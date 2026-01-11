#!/usr/bin/env coffee
###
init_hf_to_loraland.coffee
------------------------------------------------------------
Pipeline init step:
• Ensures HF model from experiment exists in loraland/
• Uses snapshot_download (full repo, resumable)
• Idempotent + restart-safe
• Memo is sole source of truth
###

fs   = require 'fs'
path = require 'path'
cp   = require 'child_process'

@step =
  desc: "Initialize base HF model into loraland for offline use"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?
    throw new Error "Memo missing getStepParam()" unless typeof M.getStepParam is 'function'

    # ------------------------------------------------------------
    # Read parameters from Memo
    # ------------------------------------------------------------

    hfModelId = M.getStepParam stepName, 'model'
    loraRoot  = M.getStepParam stepName, 'loraLand'

    throw new Error "Missing model param" unless hfModelId?
    throw new Error "Missing loraland param" unless loraRoot?

    # Normalize model directory name
    modelDirName = hfModelId.replace /\//g, '--'
    targetDir    = path.resolve loraRoot, modelDirName
    M.saveThis "model_dir:#{hfModelId}", targetDir

    # ------------------------------------------------------------
    # Short-circuit if already present
    # ------------------------------------------------------------

    if fs.existsSync(targetDir)
      entries = fs.readdirSync targetDir
      if entries.length > 0
        console.log "[init] Model already present: #{targetDir}"
        console.log "[init] Skipping HF download (offline-safe)."
        return

    # ------------------------------------------------------------
    # Ensure base directory exists
    # ------------------------------------------------------------

    fs.mkdirSync loraRoot, { recursive: true }

    # ------------------------------------------------------------
    # Perform HF snapshot download (synchronous)
    # ------------------------------------------------------------

    console.log "[init] Downloading HF model #{hfModelId}"
    console.log "[init] Target directory: #{targetDir}"

    cmd = [ 'hf', 'download',  "--local-dir=#{targetDir}", hfModelId ]

    cp.execFileSync cmd[0], cmd.slice(1),
      stdio: 'inherit'

    # ------------------------------------------------------------
    # Record result in Memo (filesystem is still the authority)
    # ------------------------------------------------------------

    M.saveThis "model_dir:#{hfModelId}", targetDir
    console.log "[init] HF model materialized locally"

    return
