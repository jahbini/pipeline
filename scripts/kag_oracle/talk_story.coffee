#!/usr/bin/env coffee
###
talk_story.coffee — sanity-check generation using base model + LoRA adapter
Runs MLX generate BEFORE fuse.
(STEP-PARAM NATIVE)
###

@step =
  desc: "Test generation using trained LoRA adapter (pre-fuse)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?
    throw new Error "Memo missing getStepParam()" unless typeof M.getStepParam is 'function'

    # ------------------------------------------------------------
    # Load params ONLY
    # ------------------------------------------------------------
    modelId = M.getStepParam stepName, 'model'
    landKey = M.getStepParam stepName, 'loraLand'
    adapterKey  = M.getStepParam stepName, 'adapterKey'
    maxTokens  = M.getStepParam stepName, 'maxTokens'
    topP  = M.getStepParam stepName, 'topP'
    temp  = M.getStepParam stepName, 'temp'

    throw new Error "Missing model"    unless modelId?
    throw new Error "Missing loraLand" unless landKey?
    model_dir = M.theLowdown  "model_dir:#{modelId}"

    # ------------------------------------------------------------
    # Story prompt
    # ------------------------------------------------------------
    prompt = M.getStepParam stepName, "prompt"

    # ------------------------------------------------------------
    # MLX generate args (adapter applied)
    # ------------------------------------------------------------
    args =
      model: model_dir.value
      prompt: prompt
      "adapter-path": adapterKey
      "max-tokens": maxTokens
      temp: temp
      "top-p": topP

    console.log "=== GENERATION ==="
    console.log args
    console.log "\n--- model output ---\n"

    out = M.callMLX "generate", args

    console.log out

    # ------------------------------------------------------------
    # Save output for inspection
    # ------------------------------------------------------------
    M.saveThis "#{stepName}:prompt", prompt
    M.saveThis "#{stepName}:output", out

    return
