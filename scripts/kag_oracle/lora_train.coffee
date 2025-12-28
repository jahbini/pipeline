#!/usr/bin/env coffee
###
lora_train.coffee — MLX LoRA incremental training (step-param native)
Assumes M.getStepParam(stepName, key) is present and authoritative.
###

@step =
  desc: "Run MLX LoRA incremental training using step-local params"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Required scalar params (step-local, global fallback handled by Memo)
    # ------------------------------------------------------------
    batchSize    = M.getStepParam stepName, 'batch_size'
    iters        = M.getStepParam stepName, 'iters'
    maxSeqLength = M.getStepParam stepName, 'max_seq_length'
    learningRate = M.getStepParam stepName, 'learning_rate'

    for v, k in [[batchSize,'batch_size'],[iters,'iters'],[maxSeqLength,'max_seq_length'],[learningRate,'learning_rate']]
      throw new Error "Missing #{stepName}.#{k}" unless v?

    # ------------------------------------------------------------
    # Required file / key params
    # ------------------------------------------------------------
    trainKey = M.getStepParam stepName, 'train_file'
    validKey = M.getStepParam stepName, 'valid_file'
    landKey  = M.getStepParam stepName, 'loraLand'
    modelId  = M.getStepParam stepName, 'model'

    throw new Error "Missing #{stepName}.train_file" unless trainKey?
    throw new Error "Missing #{stepName}.valid_file" unless validKey?
    throw new Error "Missing #{stepName}.loraLand"   unless landKey?
    throw new Error "Missing model"                  unless modelId?

    # ------------------------------------------------------------
    # Load datasets (memo-native)
    # ------------------------------------------------------------
    trainData = M.theLowdown(trainKey).value ? []
    validData = M.theLowdown(validKey).value ? []

    unless Array.isArray(trainData)
      throw new Error "#{trainKey} must be an array"
    unless Array.isArray(validData)
      throw new Error "#{validKey} must be an array"

    console.log "[lora_train]"
    console.log "  train rows:", trainData.length
    console.log "  valid rows:", validData.length

    if trainData.length is 0
      console.log "[lora_train] no new training data — skipping"
      return

    # ------------------------------------------------------------
    # MLX args
    # ------------------------------------------------------------
    adapterKey = "#{landKey}/adapter"

    args =
      train: null
      model: modelId
      data: landKey
      "adapter-path": adapterKey
      "batch-size": batchSize
      iters: iters
      "max-seq-length": maxSeqLength
      "learning-rate": learningRate

    console.log "[lora_train] MLX args:", args

    stdout = M.callMLX "lora", args
    M.saveThis "#{stepName}:stdout", stdout
    return