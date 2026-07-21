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
  logger "quantizing eligible weights (bits=#{bits} groupSize=#{groupSize})"
  t1 = Date.now()
  out = {}
  nQuant = 0
  nCopy = 0
  for name, arr of weights
    if isQuantizeCandidate(name, arr)
      [wq, scales, biases] = mx.quantize arr, groupSize, bits
      base = name[...-'.weight'.length]
      out["#{base}.weight"] = wq
      out["#{base}.scales"] = scales
      out["#{base}.biases"] = biases
      nQuant += 1
    else
      out[name] = arr
      nCopy += 1
  # Force realization before saving (arrays are lazy).
  mx.eval Object.values(out)
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
