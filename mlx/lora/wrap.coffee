# mlx/lora/wrap.coffee
# ---------------------------------------------------------------------------
# Walk a model tree and replace target Linear/QuantizedLinear modules with
# LoRALinear wrappers. Also save/load adapter weights as .safetensors +
# adapter_config.json (mlx-lm compatible naming).
#
# Design decision GPT/phase3_lora_and_fuse.md §wrap and §adapter-format.

fs = require 'fs'
path = require 'path'
{core: mx, nn} = require '@frost-beta/mlx'
{LoRALinear} = require './lora_layer'

# --- module walker ---------------------------------------------------------
# nn.Module doesn't ship an "applyToModules" that lets you REPLACE a child
# by name (only mutate). We walk manually using Object.keys and re-assign.
# Arrays of modules (like model.model.layers) are the standard MLX pattern.
walkAndWrap = (module, prefix, matcher, wrapper) ->
  wrapped = []
  for own key, child of module
    fullKey = if prefix then "#{prefix}.#{key}" else key
    if Array.isArray(child)
      for item, i in child when item instanceof nn.Module
        subKey = "#{fullKey}.#{i}"
        wrapped.push (walkAndWrap(item, subKey, matcher, wrapper))...
    else if child instanceof nn.Module
      # Attempt wrap
      isTarget = matcher fullKey, child
      if isTarget
        replacement = wrapper(child, fullKey)
        module[key] = replacement
        wrapped.push {path: fullKey, wrapper: replacement}
      else
        wrapped.push (walkAndWrap(child, fullKey, matcher, wrapper))...
  wrapped

# --- default target matcher ------------------------------------------------
# mlx-lm default: q_proj, v_proj on every attention block. Paths use the JS
# camelCase submodule names (Qwen3 model: selfAttn.qProj / selfAttn.vProj);
# snake_case conversion happens ONLY at the adapter safetensors boundary.
DEFAULT_TARGETS = ['selfAttn.qProj', 'selfAttn.vProj']

makeMatcher = (targetSuffixes = DEFAULT_TARGETS) ->
  (fullKey, child) ->
    isLinearLike = (child instanceof nn.Linear) or (child instanceof nn.QuantizedLinear)
    return false unless isLinearLike
    for suffix in targetSuffixes when fullKey.endsWith(suffix)
      return true
    false

# --- public API ------------------------------------------------------------
# Wrap `model` in-place. Freezes the entire model, then unfreezes only the
# LoRA A/B parameters of each wrapped layer.
# Returns array of {path, wrapper} for downstream saving.
applyLoRA = (model, opts = {}) ->
  rank    = opts.rank    ? 8
  alpha   = opts.alpha   ? 16
  dropout = opts.dropout ? 0.0
  targets = opts.targets ? DEFAULT_TARGETS

  matcher = makeMatcher(targets)
  wrapper = (linear, fullKey) -> LoRALinear.wrap linear, {rank, alpha, dropout}

  wrapped = walkAndWrap(model, '', matcher, wrapper)

  # Freeze everything, then unfreeze only the LoRA parameters of wrapped layers.
  model.freeze true    # recursive
  for {wrapper: lora} in wrapped
    lora.unfreeze false, ['loraA', 'loraB'], false

  {rank, alpha, dropout, targets, wrapped, count: wrapped.length}

# --- adapter save/load -----------------------------------------------------
# On-disk layout (mlx-lm compatible naming; extension safetensors instead of npz):
#   adapters.safetensors    { "<path>.lora_a": [in,rank], "<path>.lora_b": [rank,out], ... }
#   adapter_config.json     { rank, alpha, dropout, targets, wrapped_paths: [...] }

# Convert camelCase submodule paths to snake_case for safetensors keys,
# matching MLX's convention (see MLX's toCamelCase in nn/layers/base.ts, we
# invert it going out).
camelToSnake = (s) -> s.replace /[A-Z]/g, (c) -> '_' + c.toLowerCase()

adapterKeys = (fullKey) ->
  base = camelToSnake fullKey
  a: "#{base}.lora_a"
  b: "#{base}.lora_b"

saveAdapter = (adapterDir, wrappedInfo) ->
  fs.mkdirSync adapterDir, recursive: true
  tensors = {}
  paths = []
  for {path: fullKey, wrapper: lora} in wrappedInfo.wrapped
    {a, b} = adapterKeys fullKey
    tensors[a] = lora.loraA
    tensors[b] = lora.loraB
    paths.push fullKey
  mx.eval Object.values(tensors)
  mx.saveSafetensors path.join(adapterDir, 'adapters.safetensors'), tensors
  config =
    rank:          wrappedInfo.rank
    alpha:         wrappedInfo.alpha
    dropout:       wrappedInfo.dropout
    targets:       wrappedInfo.targets
    wrapped_paths: paths
  fs.writeFileSync path.join(adapterDir, 'adapter_config.json'), JSON.stringify(config, null, 2) + '\n'
  {tensorCount: Object.keys(tensors).length, adapterDir}

# Load adapter into an already-wrapped model. Skips paths not present in the
# adapter (allows loading partial or in-progress adapters). Throws if the
# adapter has paths that don't exist in the model.
loadAdapter = (adapterDir, wrappedInfo) ->
  configPath = path.join adapterDir, 'adapter_config.json'
  weightsPath = path.join adapterDir, 'adapters.safetensors'
  throw new Error "missing adapter_config.json in #{adapterDir}" unless fs.existsSync configPath
  throw new Error "missing adapters.safetensors in #{adapterDir}" unless fs.existsSync weightsPath

  weights = mx.load weightsPath
  loaded = 0
  for {path: fullKey, wrapper: lora} in wrappedInfo.wrapped
    {a, b} = adapterKeys fullKey
    unless weights[a]? and weights[b]?
      continue    # partial adapter — ok
    lora.loraA = weights[a]
    lora.loraB = weights[b]
    loaded += 1
  {loaded, expected: wrappedInfo.wrapped.length}

module.exports = {applyLoRA, saveAdapter, loadAdapter, DEFAULT_TARGETS, adapterKeys}
