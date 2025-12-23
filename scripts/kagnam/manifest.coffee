#!/usr/bin/env coffee
###
manifest.coffee — strict memo-native version (2025)
------------------------------------------------------
STEP — Capture system + environment info

Reads:
  experiment.yaml (from memo)

Writes (memo only):
  out/run_manifest.yaml → manifest object
###

fs      = require 'fs'
path    = require 'path'
yaml    = require 'js-yaml'
crypto  = require 'crypto'
child   = require 'child_process'
os      = require 'os'

@step =
  desc: "Capture system, environment, and pip-lock manifest (memo-native)"

  action: (M, stepName) ->

    # ------------------------------------------------------------
    # Load experiment.yaml from memo
    # ------------------------------------------------------------
    cfg = M.theLowdown("experiment.yaml")?.value
    throw new Error "Missing experiment.yaml" unless cfg?

    runCfg  = cfg.run
    stepCfg = cfg[stepName]
    throw new Error "Missing config for '#{stepName}'" unless stepCfg?
    throw new Error "Missing run section" unless runCfg?

    # Required step keys
    unless stepCfg.seed?
      throw new Error "Missing #{stepName}.seed"

    SEED = stepCfg.seed

    # Output metadata lives in memo only
    OUT_KEY = "out/run_manifest.yaml"

    # Logging allowed (eval_dir)
    EVAL_DIR = path.resolve(runCfg.eval_dir)
    fs.mkdirSync(EVAL_DIR, {recursive:true})
    LOG_PATH = path.join(EVAL_DIR, "#{stepName}.log")

    log = (msg) ->
      stamp = new Date().toISOString().replace('T',' ').replace(/\.\d+Z$/,'')
      line  = "[#{stamp}] #{msg}"
      try fs.appendFileSync(LOG_PATH, line+"\n") catch then null
      console.log line

    log "📘 manifest: starting"


    # ------------------------------------------------------------
    # Helpers (no process.env assumptions)
    # ------------------------------------------------------------
    safeExec = (cmd) ->
      try
        res = child.spawnSync(cmd, {shell:true, encoding:'utf8'})
        return [res.status or 1, res.stdout.trim(), res.stderr.trim()]
      catch e
        [1, '', String(e)]

    which = (bin) ->
      try
        res = child.spawnSync("which #{bin}", {shell:true, encoding:'utf8'})
        return res.stdout.trim() or null
      catch
        null

    pip_freeze = ->
      # Try python3; if unavailable, last resort 'python'
      for python of ["python3", "python"]
        p = which(python)
        continue unless p?
        [code,out,err] = safeExec("#{python} -m pip freeze")
        return [code,out,err] if code is 0
      [1,'','no python found']


    # ------------------------------------------------------------
    # System info
    # ------------------------------------------------------------
    platform_info =
      system: os.platform()
      release: os.release()
      version: os.version?() or 'unknown'
      arch: os.arch()
      cpu_model: os.cpus()[0]?.model or 'unknown'

    if platform_info.system.toLowerCase().includes('darwin')
      [code, out, _] = safeExec "sysctl -n machdep.cpu.brand_string"
      platform_info.chip_brand = (if code is 0 then out else null)


    # ------------------------------------------------------------
    # Pip freeze lock (NO disk writes → stored in memo)
    # ------------------------------------------------------------
    [freeze_code, freeze_out, freeze_err] = pip_freeze()

    lock_contents = null
    lock_hash = null

    if freeze_code is 0
      lock_contents = freeze_out.trim() + "\n"
      lock_hash = crypto.createHash('sha256').update(lock_contents).digest('hex')
      log "🔒 pip freeze OK"
    else
      log "⚠️ pip freeze failed: #{freeze_err}"


    # ------------------------------------------------------------
    # Manifest object
    # ------------------------------------------------------------
    manifest =
      timestamp_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z')
      seed: SEED
      platform: platform_info
      pip_lock:
        text: lock_contents
        sha256: lock_hash
      executables:
        node: which("node")
        python3: which("python3")
        pip: which("pip")
      notes: [
        "This manifest anchors reproducibility for this run."
        "Store this with any training or generation outputs."
      ]


    # ------------------------------------------------------------
    # Save to memo (not filesystem)
    # ------------------------------------------------------------
    M.saveThis OUT_KEY, manifest

    log "📗 manifest stored → #{OUT_KEY}"
    return
