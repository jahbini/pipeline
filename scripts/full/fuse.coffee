#!/usr/bin/env coffee
###
fuse.coffee — clean memo-native version (2025)
-----------------------------------------------
STEP — Fuse + Quantize via MLX using M.callMLX

  • Reads artifacts.json from memo (run.artifacts)
  • For each run entry:
      - optionally fuse (model + adapter → fused_dir)
      - always quantize fused_dir → quantized_dir
  • All calls use M.callMLX ("fuse", ...), ("convert", ...)
  • No shelling out, no file I/O except via memo
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Fuse LoRA adapters and quantize models (memo-native MLX)"

  action: (M, stepName) ->
    params = (M.theLowdown "params/#{stepName}.json").value

    # -------------------------------------------------------------
    # Load artifacts registry (MUST be in memo)
    # -------------------------------------------------------------
    artifacts_path = params.artifacts
    reg = M.theLowdown(artifacts_path)
    console.error "awaiting",stepName, artifacts_path unless reg.value
    registry = reg.value || await reg.notifier
    throw new Error "Missing #{artifacts_path} in memo" unless registry?

    runs = registry.runs or []
    throw new Error "No entries in registry.runs" unless runs.length
    # -------------------------------------------------------------
    # Step parameters
    # -------------------------------------------------------------
    DO_FUSE = !!params.do_fuse
    DRY_RUN = !!params.dry_run
    Q_BITS  = parseInt(params.q_bits  or 4)
    Q_GROUP = parseInt(params.q_group or 32)
    DTYPE   = params.dtype or 'float16'

    log = (msg) -> console.log "[fuse] #{msg}"

    # -------------------------------------------------------------
    # MLX wrappers — ALWAYS memo-native (no disk I/O)
    # -------------------------------------------------------------
    callFuse = (modelPath, adapterPath, savePath) ->
      args =
        model: modelPath
        "adapter-path": adapterPath
        "save-path": savePath

      if DRY_RUN
        log "(DRY_RUN) fuse: #{JSON.stringify args}"
        return {stdout: ""}
      stdout = M.callMLX "fuse", args
      {stdout}

    callQuant = (fusedDir, quantDir) ->
      args =
        "hf-path":  fusedDir
        "mlx-path": quantDir
        "q-bits": Q_BITS
        "q-group-size": Q_GROUP
        dtype: DTYPE
        "": "-q"   # MLX uses presence of '-q'

      if DRY_RUN
        log "(DRY_RUN) quantize: #{JSON.stringify args}"
        return {stdout: ""}

      stdout = M.callMLX "convert", args
      {stdout}

    # -------------------------------------------------------------
    # Main loop: for each run entry
    # -------------------------------------------------------------
    for entry in runs
      modelId    = entry.model_id
      entry["output_root"] = path.dirname entry.adapter_dir
      adapterDir = entry.adapter_dir
      fusedDir   = entry.fused_dir or path.join(path.dirname(entry.adapter_dir), 'fused')
      quantDir   = entry.quantized_dir or path.join(path.dirname(entry.adapter_dir), 'quantized')

      log "Processing #{modelId}"

      # -----------------------------------------------------------
      # FUSE (optional)
      # -----------------------------------------------------------
      if DO_FUSE
        log "→ Fusing #{modelId}"
        {stdout: outF} = callFuse(modelId, adapterDir, fusedDir)

        entry.fused_dir = fusedDir
        M.saveThis "#{stepName}:fuse:#{modelId}", outF
        log "   ✓ fused → #{fusedDir}"

      else
        log "Skipping fuse step"

      # -----------------------------------------------------------
      # QUANTIZE (always)
      # -----------------------------------------------------------
      log "→ Quantizing #{modelId}"

      fusedInput = entry.fused_dir or fusedDir
      {stdout: outQ} = callQuant(fusedInput, quantDir)

      entry.quantized_dir  = quantDir
      entry.quantize_bits  = Q_BITS
      entry.q_group_size   = Q_GROUP

      M.saveThis "#{stepName}:quant:#{modelId}", outQ
      log "   ✓ quantized → #{quantDir}"

    # -------------------------------------------------------------
    # Save updated registry back into memo
    # -------------------------------------------------------------
    registry.updated_utc = new Date().toISOString()
    M.saveThis artifacts_path, registry

    log "📘 Updated artifacts in memo."
    return
