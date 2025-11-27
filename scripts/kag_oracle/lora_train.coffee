#!/usr/bin/env coffee
###
lora_train.coffee — MLX LoRA incremental training (memo-native)

- No filesystem access (except MLX writing adapter files itself)
- Loads train/valid from memo via @demand
- Uses run.loraLand *as a memo key*, not a local directory path
- Pure MLX call through M.callMLX
###

@step =
  desc: "Run MLX LoRA incremental training using memo-loaded train/valid sets"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load configuration
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName]

    throw new Error "Missing run section"  unless runCfg?
    throw new Error "Missing step config" unless stepCfg?

    modelId   = runCfg.model
    landKey   = runCfg.loraLand              # <-- memo key root
    trainKey  = runCfg.train_file
    validKey  = runCfg.valid_file

    unless modelId? then throw new Error "Missing run.model"
    unless landKey?  then throw new Error "Missing run.loraLand"
    unless trainKey? then throw new Error "Missing run.train_file"
    unless validKey? then throw new Error "Missing run.valid_file"

    # ------------------------------------------------------------
    # Demand-load datasets (memo-native JSONL)
    # ------------------------------------------------------------
    trainEntry = M.demand(trainKey)
    trainData  = trainEntry?.value ? []
    unless Array.isArray(trainData)
      throw new Error "train_file (#{trainKey}) must hold an array"

    validEntry = M.demand(validKey)
    validData  = validEntry?.value ? []
    unless Array.isArray(validData)
      throw new Error "valid_file (#{validKey}) must hold an array"

    console.log "[lora_train]"
    console.log "  train rows:", trainData.length
    console.log "  valid rows:", validData.length

    # ------------------------------------------------------------
    # Build MLX LoRA parameters
    #
    # We give MLX:
    #   --model
    #   --data      (the key it should load: loraLand)
    #   --adapter-path (landKey + '/adapter')
    #
    # MLX’s meta-rule will write out adapter safetensors for us.
    # ------------------------------------------------------------
    adapterKey = "#{landKey}/adapter"   # NOT a directory path — a memo key

    args =
      model: modelId
      data: landKey                     # dataset root (memo key)
      "adapter-path": adapterKey        # memo location where MLX output goes
      "batch-size":     stepCfg.batch_size
      iters:            stepCfg.iters
      "max-seq-length": stepCfg.max_seq_length
      "learning-rate":  stepCfg.learning_rate

    console.log "[lora_train] MLX args:", args

    # ------------------------------------------------------------
    # Run MLX LoRA training
    # ------------------------------------------------------------
    stdout = M.callMLX "lora", args

    # ------------------------------------------------------------
    # Save into memo for inspection
    # ------------------------------------------------------------
    M.saveThis "#{stepName}:stdout", stdout
    M.saveThis "done:#{stepName}", true

    return