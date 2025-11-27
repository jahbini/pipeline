#!/usr/bin/env coffee
###
rotate_merged.coffee — rotate merged → train; old train → valid (memo-native)
###

@step =
  desc: "Rotate merged → train.jsonl; old train appended → valid.jsonl (memo-pure)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load config from memo
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml in memo" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName] ? {}

    for k in ['merged_segments','train_file','valid_file']
      throw new Error "Missing run.#{k}" unless runCfg[k]?

    mergedKey = runCfg.merged_segments
    trainKey  = runCfg.train_file
    validKey  = runCfg.valid_file

    # ------------------------------------------------------------
    # Demand load all three arrays (JSONL)
    # ------------------------------------------------------------
    mergedEntry = M.demand(mergedKey)
    mergedRows  = mergedEntry?.value ? []
    unless Array.isArray(mergedRows)
      throw new Error "Merged rows (#{mergedKey}) must be array"

    trainEntry = M.demand(trainKey)
    oldTrain   = trainEntry?.value ? []
    oldTrain   = [] unless Array.isArray(oldTrain)

    validEntry = M.demand(validKey)
    oldValid   = validEntry?.value ? []
    oldValid   = [] unless Array.isArray(oldValid)

    # ------------------------------------------------------------
    # Rotation:
    #   new train = fresh merged rows
    #   new valid = existing valid + prior train
    # ------------------------------------------------------------
    newTrain = mergedRows.slice()
    newValid = oldValid.concat(oldTrain)

    console.log "[rotate_merged]"
    console.log "  merged rows:", mergedRows.length
    console.log "  old train:", oldTrain.length
    console.log "  old valid:", oldValid.length
    console.log "  → new train:", newTrain.length
    console.log "  → new valid:", newValid.length

    # ------------------------------------------------------------
    # Persist via memo (JSONL meta rule handles disk)
    # ------------------------------------------------------------
    M.saveThis trainKey, newTrain
    M.saveThis validKey, newValid

    M.saveThis "done:#{stepName}", true
    return