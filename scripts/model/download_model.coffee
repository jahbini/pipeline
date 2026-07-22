#!/usr/bin/env coffee
###
init_hf_to_loraland.coffee
------------------------------------------------------------
Pipeline init step (HARDENED):
• Uses git + git-lfs (no HF CLI, no Python)
• Detects failures correctly
• Retries 3 times with 10-minute backoff
• Idempotent + restart-safe
• Memo is sole source of truth
###

fs    = require 'fs'
path  = require 'path'
cp    = require 'child_process'

SLEEP_10_MIN = 10 * 60 * 1000
MAX_RETRIES  = 3

sleep = (ms) ->
  end = Date.now() + ms
  while Date.now() < end then null
  return

run = (cmd, args, cwd = null) ->
  cp.execFileSync cmd, args,
    cwd: cwd
    stdio: 'inherit'

runSh = (cmd, cwd = null) ->
  cp.execSync cmd,
    cwd: cwd
    stdio: 'pipe'
    encoding: 'utf8'

provenancePathFor = (targetDir) ->
  path.join targetDir, '.model_provenance.json'

readProvenance = (targetDir) ->
  provPath = provenancePathFor targetDir
  return null unless fs.existsSync provPath
  try
    JSON.parse fs.readFileSync(provPath, 'utf8')
  catch
    throw new Error "Invalid model provenance file: #{provPath}"

writeProvenance = (targetDir, modelId, repoUrl) ->
  provPath = provenancePathFor targetDir
  payload =
    model_id: modelId
    repo_url: repoUrl
    recorded_at: new Date().toISOString()
  fs.writeFileSync provPath, JSON.stringify(payload, null, 2), 'utf8'

stripGitDirectory = (targetDir) ->
  gitDir = path.join targetDir, '.git'
  return unless fs.existsSync gitDir
  run 'rm', ['-rf', gitDir]

modelTail = (modelId) ->
  return '' unless modelId?
  String(modelId).split('/').pop() ? ''

resolveRequestedModelId = (requestedModelId, provenance = null) ->
  requested = String(requestedModelId ? '').trim()
  return requested if requested.includes('/')

  recorded = String(provenance?.model_id ? '').trim()
  if recorded.length and modelTail(recorded) is requested
    return recorded

  requested

@step =
  desc: "Initialize base HF model into loraland (git + lfs, retry-hardened)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?
    throw new Error "Memo missing getStepParam()" unless typeof M.getStepParam is 'function'

    # ------------------------------------------------------------
    # Read parameters from Memo
    # ------------------------------------------------------------

    hfModelIdRaw = M.getStepParam stepName, 'model'
    loraRoot  = M.getStepParam stepName, 'loraLand'

    throw new Error "Missing model param" unless hfModelIdRaw?
    throw new Error "Missing loraLand param" unless loraRoot?

    targetDir = path.resolve loraRoot

    M.saveThis 'modelDir', targetDir
    console.log "model directory",targetDir

    # ------------------------------------------------------------
    # Short-circuit if already present AND non-empty
    # ------------------------------------------------------------

    present = false
    try
      out = runSh "find #{JSON.stringify(targetDir)} -mindepth 1 -maxdepth 1 | head -n 1"
      present = out.trim().length > 0
    catch then present = false
    hasWeights = false
    try
      out = runSh "find #{JSON.stringify(targetDir)} -type f \\( -name '*.safetensors' -o -name '*.bin' \\) | head -n 1"
      hasWeights = out.trim().length > 0
    catch then hasWeights = false

    provenance = readProvenance targetDir if present
    hfModelId = resolveRequestedModelId hfModelIdRaw, provenance
    repoUrl   = "https://huggingface.co/#{hfModelId}"

    if present && hasWeights
      unless provenance?
        throw new Error "[init] Existing model directory has weights but no provenance: #{provenancePathFor(targetDir)}. Verify the model manually and either remove the directory or add matching provenance for #{hfModelId}."
      if provenance.model_id isnt hfModelId
        throw new Error "[init] Existing model directory was recorded for #{provenance.model_id}; requested #{hfModelId}. Remove #{targetDir} if you want to materialize a different base model."

      console.log "[init] Model already present, skipping."
      return

    unless hfModelId.includes '/'
      throw new Error "[init] Model '#{hfModelIdRaw}' is not organization-qualified and no matching provenance was found in #{targetDir}. Use a full Hugging Face model id such as mlx-community/#{hfModelIdRaw}."

    run 'mkdir', ['-p', targetDir]

    # ------------------------------------------------------------
    # Retry loop
    # ------------------------------------------------------------

    lastError = null

    for attempt in [1..MAX_RETRIES]

      console.log "[init] Attempt #{attempt} of #{MAX_RETRIES}"

      try
        # Clean partial state before retry
        try run 'rm', ['-rf', targetDir] catch then null

        # Clone repo
        run 'git', ['clone', '--depth', '1', repoUrl, targetDir]

        # Pull LFS objects
        run 'git', ['lfs', 'pull'], targetDir

        # --------------------------------------------------------
        # Sanity check: repo must contain something real
        # --------------------------------------------------------

        repoHasFiles = false
        try
          out = runSh "find #{JSON.stringify(targetDir)} -mindepth 1 -maxdepth 1 | head -n 1"
          repoHasFiles = out.trim().length > 0
        catch then repoHasFiles = false
        throw new Error "Empty repo after clone" unless repoHasFiles

        hasWeights = false
        try
          out = runSh "find #{JSON.stringify(targetDir)} -type f \\( -name '*.safetensors' -o -name '*.bin' \\) | head -n 1"
          hasWeights = out.trim().length > 0
        catch then hasWeights = false
        throw new Error "No model weights found" unless hasWeights

        writeProvenance targetDir, hfModelId, repoUrl
        stripGitDirectory targetDir

        console.log "[init] Model successfully materialized."
        return

      catch err
        lastError = err
        console.log "[init] ERROR:", err.message

        if attempt < MAX_RETRIES
          console.log "[init] Waiting 10 minutes before retry…"
          sleep SLEEP_10_MIN
        else
          console.log "[init] Exhausted retries."

    # ------------------------------------------------------------
    # Final failure
    # ------------------------------------------------------------

    throw lastError
