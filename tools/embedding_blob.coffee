###
  embedding_blob.coffee  —  tool (S.tools.embedding_blob)
  ========================================================
  Reached from step scripts as:
      S.tools.embedding_blob.<entrypoint>(args...)

  Tool contract (see GPT/CONVENTIONS.md § "Tools"):
    - stateless: no module-level mutables, no warm-up
    - takes ordinary args; receives no runner-injected objects
    - no filesystem I/O
    - never a recipe step

  What it does:
    Four helpers for handling the 1024-dim Float32 embeddings that
    L.callLLM({op:'embed'}) produces:
      - floatArrayToBlob / blobToFloatArray  — SQLite BLOB glue
      - meanOfFloatArrays                    — build a centroid
      - cosineSimilarity                     — the voice-fidelity metric

    Historical note: this file was previously `cache_embedding.coffee`
    and carried a full safetensors-reader + BF16→F32 + last-layer-V
    extraction chain. All of that is dead now — the in-process
    `L.callLLM({op:'embed'})` returns a Float32Array directly, so
    reading K/V from a temp file is no longer part of any recipe.
    The four helpers below are what actually survived the port.
###

# ---- Float32Array ↔ Buffer conversions for SQLite BLOBs ------------

floatArrayToBlob = (arr) ->
  # Buffer.from(arrayBuffer) shares memory with the Float32Array's
  # backing buffer. Copy if the array is a view into a larger buffer.
  Buffer.from arr.buffer, arr.byteOffset, arr.byteLength

blobToFloatArray = (buf) ->
  # Buffer view → Float32Array view. Slice the bytes into a fresh
  # ArrayBuffer to guarantee 4-byte alignment (Float32Array requires
  # this on some platforms).
  copy = new ArrayBuffer(buf.byteLength)
  new Uint8Array(copy).set(buf)
  new Float32Array(copy)

# ---- centroid + cosine ---------------------------------------------

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

module.exports = {
  floatArrayToBlob
  blobToFloatArray
  meanOfFloatArrays
  cosineSimilarity
}
