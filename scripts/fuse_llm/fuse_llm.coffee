###
  scripts/fuse_llm/fuse_llm.coffee  —  FUSE_LLM step
  =================================================
  Merges a LoRA adapter into the base model's weights via
  L.callLLM({op:'fuse', ...}) → mlx/lora/fuse.coffee::fuseAdapter.
  In-process, node-mlx. Sibling of no MLX/Python step in mlxCoffee's
  grandfathered path (the Python variant `mlx_lm.fuse` is only ever
  reached via a legacy shell-out from `scripts/full/fuse.coffee`).

  Contract:
    needs: []                          (relies on adapter + base being
                                        materialized by upstream steps or
                                        by hand; no artifact dependency
                                        because their targets are dirs,
                                        not files, and the artifact
                                        registry is file-typed)
    makes: fuse_run_record             (JSON with merge stats)
    params:
      quantized_model_dir  → base model dir (mlx-lm format, may be quantized)
      adapter_dir          → dir containing adapter_config.json + adapters.safetensors
      target_model_dir     → output dir for the fused, self-contained model
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Merge a LoRA adapter into base weights via L.callLLM(fuse)"

  action: (L) ->
    baseModelDir   = L.param 'quantized_model_dir', null
    adapterDir     = L.param 'adapter_dir', null
    targetModelDir = L.param 'target_model_dir', null

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless baseModelDir?
    throw new Error "[#{L.stepName}] Missing adapter_dir param"         unless adapterDir?
    throw new Error "[#{L.stepName}] Missing target_model_dir param"    unless targetModelDir?

    # Pre-checks: fuseAdapter will throw specific errors for missing files,
    # but a step-level sanity check gives clearer failure attribution.
    baseCfg = path.join baseModelDir, 'config.json'
    throw new Error "[#{L.stepName}] base model missing config.json at #{baseCfg}" unless fs.existsSync baseCfg
    adapterCfg = path.join adapterDir, 'adapter_config.json'
    adapterSt  = path.join adapterDir, 'adapters.safetensors'
    throw new Error "[#{L.stepName}] adapter missing #{adapterCfg}"    unless fs.existsSync adapterCfg
    throw new Error "[#{L.stepName}] adapter missing #{adapterSt}"     unless fs.existsSync adapterSt

    console.log "[fuse_llm] baseModelDir:   #{baseModelDir}"
    console.log "[fuse_llm] adapterDir:     #{adapterDir}"
    console.log "[fuse_llm] targetModelDir: #{targetModelDir}"

    t0 = Date.now()
    result = await L.callLLM
      op: 'fuse'
      baseModelDir:   baseModelDir
      adapterDir:     adapterDir
      targetModelDir: targetModelDir
    elapsedSec = (Date.now() - t0) / 1000

    console.log "[fuse_llm] merged #{result.merged} layers → #{targetModelDir} in #{elapsedSec.toFixed 1}s"
    console.log "[fuse_llm] output: #{(result.outputBytes / 1024 / 1024 / 1024).toFixed 2} GB"

    L.make 'fuse_run_record',
      mode:              'fuse_llm'
      base_model_dir:    baseModelDir
      adapter_dir:       adapterDir
      target_model_dir:  targetModelDir
      merged_layers:     result.merged
      output_bytes:      result.outputBytes
      output_gb:         result.outputBytes / 1024 / 1024 / 1024
      elapsed_sec:       elapsedSec

    L.done()
    return
