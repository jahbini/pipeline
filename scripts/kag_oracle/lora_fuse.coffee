#!/usr/bin/env coffee
###
lora_fuse.coffee — fuse LoRA adapter → fused-model
Memo-native, restart-safe, no filesystem usage.

MLX will read from:
   run.loraLand/adapter

MLX will write fused model into:
   run.loraLand/fused
via existing meta-rules.
###

@step =
  desc: "Fuse MLX LoRA adapter into a new fused model (memo-native)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load experiment config
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName] ? {}

    throw new Error "Missing run section" unless runCfg?
    throw new Error "Missing run.model"    unless runCfg.model?
    throw new Error "Missing run.loraLand" unless runCfg.loraLand?

    # ------------------------------------------------------------
    # All memo-native locations
    # ------------------------------------------------------------
    landKey     = runCfg.loraLand
    adapterKey  = "#{landKey}/adapter"
    fusedKey    = "#{landKey}/fused"   # MLX will write its files here

    # ------------------------------------------------------------
    # Build args for MLX fuse
    # ------------------------------------------------------------
    args =
      model: runCfg.model
      "adapter-path": adapterKey
      "save-path": fusedKey

    console.log "[lora_fuse] args:", args

    # ------------------------------------------------------------
    # Run the MLX fuse command
    # ------------------------------------------------------------
    stdout = M.callMLX "fuse", args

    # ------------------------------------------------------------
    # Save results into memo for inspection
    # ------------------------------------------------------------
    M.saveThis "#{stepName}:stdout", stdout
    M.saveThis "done:#{stepName}", true

    return