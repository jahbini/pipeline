#!/usr/bin/env coffee
###
train.coffee — memo-native MLX LoRA runner (simplified, via M.callMLX)
-----------------------------------------------------------------------
• Executes inside unified pipeline (shared @memo)
• Uses run.experiments_csv as source of training rows
• Filters by only_model_id / only_row from step config
• Calls MLX via M.callMLX "lora", args (no shelling out)
• Drops reporting / eval / val-batch flags (strict MLX arg subset)
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Run MLX LoRA trainings based on experiments.csv (memo-native, simplified)"

  action: (M, stepName) ->

    throw new Error "Missing stepName argument" unless stepName?

    cfg = M?.theLowdown?('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml in memo" unless cfg?

    stepCfg = cfg[stepName]
    throw new Error "Missing step config for '#{stepName}'" unless stepCfg?

    runCfg = cfg['run']
    throw new Error "Missing global 'run' section in experiment.yaml" unless runCfg?

    # ----------------------------------------------------------------
    # Required step-level keys (control which rows to run)
    # ----------------------------------------------------------------
    requiredStep = ['dry_run','only_model_id','only_row']
    for k in requiredStep
      throw new Error "Missing required param '#{k}' in step '#{stepName}'" unless k of stepCfg

    DRY_RUN       = !!stepCfg.dry_run
    ONLY_MODEL_ID = stepCfg.only_model_id   # string or ''
    ONLY_ROW      = stepCfg.only_row        # index or 'None'

    # ----------------------------------------------------------------
    # experiments.csv location from run.*
    # ----------------------------------------------------------------
    EXP_CSV_KEY = runCfg.experiments_csv
    throw new Error "Missing run.experiments_csv" unless EXP_CSV_KEY?

    # Prefer memo; fall back to filesystem if needed
    csvEntry = M.theLowdown(EXP_CSV_KEY)
    csvText  = csvEntry?.value

    if csvText? and typeof csvText is 'string' and csvText.trim().length
      text = csvText
    else if fs.existsSync(EXP_CSV_KEY)
      text = fs.readFileSync(EXP_CSV_KEY, 'utf8')
    else
      throw new Error "experiments.csv missing in memo and on disk: #{EXP_CSV_KEY}"

    # ----------------------------------------------------------------
    # CSV parsing helpers
    # ----------------------------------------------------------------
    readCSVText = (text) ->
      lines = text.split(/\r?\n/).filter (l)-> l.trim().length
      return [] unless lines.length
      headers = lines[0].split(',').map (h)-> h.trim()
      rows = []
      for line in lines.slice(1)
        cols = line.split(',').map (c)-> c.trim()
        row = {}
        for i in [0...headers.length]
          row[headers[i]] = cols[i] ? ''
        # numeric coercions for known fields
        for k in ['epochs','iters','batch_size','grad_accum','max_seq_length','bf16']
          if row[k]? and row[k] isnt ''
            row[k] = parseInt(parseFloat(row[k]))
        for k in ['learning_rate']
          if row[k]? and row[k] isnt ''
            row[k] = parseFloat(row[k])
        rows.push row
      rows

    selectRows = (rows, onlyModel, onlyRowIdx) ->
      # explicit row index wins
      if onlyRowIdx? and String(onlyRowIdx) isnt 'None'
        idx = parseInt(onlyRowIdx)
        return if rows[idx]? then [rows[idx]] else []
      # else filter by model id if provided
      if onlyModel? and String(onlyModel).length
        return rows.filter (r)-> r.model_id is onlyModel
      rows

    # ----------------------------------------------------------------
    # Build MLX args for a single experiments row
    # ----------------------------------------------------------------
    buildLoraArgs = (row) ->
      # Required fields in row
      for k in ['model_id','data_dir','adapter_path','iters','batch_size','max_seq_length','learning_rate']
        throw new Error "experiments.csv row missing required column '#{k}'" unless row[k]?

      args =
        model: row.model_id
        data:  row.data_dir
        train: ''   # presence of flag triggers training in mlx_lm
        "adapter-path":    row.adapter_path
        "batch-size":      row.batch_size
        iters:             row.iters
        "max-seq-length":  row.max_seq_length
        "learning-rate":   row.learning_rate

      args

    ensureDirs = (row) ->
      if row.adapter_path?
        fs.mkdirSync(path.resolve(row.adapter_path), {recursive:true})

    # ----------------------------------------------------------------
    # Run MLX LoRA for a single row
    # ----------------------------------------------------------------
    runLoraForRow = (row) ->
      args = buildLoraArgs(row)
      console.log "\n[MLX lora] model=#{row.model_id}"
      console.log "  data_dir:      #{row.data_dir}"
      console.log "  adapter_path:  #{row.adapter_path}"
      console.log "  iters:         #{row.iters}"
      console.log "  batch_size:    #{row.batch_size}"
      console.log "  max_seq_length:#{row.max_seq_length}"
      console.log "  learning_rate: #{row.learning_rate}"

      if DRY_RUN
        console.log "DRY_RUN=true → skipping actual MLX call."
        return ""

      stdout = M.callMLX "lora", args
      stdout ? ""

    # ----------------------------------------------------------------
    # Main execution
    # ----------------------------------------------------------------
    rows = readCSVText(text)
    if rows.length is 0
      console.log "train: experiments.csv has no data rows; nothing to run."
      M.saveThis "train:status", "empty"
      return

    todo = selectRows(rows, ONLY_MODEL_ID, ONLY_ROW)
    console.log "Found #{rows.length} row(s) in experiments.csv; running #{todo.length} row(s). DRY_RUN=#{DRY_RUN}"

    lastRow  = null
    lastOut  = null

    for i in [0...todo.length]
      row = todo[i]
      console.log "\n=== TRAIN ROW #{i+1}/#{todo.length} ==="
      ensureDirs(row)
      out = runLoraForRow(row)
      lastRow = row
      lastOut = out

    M.saveThis "#{stepName}:last_row", lastRow
    M.saveThis "#{stepName}:stdout",   lastOut
    M.saveThis "train:status", "done"
    console.log "\n📗 train.coffee: completed #{todo.length} row(s)."
    return
