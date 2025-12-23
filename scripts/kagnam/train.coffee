#!/usr/bin/env coffee
###
train_kagnam.coffee — MLX LoRA training using kag_examples
- Uses experiments.csv created by prepare_kagnam_experiments
- Dispatches MLX training via memo key "mlx-lm:lora"
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Run MLX LoRA training for KAG examples (kagnam pipeline)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # -------------------------------------------------------------
    # Load experiment.yaml + run config
    # -------------------------------------------------------------
    cfg = M.theLowdown('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml" unless cfg?

    runCfg = cfg.run
    throw new Error "Missing run{} section" unless runCfg?

    EXP_CSV_KEY = runCfg.experiments_csv
    TRAIN_FILE  = runCfg.train_file     # for clarity, though CSV row has the same
    MODEL_ID    = runCfg.model

    # -------------------------------------------------------------
    # Load experiments.csv FROM MEMO (not disk)
    # -------------------------------------------------------------
    csvText = M.theLowdown(EXP_CSV_KEY)?.value
    throw new Error "experiments.csv missing in memo: #{EXP_CSV_KEY}" unless csvText?

    lines = csvText.trim().split(/\n/)
    headers = lines[0].split(',').map (x)-> x.trim()
    values  = lines[1].split(',').map (x)-> x.trim()

    row = {}
    for v, i in values
      h = headers[i]
      continue unless h?
      row[h] = v

    adapterPath = row.adapter_path
    throw new Error "Missing adapter_path in experiments.csv" unless adapterPath?

    # -------------------------------------------------------------
    # Build MLX LoRA training request
    # -------------------------------------------------------------
    payload =
      op:             "lora"
      model_id:       row.model_id
      data:           row.train_file
      batch_size:     parseInt(row.batch_size)
      iters:          parseInt(row.iters)
      max_seq_length: parseInt(row.max_seq_length)
      grad_accum:     parseInt(row.grad_accum)
      learning_rate:  parseFloat(row.learning_rate)
      adapter_path:   adapterPath

    console.log "train_kagnam → Dispatching LoRA:", payload

    # -------------------------------------------------------------
    # Ask memo’s MLX worker to run LoRA
    # -------------------------------------------------------------
    M.saveThis "mlx-lm:lora", payload

    mo = M.theLowdown "mlx-lm:lora"
    res = await mo.notifier

    if res?.error?
      throw new Error "LoRA training failed: #{res.error}"

    # -------------------------------------------------------------
    # Save results into memo
    # -------------------------------------------------------------
    M.saveThis "train_kagnam:result", res

    console.log "KAG LoRA training finished."
    return
