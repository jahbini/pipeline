# mlx/lora/fuse.coffee
# ---------------------------------------------------------------------------
# In-process replacement for `mlx_lm.fuse`. Merges a LoRA adapter into the
# base model's weights and writes a self-contained model dir with no
# adapter. Works on both unquantized and quantized base weights.
#
# For quantized bases (Qwen3-4B is 4-bit affine), the delta is added in
# dequantized fp space and then re-quantized with the same group_size/bits.
# This is what mlx-lm does; you re-introduce quantization noise on top of
# the merged weights, but the alternative (leaving quantized untouched and
# emitting the adapter as a runtime layer) is exactly the un-fused state.
#
# Design decision GPT/phase3_lora_and_fuse.md §fuse.

fs = require 'fs'
path = require 'path'
{core: mx} = require '@frost-beta/mlx'

# Copy every file except *.safetensors + *.safetensors.index.json from src → dst.
# The weights are being rewritten so we drop stale ones; config.json and
# tokenizer files come across.
copyMetadata = (srcDir, dstDir) ->
  fs.mkdirSync dstDir, recursive: true
  n = 0
  for name in fs.readdirSync(srcDir)
    continue if name.endsWith('.safetensors')
    continue if name.endsWith('.safetensors.index.json')
    stat = fs.statSync path.join(srcDir, name)
    continue if stat.isDirectory()
    fs.copyFileSync path.join(srcDir, name), path.join(dstDir, name)
    n += 1
  n

camelToSnake = (s) -> s.replace /[A-Z]/g, (c) -> '_' + c.toLowerCase()

# Load all weights from a directory (all shards merged).
loadAllWeights = (dir) ->
  weights = {}
  for name in fs.readdirSync(dir) when name.endsWith('.safetensors')
    Object.assign weights, mx.load path.join(dir, name)
  weights

# Compute the fused delta weight from A [in, rank] and B [rank, out].
# Returns shape [out, in] so it can be added directly to a Linear's weight.
computeDelta = (loraA, loraB, scale) ->
  ab = mx.matmul(loraA, loraB)          # [in, out]
  scaled = mx.multiply(ab, mx.array(scale))
  mx.transpose(scaled, [1, 0])          # [out, in]

# --- public API ------------------------------------------------------------
fuseAdapter = (baseModelDir, adapterDir, targetModelDir, opts = {}) ->
  logger = opts.log ? (msg) -> console.log "[fuse] #{msg}"

  configPath = path.join baseModelDir, 'config.json'
  throw new Error "base config missing: #{configPath}" unless fs.existsSync configPath
  throw new Error "adapter_config.json missing in #{adapterDir}" unless fs.existsSync path.join(adapterDir, 'adapter_config.json')
  throw new Error "adapters.safetensors missing in #{adapterDir}" unless fs.existsSync path.join(adapterDir, 'adapters.safetensors')

  baseConfig = JSON.parse fs.readFileSync(configPath, 'utf8')
  adapterConfig = JSON.parse fs.readFileSync(path.join(adapterDir, 'adapter_config.json'), 'utf8')
  scale = adapterConfig.alpha / adapterConfig.rank
  logger "adapter rank=#{adapterConfig.rank} alpha=#{adapterConfig.alpha} → scale=#{scale}"
  logger "adapter targets #{adapterConfig.wrapped_paths.length} layers"

  isQuantized = baseConfig.quantization?
  if isQuantized
    {group_size, bits} = baseConfig.quantization
    logger "base is quantized (bits=#{bits} groupSize=#{group_size}) — dequantize→add→requantize"

  # Load everything ONCE.
  logger "loading base weights from #{baseModelDir}"
  weights = loadAllWeights baseModelDir
  logger "  #{Object.keys(weights).length} base tensors"
  logger "loading adapter weights from #{adapterDir}"
  adapterWeights = mx.load path.join(adapterDir, 'adapters.safetensors')
  logger "  #{Object.keys(adapterWeights).length} adapter tensors"

  # Merge in-place.
  merged = 0
  for camelPath in adapterConfig.wrapped_paths
    snake = camelToSnake camelPath
    keyA = "#{snake}.lora_a"
    keyB = "#{snake}.lora_b"
    unless adapterWeights[keyA]? and adapterWeights[keyB]?
      throw new Error "adapter missing #{keyA} or #{keyB}"

    delta = computeDelta adapterWeights[keyA], adapterWeights[keyB], scale
    weightKey = "#{snake}.weight"
    baseW = weights[weightKey]
    throw new Error "base missing #{weightKey}" unless baseW?

    if isQuantized
      scalesKey = "#{snake}.scales"
      biasesKey = "#{snake}.biases"
      throw new Error "base missing #{scalesKey}/#{biasesKey}" unless weights[scalesKey]? and weights[biasesKey]?
      # Dequantize [out, in] fp, add delta (which is fp), re-quantize.
      dq = mx.dequantize weights[weightKey], weights[scalesKey], weights[biasesKey], group_size, bits
      # dq might be fp16/fp32 depending on how MLX dequantizes; delta is fp32.
      merged_fp = mx.add dq, delta.astype(dq.dtype)
      [wq, s, b] = mx.quantize merged_fp, group_size, bits
      weights[weightKey] = wq
      weights[scalesKey] = s
      weights[biasesKey] = b
    else
      weights[weightKey] = mx.add baseW, delta.astype(baseW.dtype)
    merged += 1

  mx.eval Object.values(weights)
  logger "  merged #{merged} weight tensors"

  # Write target dir.
  copied = copyMetadata baseModelDir, targetModelDir
  logger "copied #{copied} metadata files from base"
  outPath = path.join targetModelDir, 'model.safetensors'
  mx.saveSafetensors outPath, weights
  outBytes = fs.statSync(outPath).size
  logger "wrote #{outPath} (#{(outBytes/1024/1024/1024).toFixed(2)} GB)"

  # Preserve config.json as-is (already copied by copyMetadata).
  {targetDir: targetModelDir, merged, outputBytes: outBytes}

module.exports = {fuseAdapter, computeDelta}
