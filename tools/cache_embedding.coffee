###
  cache_embedding.coffee  —  tool (S.tools.cache_embedding)
  =====================================================
  Reached from step scripts as:
      S.tools.cache_embedding.<entrypoint>(args...)

  Tool contract (see GPT/CONVENTIONS.md § "Tools"):
    - stateless: no module-level mutables, no warm-up
    - takes ordinary args; receives no runner-injected objects
    - may do filesystem I/O (read the safetensors file, unlink it,
      etc.); the tool itself remembers nothing between calls
    - never a recipe step

  Resolution tier (handled by the runner): CWD/tools/ over BASE/tools/
  over EXEC/tools/. Drop a per-pipe override at {CWD}/tools/cache_embedding.coffee
  to shadow this canonical version for one pipe only.

  Safetensors layout produced by `mlx_lm cache_prompt` (verified by
  `test.sh`'s cache_prompt_probe — see test/results/.../safetensors_header.json):
    - first 8 bytes  : u64 LE = JSON header length
    - next N bytes   : JSON header
    - remaining bytes: tensor data blob
    - tensors named "<layer>.0" (keys) / "<layer>.1" (values)
    - each shape [1, num_kv_heads, seq_len, head_dim], dtype BF16

  Embedding extraction:
    - last layer's "<L>.1" tensor (the V projection of the highest layer)
    - mean-pool across the seq_len axis
    - flatten heads → single 1-D vector of (num_kv_heads × head_dim) floats
    - for Qwen3-4B that's 8 × 128 = 1024 floats = 4096 bytes as Float32
###
fs = require 'fs'

# ---- safetensors reader ---------------------------------------------

readSafetensors = (filepath) ->
  buf = fs.readFileSync filepath
  headerLen = Number buf.readBigUInt64LE 0
  throw new Error "safetensors header too short" if headerLen <= 0 or headerLen >= buf.length - 8
  header = JSON.parse buf.slice(8, 8 + headerLen).toString 'utf8'
  blobStart = 8 + headerLen
  { header, blob: buf.slice(blobStart) }

# Read one named tensor's raw bytes from a parsed safetensors. The
# `data_offsets` in the header are byte offsets into the data blob
# (NOT into the file as a whole) per the safetensors spec.
sliceTensorBytes = (parsed, tensorName) ->
  meta = parsed.header[tensorName]
  throw new Error "tensor '#{tensorName}' not in safetensors header" unless meta?
  [start, end] = meta.data_offsets
  parsed.blob.slice start, end

# ---- BF16 → Float32 -------------------------------------------------

# BF16 = top 16 bits of a Float32 (sign + 8-bit exponent + 7 mantissa
# bits). Extending to F32 means shifting the BF16 bits into the high
# half of a 32-bit word and zeroing the low half. >>> 0 forces unsigned
# so the shift doesn't produce a negative JS number.
bf16BufferToFloat32 = (bf16Buf) ->
  count = bf16Buf.length / 2
  throw new Error "BF16 buffer length must be even (got #{bf16Buf.length})" unless count is Math.floor(count)
  out = new Float32Array(count)
  view = new DataView(out.buffer)
  for i in [0...count]
    bf16 = bf16Buf.readUInt16LE(i * 2)
    view.setUint32(i * 4, (bf16 << 16) >>> 0, true)   # little-endian
  out

# ---- last-layer V extraction + mean-pool ----------------------------

# Find the highest-numbered layer in the parsed safetensors. The cache
# tensors are named "<layer>.0" (keys) / "<layer>.1" (values).
lastLayerIndex = (parsed) ->
  best = -1
  for name of parsed.header when name isnt '__metadata__'
    [layerStr, _role] = name.split '.'
    layer = parseInt layerStr, 10
    best = layer if Number.isFinite(layer) and layer > best
  throw new Error "no layered tensors found in safetensors header" if best < 0
  best

# Extract last-layer V tensor as a flat Float32Array, in raw shape
# `[1 × num_kv_heads × seq_len × head_dim]` flattened in C order.
# Returns { values: Float32Array, shape: [1, kv_heads, seq_len, head_dim] }.
extractLastLayerV = (parsed) ->
  layer = lastLayerIndex parsed
  name = "#{layer}.1"
  meta = parsed.header[name]
  shape = meta.shape
  throw new Error "last-layer V '#{name}' wrong rank (#{shape})" unless shape.length is 4
  rawBytes = sliceTensorBytes parsed, name
  switch meta.dtype.toUpperCase()
    when 'BF16'
      values = bf16BufferToFloat32 rawBytes
    when 'F16'
      throw new Error "F16 dtype not yet supported in cache_embedding (need a small extra path)"
    when 'F32'
      values = new Float32Array(rawBytes.buffer.slice(rawBytes.byteOffset, rawBytes.byteOffset + rawBytes.byteLength))
    else
      throw new Error "unhandled cache dtype: #{meta.dtype}"
  { values, shape }

# Mean-pool the V tensor across the seq_len axis (axis 2). Shape goes
# from [1, kv_heads, seq_len, head_dim] → [kv_heads × head_dim] flat.
# Returns a Float32Array sized (kv_heads × head_dim).
meanPoolLastLayerV = (tensor) ->
  { values, shape } = tensor
  [batch, kvHeads, seqLen, headDim] = shape
  throw new Error "expected batch=1, got #{batch}" unless batch is 1
  throw new Error "empty seq_len in V tensor" unless seqLen > 0
  out = new Float32Array(kvHeads * headDim)
  # Layout (C order): values[h * seqLen * headDim + s * headDim + d]
  for h in [0...kvHeads]
    for d in [0...headDim]
      sum = 0
      for s in [0...seqLen]
        sum += values[h * seqLen * headDim + s * headDim + d]
      out[h * headDim + d] = sum / seqLen
  out

# Convenience: full pipeline from a cache file path → pooled 1-D
# Float32Array. The caller turns this into a Buffer for SQLite BLOB
# storage via `floatArrayToBlob`.
embeddingFromCacheFile = (cachePath) ->
  parsed = readSafetensors cachePath
  tensor = extractLastLayerV parsed
  meanPoolLastLayerV tensor

# ---- Float32Array ↔ Buffer conversions for SQLite BLOBs ------------

floatArrayToBlob = (arr) ->
  # Buffer.from(arrayBuffer) shares memory with the Float32Array's
  # backing buffer. Copy if the array is a view into a larger buffer.
  Buffer.from arr.buffer, arr.byteOffset, arr.byteLength

blobToFloatArray = (buf) ->
  # Buffer view → Float32Array view (zero-copy when alignment allows).
  # Slice the bytes into a fresh ArrayBuffer to guarantee 4-byte align.
  copy = new ArrayBuffer(buf.byteLength)
  new Uint8Array(copy).set(buf)
  new Float32Array(copy)

# ---- cosine similarity ---------------------------------------------

cosineSimilarity = (a, b) ->
  throw new Error "cosine length mismatch (#{a.length} vs #{b.length})" unless a.length is b.length
  dot = 0; na = 0; nb = 0
  for i in [0...a.length]
    dot += a[i] * b[i]
    na  += a[i] * a[i]
    nb  += b[i] * b[i]
  denom = Math.sqrt(na) * Math.sqrt(nb)
  return 0 if denom is 0
  dot / denom

# Mean of an iterable of Float32Arrays (all same length) → centroid.
meanOfFloatArrays = (arrays) ->
  return null unless arrays.length > 0
  dim = arrays[0].length
  out = new Float32Array(dim)
  for arr in arrays
    throw new Error "centroid length mismatch (#{arr.length} vs #{dim})" unless arr.length is dim
    for i in [0...dim]
      out[i] += arr[i]
  for i in [0...dim]
    out[i] /= arrays.length
  out

module.exports = {
  readSafetensors
  sliceTensorBytes
  bf16BufferToFloat32
  lastLayerIndex
  extractLastLayerV
  meanPoolLastLayerV
  embeddingFromCacheFile
  floatArrayToBlob
  blobToFloatArray
  cosineSimilarity
  meanOfFloatArrays
}
