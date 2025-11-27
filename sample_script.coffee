#!/usr/bin/env coffee
###
999_template.coffee — Pipeline-Compliant Step Template (Memo-Aware, 2025 Edition)
---------------------------------------------------------------------------------

Use this as the base for any new pipeline step.

Design rules:
  • Called inline by the pipeline runner (require + @step)
  • Receives (M, stepName)
  • No process.env access — reads from memo['experiment.yaml']
  • Deterministic and self-contained
  • Logs under <output>/logs/
  • May safely write to memo for downstream use
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Boilerplate for new memo-aware steps"

  action: (M, stepName) ->

    exp = M.theLowdown('experiment.yaml').value
    runCfg  = exp?.run or {}
    stepCfg = exp?[stepName] or {}

    unless runCfg?.output_dir?
      throw new Error "Missing 'run.output_dir' in experiment.yaml"

    OUT_DIR  = path.resolve(runCfg.output_dir)
    LOG_DIR  = path.join(OUT_DIR, 'logs')
    fs.mkdirSync OUT_DIR, {recursive:true}
    fs.mkdirSync LOG_DIR, {recursive:true}

    INPUT_FILE  = path.resolve(stepCfg.input or path.join(OUT_DIR, runCfg.contract))
    OUTPUT_FILE = path.resolve(stepCfg.output or path.join(OUT_DIR, "#{stepName}_output.json"))

    # --- Logging ---
    LOG_PATH = path.join(LOG_DIR, "#{stepName}.log")
    log = (msg) ->
      stamp = new Date().toISOString().replace('T',' ').replace(/\..+$/,'')
      line  = "[#{stamp}] #{msg}"
      fs.appendFileSync LOG_PATH, line + '\n', 'utf8'
      console.log line

    write_json = (fpath, obj) ->
      try
        fs.writeFileSync fpath, JSON.stringify(obj, null, 2), 'utf8'
        log "[OK] Wrote #{fpath}"
      catch err
        log "[FATAL] Could not write #{fpath}: #{err.message}"
        throw err

    # --- Validation ---
    unless fs.existsSync INPUT_FILE
      log "[FATAL] Missing required input: #{INPUT_FILE}"
      throw new Error "Missing input #{INPUT_FILE}"

    log "[INFO] Starting step '#{stepName}'"
    log "[INFO] Output dir: #{OUT_DIR}"

    # --- Core Logic (replace this section) ---
    processFile = (file) ->
      raw  = fs.readFileSync file, 'utf8'
      data = JSON.parse raw
      result =
        summary: "File has #{Object.keys(data).length} top-level keys"
        timestamp: new Date().toISOString()
      result

    # --- Execution ---
    t0 = Date.now()
    result = processFile INPUT_FILE
    write_json OUTPUT_FILE, result

    # --- Memo bookkeeping ---
    M.saveThis "#{stepName}:output_path", OUTPUT_FILE
    M.saveThis "#{stepName}:result", result
    M.saveThis "done:#{stepName}", true
    log "[INFO] Memo entries recorded."

    # --- Exit Summary ---
    elapsed = ((Date.now() - t0)/1000).toFixed(2)
    log "[INFO] Step runtime: #{elapsed}s"
    log "[INFO] Completed step '#{stepName}' successfully"

    return
