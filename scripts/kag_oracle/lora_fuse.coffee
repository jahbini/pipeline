#!/usr/bin/env coffee
###
lora_fuse.coffee — fuse LoRA adapter → fused-model
Memo-native, restart-safe, no filesystem usage.

Uses ONLY step params (no experiment.yaml).
Relies on Memo helper(s):
  • M.getStepParam(stepName, "run.model")
  • M.getStepParam(stepName, "run.loraLand")

MLX will read from:
   <run.loraLand>/adapter

MLX will write fused model into:
   <run.loraLand>/fused
via existing meta-rules.
###

@step =
  desc: "Fuse MLX LoRA adapter into a new fused model (params-only, memo-native)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Pull required params (NO experiment.yaml)
    # ------------------------------------------------------------
    modelId = M.getStepParam stepName, "run.model"
    landKey = M.getStepParam stepName, "run.loraLand"

    throw new Error "Missing param run.model" unless modelId?
    throw new Error "Missing param run.loraLand" unless landKey?

    # ------------------------------------------------------------
    # Memo-native locations
    # ------------------------------------------------------------
    adapterKey = "#{landKey}/adapter"
    fusedKey   = "#{landKey}/fused"

    # ------------------------------------------------------------
    # Check whether adapter exists (memo + meta-read)
    # ------------------------------------------------------------
    adapterEntry = M.theLowdown adapterKey
    adapterVal   = adapterEntry?.value

    unless adapterVal?
      console.log "[lora_fuse] no adapter present — skipping"
      return

    # ------------------------------------------------------------
    # Build args for MLX fuse
    # ------------------------------------------------------------
    args =
      model: modelId
      "adapter-path": adapterKey
      "save-path": fusedKey

    console.log "[lora_fuse] args:", args

    # ------------------------------------------------------------
    # Run the MLX fuse command (synchronous)
    # ------------------------------------------------------------
    stdout = M.callMLX "fuse", args

    # ------------------------------------------------------------
    # Save results into memo for inspection
    # ------------------------------------------------------------
    M.saveThis "#{stepName}:stdout", stdout

    return