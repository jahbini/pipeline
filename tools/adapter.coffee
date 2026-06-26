###
  adapter.coffee  —  tool (S.tools.adapter)
  =====================================================
  Reached from step scripts as:
      S.tools.adapter.<entrypoint>(args...)

  Tool contract (see GPT/CONVENTIONS.md § "Tools"):
    - stateless: no module-level mutables, no warm-up
    - takes ordinary args; receives no runner-injected objects
    - may do filesystem I/O (these entrypoints all read the disk —
      probe for files, list a directory); the tool remembers nothing
      between calls
    - never a recipe step

  Why this exists:
    LoRA-related step scripts kept duplicating the same "where is
    the latest adapter checkpoint?" and "does an adapter config
    exist?" probes. Two scripts (run_lora_train_ite,
    generate_ablations_ite) were each carrying their own `fs.existsSync`
    / `fs.readdirSync` logic. Both violated the "fs stinginess in
    step scripts" rule — they aren't producing build artifacts, just
    sniffing the disk. Folding the probes into one tool removes the
    duplication and lets steps stay fs-free.

  Naming convention this tool assumes:
    - `<adapterPath>/adapters.safetensors`        ← final adapter
    - `<adapterPath>/<NNNN>_adapters.safetensors` ← numbered checkpoints
    - `<adapterPath>/adapter_config.json`         ← LoRA config
  (mlx_lm.lora's documented output layout)
###
fs = require 'fs'
path = require 'path'

# Does the adapter directory exist? (Cheap existsSync — a simple sniff
# that says "this is a path the disk knows about." Does NOT mean the
# directory contains a valid adapter; use `latestCheckpoint` /
# `hasAdapterConfig` for that.)
exists = (adapterPath) ->
  return false unless adapterPath?
  fs.existsSync adapterPath

# Is there an `adapter_config.json` inside this adapter dir?
hasAdapterConfig = (adapterPath) ->
  return false unless adapterPath?
  fs.existsSync path.join(adapterPath, 'adapter_config.json')

# Find the most recent checkpoint file in an adapter directory:
#   1. `adapters.safetensors`        (the final/converged adapter)
#   2. highest-numbered `<NNNN>_adapters.safetensors`
#   3. otherwise null
# Returns an absolute path or null. Performs no validation beyond
# existence.
latestCheckpoint = (adapterPath) ->
  return null unless adapterPath? and fs.existsSync(adapterPath)

  finalAdapter = path.join(adapterPath, 'adapters.safetensors')
  return finalAdapter if fs.existsSync(finalAdapter)

  checkpoints = fs.readdirSync(adapterPath)
    .filter (name) -> /^\d+_adapters\.safetensors$/.test(name)
    .sort()

  return null unless checkpoints.length
  path.join adapterPath, checkpoints[checkpoints.length - 1]

# Pick a file to resume training from. If the caller passed an explicit
# `configuredResumeFile` that exists on disk, use it; otherwise fall
# back to `latestCheckpoint`. Returns an absolute path or null.
resolveResumeFile = (adapterPath, configuredResumeFile) ->
  return configuredResumeFile if configuredResumeFile? and fs.existsSync(configuredResumeFile)
  latestCheckpoint adapterPath

module.exports = {
  exists
  hasAdapterConfig
  latestCheckpoint
  resolveResumeFile
}
