#!/usr/bin/env coffee
###
prepare_experiments.coffee — memo-native (single-model)
- Reads contract, catalog, and data_report via M.demand()
- No filesystem access except meta-rules through M.saveThis
- Produces experiments.csv entirely inside memo
###

path = require 'path'

@step =
  desc: "Materialize experiments.csv for MLX LoRA training (single-model)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ----------------------------------------------------------
    # Load experiment.yaml
    # ----------------------------------------------------------
    expEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml in memo" unless expEntry?
    cfg = expEntry.value

    run = cfg.run
    throw new Error "Missing run section" unless run?

    stepCfg = cfg[stepName]
    throw new Error "Missing step config #{stepName}" unless stepCfg?

    # ----------------------------------------------------------
    # Required run.* keys
    # ----------------------------------------------------------
    reqRunKeys = [
      'contract','catalog','report',
      'output_dir','experiments_csv','model'
    ]

    for k in reqRunKeys
      throw new Error "Missing run.#{k}" unless run[k]?

    CONTRACT_KEY = run.contract
    CATALOG_KEY  = run.catalog
    REPORT_KEY   = run.report
    OUT_DIR      = run.output_dir        # pure logical — no fs
    EXP_CSV_KEY  = run.experiments_csv   # memo key only
    MODEL_ID     = run.model

    # ----------------------------------------------------------
    # Load contract, catalog, report
    # ----------------------------------------------------------
    contractEntry = M.demand(CONTRACT_KEY)
    contract = contractEntry?.value
    throw new Error "Missing contract memo: #{CONTRACT_KEY}" unless contract?

    catalogEntry = M.demand(CATALOG_KEY)
    catalog      = catalogEntry?.value

    reportEntry = M.demand(REPORT_KEY)
    report      = reportEntry?.value
    throw new Error "Missing data_report in memo: #{REPORT_KEY}" unless report?

    # ----------------------------------------------------------
    # Resolve TRAIN / VALID filenames in contract
    # ----------------------------------------------------------
    files = {}
    for split, info of contract.filenames
      continue unless info?
      if info.resolved?
        files[split] = info.resolved

    # Normalize: valid/val → validation
    if files.valid? then files.validation = files.valid
    if files.val?   then files.validation = files.val

    # Logical data directory (never used to read FS)
    dataDir = contract.data_dir ? ""

    # ----------------------------------------------------------
    # Determine example counts (prefer catalog → fallback report)
    # ----------------------------------------------------------
    trainCount = null
    validCount = null

    if catalog?.entries?.train?.stats?.num_valid_examples?
      trainCount = parseInt(catalog.entries.train.stats.num_valid_examples)

      ventry = catalog.entries.valid ? catalog.entries.val
      validCount = ventry?.stats?.num_valid_examples ? 0
      validCount = parseInt(validCount)
    else
      # fallback → report
      rtrain = report?.splits?.train?.valid_examples
      throw new Error "Missing train count in report" unless Number.isFinite(rtrain)
      trainCount = parseInt(rtrain)

      vrep = report?.splits?.valid ? report?.splits?.val
      validCount = vrep?.valid_examples ? 0
      validCount = parseInt(validCount)

    # ----------------------------------------------------------
    # Required step params
    # ----------------------------------------------------------
    requiredStepKeys = [
      'epochs','batch_size','grad_accum',
      'max_seq_length','learning_rate','bf16','iters_override'
    ]
    for k in requiredStepKeys
      throw new Error "Missing #{k} in step '#{stepName}'" unless stepCfg[k]?

    EPOCHS         = parseInt(stepCfg.epochs)
    BATCH_SIZE     = parseInt(stepCfg.batch_size)
    GRAD_ACCUM     = parseInt(stepCfg.grad_accum)
    MAX_SEQ_LENGTH = parseInt(stepCfg.max_seq_length)
    LEARNING_RATE  = parseFloat(stepCfg.learning_rate)
    BF16           = if String(stepCfg.bf16).toLowerCase() in ['1','true'] then 1 else 0
    ITERS_OVERRIDE = parseInt(stepCfg.iters_override)

    # ----------------------------------------------------------
    # Compute number of gradient steps
    # ----------------------------------------------------------
    estIters = ->
      steps = Math.ceil(
        (EPOCHS * Math.max(1, trainCount)) /
        Math.max(1, BATCH_SIZE * GRAD_ACCUM)
      )
      Math.max(10000, steps)    # preserve your floor

    iters = if ITERS_OVERRIDE > 0 then ITERS_OVERRIDE else estIters()

    estTokens = MAX_SEQ_LENGTH * BATCH_SIZE * GRAD_ACCUM * iters

    # ----------------------------------------------------------
    # Adapter/log dirs – logical only, no fs creation
    # ----------------------------------------------------------
    modelTag    = MODEL_ID.replace(/\//g, '--')
    adapterPath = path.join(OUT_DIR, modelTag, "adapter")
    logsDir     = path.join(OUT_DIR, modelTag, "logs")

    # ----------------------------------------------------------
    # CSV row
    # ----------------------------------------------------------
    row =
      created_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z')
      model_id: MODEL_ID
      data_dir: dataDir
      train_file: files.train ? ""
      valid_file: files.validation ? ""
      train_examples: trainCount
      valid_examples: validCount
      epochs: EPOCHS
      iters: iters
      batch_size: BATCH_SIZE
      grad_accum: GRAD_ACCUM
      max_seq_length: MAX_SEQ_LENGTH
      learning_rate: LEARNING_RATE
      bf16: BF16
      adapter_path: adapterPath
      log_dir: logsDir
      est_tokens: estTokens

    # ----------------------------------------------------------
    # CSV string
    # ----------------------------------------------------------
    headers = Object.keys(row)
    csv =
      headers.join(',') + '\n' +
      headers.map((k)-> String(row[k])).join(',') + '\n'

    # ----------------------------------------------------------
    # Save to memo (the new truth)
    # ----------------------------------------------------------
    M.saveThis EXP_CSV_KEY, csv
    M.saveThis "prepare_experiments:last_row", row
    M.saveThis "done:#{stepName}", true

    console.log "experiments.csv materialized → memo key #{EXP_CSV_KEY}"
    return