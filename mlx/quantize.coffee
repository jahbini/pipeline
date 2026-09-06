# mlx/quantize.coffee
# ---------------------------------------------------------------------------
# In-process replacement for `mlx_lm.convert` (Python). Loads a HuggingFace-
# style unquantized MLX model from `sourceDir`, quantizes eligible weights,
# and writes a new model dir at `targetDir`.
#
# Behaviour matches mlx_lm.convert defaults:
#   - bits=4, groupSize=64, mode='affine'
#   - quantize every 2D `.weight` on a Linear or Embedding module (heuristic
#     applied by tensor shape + name; no module tree needed)
#   - copy config.json (with a `quantization` block added), tokenizer files,
#     chat template, and other metadata (LICENSE, README, generation_config)
#
# NOT sharded: Qwen3-4B fp16 (~8 GB) → 4-bit (~2 GB) fits in one safetensors.
# Larger models (>4 GB quantized) will need sharding — see TODO in
# GPT/kag_oracle/quantize_model.md.
#
# Design decision GPT/phase2_python_elimination.md §quantize.

fs = require 'fs'
path = require 'path'
{core: mx} = require '@frost-beta/mlx'

# --- constants --------------------------------------------------------------
QUANTIZE_SUFFIXES = [
  '.self_attn.q_proj.weight'
  '.self_attn.k_proj.weight'
  '.self_attn.v_proj.weight'
  '.self_attn.o_proj.weight'
  '.mlp.gate_proj.weight'
  '.mlp.up_proj.weight'
  '.mlp.down_proj.weight'
]

QUANTIZE_TOP_LEVEL = [
  'model.embed_tokens.weight'
  'lm_head.weight'
]

# Files that should be copied verbatim from source to target.
COPY_ALWAYS = [
  'tokenizer.json'
  'tokenizer.model'
  'tokenizer_config.json'
  'chat_template.jinja'
  'special_tokens_map.json'
  'generation_config.json'
  'LICENSE'
  'LICENSE.txt'
  'README.md'
  'merges.txt'
  'vocab.json'
  'added_tokens.json'
]

# --- helpers ----------------------------------------------------------------
listSafetensors = (dir) ->
  (name for name in fs.readdirSync(dir) when name.endsWith('.safetensors')).sort()

isQuantizeCandidate = (name, arr) ->
  return false unless arr?.shape?.length is 2
  return true if name in QUANTIZE_TOP_LEVEL
  return true for suffix in QUANTIZE_SUFFIXES when name.endsWith(suffix)
  false

copyFileIfExists = (srcDir, tgtDir, name) ->
  src = path.join srcDir, name
  return false unless fs.existsSync src
  fs.copyFileSync src, path.join(tgtDir, name)
  true

