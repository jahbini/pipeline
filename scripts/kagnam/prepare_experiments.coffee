#!/usr/bin/env coffee
###
prepare_kagnam_experiments.coffee — clean + memo-native
-------------------------------------------------------
• Reads run.model, run.train_file, run.valid_file directly
• Counts JSONL rows robustly
• Produces experiments.csv (single-row) for KAG LoRA training
• Writes ONLY to memo, not to disk
###
fs   = require 'fs'
path = require 'path'

@step =
  desc: "Prepare experiments.csv for KAGNAM LoRA training (single-model)"

  action: (M, stepName) ->

    # --------------------------
    # Load config + step config
    # --------------------------
    Cfg = M.theLowdown('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml" unless Cfg?

    runCfg = Cfg.run
    throw new Error "Missing run section" unless runCfg?

    stepCfg = Cfg[stepName]
    throw new Error "Missing step config for #{stepName}" unless stepCfg?

    # --------------------------
    # Required run keys
    # --------------------------
    for k in ['model','train_file','valid_file','output_dir','experiments_csv']
      throw new Error "Missing runCfg.#{k}" unless runCfg[k]?

    MODEL_ID   = runCfg.model
    TRAIN_PATH = path.resolve(runCfg.train_file)
    VALID_PATH = path.resolve(runCfg.valid_file)
    OUT_DIR    = path.resolve(runCfg.output_dir)
    EXP_CSV    = runCfg.experiments_csv            # memo key (not disk path)

    # --------------------------
    # Count JSONL lines
    # --------------------------
    countLines = (p) ->
      txt = fs.readFileSync(p, 'utf8')
      txt.split(/\r?\n/).filter((l)-> l.trim().length).length

    trainCount = countLines(TRAIN_PATH)
    validCount = countLines(VALID_PATH)

    dataDir = path.dirname(TRAIN_PATH)

    # --------------------------
    # Required step keys
    # --------------------------
    for k in [
      'epochs','batch_size','grad_accum',
      'max_seq_length','learning_rate',
      'bf16','iters_override'
    ]
      throw new Error "Missing #{k} in #{stepName}" unless stepCfg[k]?

    EPOCHS         = parseInt(stepCfg.epochs)
    BATCH_SIZE     = parseInt(stepCfg.batch_size)
    GRAD_ACCUM     = parseInt(stepCfg.grad_accum)
    MAX_SEQ_LENGTH = parseInt(stepCfg.max_seq_length)
    LEARNING_RATE  = parseFloat(stepCfg.learning_rate)
    BF16           = if String(stepCfg.bf16) in ['1','true','True'] then 1 else 0
    ITERS_OVERRIDE = parseInt(stepCfg.iters_override)

    # --------------------------
    # Compute iterations
    # --------------------------
    estIters = ->
      steps =
        Math.ceil(
          (EPOCHS * Math.max(1, trainCount)) /
          Math.max(1, BATCH_SIZE * GRAD_ACCUM)
        )
      Math.max(10000, steps)

    iters = if ITERS_OVERRIDE > 0 then ITERS_OVERRIDE else estIters()

    estTokens = MAX_SEQ_LENGTH * BATCH_SIZE * GRAD_ACCUM * iters

    modelTag    = MODEL_ID.replace(/\//g, '--')
    adapterPath = path.join(OUT_DIR, modelTag, 'adapter')
    logsDir     = path.join(OUT_DIR, modelTag, 'logs')

    # --------------------------
    # Construct CSV row
    # --------------------------
    row =
      created_utc:  new Date().toISOString().replace(/\.\d+Z$/, 'Z')
      model_id:     MODEL_ID
      data_dir:     dataDir
      train_file:   TRAIN_PATH
      valid_file:   VALID_PATH
      train_examples: trainCount
      valid_examples: validCount
      epochs:       EPOCHS
      iters:        iters
      batch_size:   BATCH_SIZE
      grad_accum:   GRAD_ACCUM
      max_seq_length: MAX_SEQ_LENGTH
      learning_rate:  LEARNING_RATE
      bf16:         BF16
      adapter_path: adapterPath
      log_dir:      logsDir
      est_tokens:   estTokens

    headers = Object.keys(row)
    csv = headers.join(',') + '\n' +
          headers.map((k)-> String(row[k])).join(',') + '\n'

    # ----------------------------------------------------
    # Memo is the source of truth. No disk write allowed.
    # ----------------------------------------------------
    M.saveThis EXP_CSV, csv
    M.saveThis "prepare_kagnam_experiments:last_row", row

    console.log "📘 experiments.csv prepared (memo-key: #{EXP_CSV})"
    return
