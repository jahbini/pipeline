#!/usr/bin/env coffee
###
register.coffee — memo-native checkpoint (2025)
------------------------------------------------
Confirms that experiments.csv exists
validates its header line, computes a lock_hash,
and installs a canonical artifacts registry into memo.

NEVER reads or writes the filesystem.
NEVER falls back to fs if memo entry is missing.

###

path   = require 'path'
crypto = require 'crypto'

@step =
  desc: "Register experiments.csv and record pipeline lock hash (memo-native)"

  action: (M, stepName) ->
    params = (M.theLowdown "params/#{stepName}.json").value

    EXP_CSV_KEY = params.experiments_csv

    # ------------------------------------------------------------
    # Load CSV from memo ONLY
    # ------------------------------------------------------------
    csvEntry = M.theLowdown(EXP_CSV_KEY)
    throw new Error "experiments.csv not found in memo (#{EXP_CSV_KEY})" unless csvEntry?

    console.error "awaiting",stepName,EXP_CSV_KEY unless csvEntry.value
    csv = csvEntry.value ||  await csvEntry.notifier
    
    # ------------------------------------------------------------
    # Compute lock_hash (stable pipeline checksum)
    # ------------------------------------------------------------
    lockHash = crypto.createHash("sha1").update(JSON.stringify(csv), "utf8").digest("hex")

    M.saveThis "lock_hash", lockHash
    M.saveThis "register:experiments_csv", EXP_CSV_KEY

    console.log "Registered experiments.csv 1  row"
    console.log "lock_hash =", lockHash

    # ------------------------------------------------------------
    # Build artifacts registry
    # ------------------------------------------------------------
    ART_PATH = M.getStepParam stepName, "artifacts"  # e.g. "out/artifacts.json"
    throw new Error "Missing run.artifacts" unless ART_PATH?

    OUT_ROOT = path.dirname(csv.adapter_path)

    registry =
      created_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z')
      runs: [
        {
          model_id: M.getStepParam stepName, "model"
          output_root: OUT_ROOT
          adapter_dir: csv.adapter_path
          fused_dir: path.join(OUT_ROOT, "fused")
          quantized_dir: path.join(OUT_ROOT, "quantized")
        }
      ]
    

    # Memo-native save; meta rule handles writing externally
    M.saveThis ART_PATH, registry
    M.saveThis "register:artifacts", ART_PATH

    console.log "Registered artifacts at memo key:", ART_PATH

    return