# --- main -------------------------------------------------------------------
quantizeModelDir = (sourceDir, targetDir, opts = {}) ->
  bits = opts.bits ? 4
  groupSize = opts.groupSize ? 64
  mode = opts.mode ? 'affine'
  logger = opts.log ? (msg) -> console.log "[quantize] #{msg}"

  throw new Error "source dir missing: #{sourceDir}" unless fs.existsSync(sourceDir)
  configPath = path.join(sourceDir, 'config.json')
  throw new Error "source missing config.json: #{configPath}" unless fs.existsSync(configPath)

  shards = listSafetensors(sourceDir)
  throw new Error "source has no .safetensors files: #{sourceDir}" unless shards.length

  fs.mkdirSync targetDir, recursive: true

  # ---- 1. Load all shards into one dict --------------------------------
  logger "loading #{shards.length} shard(s) from #{sourceDir}"
  weights = {}
  t0 = Date.now()
  for shard in shards
    shardWeights = mx.load path.join(sourceDir, shard)
    Object.assign weights, shardWeights
  logger "  loaded #{Object.keys(weights).length} tensors in #{Date.now()-t0}ms"

  # ---- 2. Quantize eligible weights ------------------------------------
  # Verbose progress logging: Metal can SIGABRT mid-quantize with
  # kIOGPUCommandBufferCallbackErrorTimeout, which is an uncaught C++
  # exception JavaScript try/catch can't reach. Log BEFORE every
  # dangerous op (mx.quantize, mx.eval flush) so the last visible
  # line pinpoints where the crash happened. Also print a heartbeat
  # every PROGRESS_EVERY tensors so long-running quantize appears
  # alive even between crashes.
  totalTensors = Object.keys(weights).length
  logger "quantizing eligible weights (bits=#{bits} groupSize=#{groupSize}, #{totalTensors} tensors total)"
  t1 = Date.now()
  out = {}
  nQuant = 0
  nCopy = 0
  seen = 0
  pending = []
  pendingBytes = 0
  # 2026-09-07: batch by BYTES not by tensor count. The old
  # tensor-count ceiling was tuned for 4B models; on 8B/27B each
  # tensor is 4-9x larger, and 32 of them per Metal command buffer
  # blows past the driver's kIOGPUCommandBufferCallbackErrorTimeout
  # watchdog (fires ~a few seconds after submission, timer-bound not
  # compute-bound). Every 8B+ pipe was hitting this. Byte budget:
  # start conservative at 32 MB per submission; override via
  # env MLX_QUANTIZE_MAX_BYTES for per-machine tuning without a
  # code change. EVAL_MAX_COUNT keeps a belt-and-suspenders ceiling.
  EVAL_MAX_BYTES = Number(process.env.MLX_QUANTIZE_MAX_BYTES ? 32 * 1024 * 1024)
  EVAL_MAX_COUNT = Number(process.env.MLX_QUANTIZE_MAX_COUNT ? 32)
  PROGRESS_EVERY = 50
  batchIdx = 0
  # dtype-agnostic worst-case bytes (fp32 upper bound — quantized
  # residuals still live in float form until eval flushes).
  byteSize = (arr) ->
    return 0 unless arr?.shape?
    n = 1
    n *= d for d in arr.shape
    4 * n
  flushPending = ->
    return unless pending.length
    batchIdx += 1
    n = pending.length
    mb = Math.round(pendingBytes / 1024 / 1024)
    logger "  eval batch ##{batchIdx} — #{n} arrays, ~#{mb}MB (about to flush to Metal)"
    tFlush = Date.now()
    mx.eval pending
    logger "  eval batch ##{batchIdx} done in #{Date.now()-tFlush}ms"
    pending.length = 0
    pendingBytes = 0
  pushArr = (arr) ->
    b = byteSize arr
    # If this single array alone would blow the budget and we already
    # have work queued, flush first so this array gets its own buffer.
    if b >= EVAL_MAX_BYTES and pending.length
      flushPending()
    pending.push arr
    pendingBytes += b
    if pending.length >= EVAL_MAX_COUNT or pendingBytes >= EVAL_MAX_BYTES
      flushPending()
  logger "eval-batching: MAX_BYTES=#{Math.round(EVAL_MAX_BYTES/1024/1024)}MB MAX_COUNT=#{EVAL_MAX_COUNT}"
  for name, arr of weights
    seen += 1
    shapeStr = JSON.stringify(arr?.shape ? [])
    if isQuantizeCandidate(name, arr)
      # 2026-09-07: some tensors (chiefly lm_head: vocab × hidden) are
      # single arrays large enough that even a solo Metal command
      # buffer for mx.quantize overruns kIOGPUCommandBufferCallbackError-
      # Timeout on the mini's GPU (e.g. lm_head[151936,4096] ≈ 297MB
      # fp32 → ~5s+ Metal wall-clock). Copy such tensors verbatim
      # (fp16) instead of quantizing them; we lose ~600MB of size
      # savings on that single tensor but the rest of the model
      # still quantizes fine. Env override: MLX_QUANTIZE_MAX_PARAMS
      # (default 300M params).
      totalParams = (arr?.shape ? []).reduce ((a,b) -> a*b), 1
      MAX_QUANT_PARAMS = Number(process.env.MLX_QUANTIZE_MAX_PARAMS ? 300_000_000)
      if totalParams > MAX_QUANT_PARAMS
        logger "  [#{seen}/#{totalTensors}] SKIP-QUANT (too large for one Metal buffer: #{totalParams} params) #{name} shape=#{shapeStr}"
        out[name] = arr
        pushArr arr
        nCopy += 1
      else
        # Announce BEFORE the potentially-crashing quantize call.
        if seen % PROGRESS_EVERY is 0 or arr?.shape?[0] * (arr?.shape?[1] ? 1) > 50_000_000
          logger "  [#{seen}/#{totalTensors}] quantizing #{name} shape=#{shapeStr}"
        try
          [wq, scales, biases] = mx.quantize arr, groupSize, bits
        catch err
          logger "  FAILED at #{name} shape=#{shapeStr}: #{err?.message ? err}"
          throw err
        base = name[...-'.weight'.length]
        out["#{base}.weight"] = wq
        out["#{base}.scales"] = scales
        out["#{base}.biases"] = biases
        pushArr wq
        pushArr scales
        pushArr biases
        nQuant += 1
    else
      logger "  [#{seen}/#{totalTensors}] copy #{name} shape=#{shapeStr}" if seen % PROGRESS_EVERY is 0
      out[name] = arr
      pushArr arr
      nCopy += 1
  flushPending()
  logger "  quantized #{nQuant} tensors, copied #{nCopy} verbatim (#{Date.now()-t1}ms)"

  # ---- 3. Write model.safetensors --------------------------------------
  outPath = path.join targetDir, 'model.safetensors'
  logger "writing #{outPath}"
  t2 = Date.now()
  mx.saveSafetensors outPath, out
  outSize = fs.statSync(outPath).size
  logger "  wrote #{(outSize/1024/1024/1024).toFixed(2)} GB in #{Date.now()-t2}ms"

  # ---- 4. Write updated config.json ------------------------------------
  config = JSON.parse fs.readFileSync(configPath, 'utf8')
  config.quantization =
    group_size: groupSize
    bits: bits
    mode: mode
  fs.writeFileSync path.join(targetDir, 'config.json'), JSON.stringify(config, null, 2) + '\n'

  # ---- 5. Copy tokenizer + metadata ------------------------------------
  copied = 0
  copied += 1 for name in COPY_ALWAYS when copyFileIfExists sourceDir, targetDir, name
  logger "  copied #{copied} metadata files"

  {
    tensorsQuantized: nQuant
    tensorsCopied: nCopy
    outputBytes: outSize
    targetDir: targetDir
  }

module.exports = {quantizeModelDir, isQuantizeCandidate, QUANTIZE_SUFFIXES, QUANTIZE_TOP_LEVEL}
