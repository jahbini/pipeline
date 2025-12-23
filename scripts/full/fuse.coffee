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

    throw new Error "Missing stepName argument" unless stepName?

    # -------------------------------------------------------------
    # Load config
    # -------------------------------------------------------------
    cfg = M.theLowdown('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml in memo" unless cfg?

    stepCfg = cfg[stepName]
    throw new Error "Missing step config '#{stepName}'" unless stepCfg?

    runCfg = cfg.run
    throw new Error "Missing run section" unless runCfg?

    # -------------------------------------------------------------
    # Load artifacts registry (MUST be in memo)
    # -------------------------------------------------------------
    ART_PATH = runCfg.artifacts
    registry = M.theLowdown(ART_PATH)?.value
    throw new Error "Missing #{ART_PATH} in memo" unless registry?

    runs = registry.runs or []
    throw new Error "No entries in registry.runs" unless runs.length

    # -------------------------------------------------------------
    # Step parameters
    # -------------------------------------------------------------
    DO_FUSE = !!stepCfg.do_fuse
    DRY_RUN = !!stepCfg.dry_run
    Q_BITS  = parseInt(stepCfg.q_bits  or 4)
    Q_GROUP = parseInt(stepCfg.q_group or 32)
    DTYPE   = stepCfg.dtype or 'float16'

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
        quantize: ''   # MLX uses presence of '-q'

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
      adapterDir = entry.adapter_dir
      fusedDir   = entry.fused_dir or path.join(path.dirname(ART_PATH), 'fused')
      quantDir   = entry.quantized_dir or path.join(path.dirname(ART_PATH), 'quantized')

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
    M.saveThis ART_PATH, registry

    log "📘 Updated artifacts in memo."
    return
