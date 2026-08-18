#!/usr/bin/env coffee
###
init_hf_to_loraland.coffee
------------------------------------------------------------
Pipeline init step (HARDENED):
• Uses git + git-lfs only
• Downloads public Hugging Face repositories anonymously
• Prevents interactive credential prompts
• Separates Git clone from Git LFS transfer
• Detects failures correctly
• Retries 3 times with 10-minute backoff
• Idempotent + restart-safe
• Memo is sole source of truth
###

fs   = require 'fs'
path = require 'path'
cp   = require 'child_process'

# Retry policy — keep in sync with `tools/retry_policy.coffee`
# (the async twin used by meta/hfchat). Not require()'d here
# because step scripts are location-anonymous (see
# GPT/CONVENTIONS.md — no path-relative requires).
SLEEP_10_MIN = 10 * 60 * 1000
MAX_RETRIES  = 3

# Synchronous sleep without consuming a CPU core.
sleepBuffer = new Int32Array new SharedArrayBuffer 4

sleep = (ms) ->
  Atomics.wait sleepBuffer, 0, 0, ms
  return

run = (cmd, args, cwd = null, extraEnv = {}) ->
  env = Object.assign {}, process.env, extraEnv

  cp.execFileSync cmd, args,
    cwd: cwd
    stdio: 'inherit'
    env: env

runSh = (cmd, cwd = null, extraEnv = {}) ->
  env = Object.assign {}, process.env, extraEnv

  cp.execSync cmd,
    cwd: cwd
    stdio: 'pipe'
    encoding: 'utf8'
    env: env

provenancePathFor = (targetDir) ->
  # Visible (no leading dot) so `ls` shows it and humans can spot it
  # without `ls -la`. Written read-only (0o444) after each successful
  # download, matching the "read-only like the model itself" rule —
  # see writeProvenance below. Renamed from `.model_provenance.json`
  # 2026-08-05; see GPT/model_identity.md.
  path.join targetDir, 'model_provenance.json'

readProvenance = (targetDir) ->
  provPath = provenancePathFor targetDir
  return null unless fs.existsSync provPath

  try
    JSON.parse fs.readFileSync provPath, 'utf8'
  catch err
    throw new Error "Invalid model provenance file: #{provPath}: #{err.message}"

writeProvenance = (targetDir, modelId, repoUrl) ->
  provPath = provenancePathFor targetDir

  payload =
    model_id: modelId
    repo_url: repoUrl
    recorded_at: new Date().toISOString()

  # Ensure write succeeds even if a prior run left a read-only file
  # in place (chmod first, then write, then re-chmod).
  if fs.existsSync provPath
    try fs.chmodSync provPath, 0o644 catch then null

  fs.writeFileSync(
    provPath
    JSON.stringify(payload, null, 2)
    'utf8'
  )

  # Lock read-only so a stray `cat > model_provenance.json` cannot
  # corrupt the provenance without an explicit chmod. Matches the
  # "read-only like the model after it is loaded" rule.
  try fs.chmodSync provPath, 0o444 catch then null

stripGitDirectory = (targetDir) ->
  gitDir = path.join targetDir, '.git'
  return unless fs.existsSync gitDir

  fs.rmSync gitDir,
    recursive: true
    force: true

modelTail = (modelId) ->
  return '' unless modelId?
  String(modelId).split('/').pop() ? ''

resolveRequestedModelId = (requestedModelId, provenance = null) ->
  requested = String(requestedModelId ? '').trim()
  return requested if requested.includes '/'

  recorded = String(provenance?.model_id ? '').trim()

  if recorded.length and modelTail(recorded) is requested
    return recorded

  requested

directoryHasAnyFiles = (targetDir) ->
  return false unless fs.existsSync targetDir

  entries = fs.readdirSync targetDir
  entries.length > 0

findWeightFile = (rootDir) ->
  return null unless fs.existsSync rootDir

  stack = [rootDir]

  while stack.length
    current = stack.pop()

    for entry in fs.readdirSync current, withFileTypes: true
      fullPath = path.join current, entry.name

      if entry.isDirectory()
        continue if entry.name is '.git'
        stack.push fullPath

      else if entry.isFile()
        lower = entry.name.toLowerCase()

        if lower.endsWith('.safetensors') or lower.endsWith('.bin')
          return fullPath

  null

removeTargetDirectory = (targetDir) ->
  return unless fs.existsSync targetDir

  fs.rmSync targetDir,
    recursive: true
    force: true

# Prevent Git from invoking terminal or graphical credential prompts.
gitBaseEnv =
  GIT_TERMINAL_PROMPT: '0'
  GIT_ASKPASS: '/usr/bin/false'
  SSH_ASKPASS: '/usr/bin/false'
  GCM_INTERACTIVE: 'Never'

# Keep Git LFS from downloading weights automatically during clone.
gitCloneEnv = Object.assign {}, gitBaseEnv,
  GIT_LFS_SKIP_SMUDGE: '1'

# Disable inherited credentials and authorization headers for public repos.
gitPublicArgs = [
  '-c', 'credential.helper='
  '-c', 'http.extraHeader='
]

@step =
  desc: "Initialize base HF model into loraland (git + lfs, retry-hardened)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?
    unless typeof M.getStepParam is 'function'
      throw new Error "Memo missing getStepParam()"

    # ------------------------------------------------------------
    # Read parameters from Memo
    # ------------------------------------------------------------

    hfModelIdRaw = M.getStepParam stepName, 'model'
    throw new Error "Missing model param" unless hfModelIdRaw?

    # Path resolution (2026-08-19):
    #   1. Explicit `download_dir` (or legacy `loraLand`) → wins.
    #   2. Otherwise, if $MODELS (or `models_root` param) is set,
    #      derive HF-cache-shaped path:
    #        <root>/hub/models--<org>--<name>/
    #      This mirrors the HuggingFace hub layout so multiple base
    #      models coexist in one shared cache. Set HF_HOME=$MODELS
    #      and HF's own snapshot_download lands things here too.
    #   3. Legacy fallback: `build/model`.
    explicit  = (M.getStepParam(stepName, 'download_dir') ? M.getStepParam(stepName, 'loraLand'))
    modelsRoot = M.getStepParam(stepName, 'models_root') ? process.env.MODELS

    targetDir = if explicit?
      path.resolve String(explicit)
    else if modelsRoot?
      [org, name] = String(hfModelIdRaw).split('/')
      unless org and name
        throw new Error "model '#{hfModelIdRaw}' must be organization/name to derive a $MODELS-based path"
      path.resolve String(modelsRoot), 'hub', "models--#{org}--#{name}"
    else
      path.resolve 'build/model'

    M.saveThis 'modelDir', targetDir
    console.log "[init] Model directory:", targetDir

    # ------------------------------------------------------------
    # Inspect existing local state
    # ------------------------------------------------------------

    present    = directoryHasAnyFiles targetDir
    weightFile = findWeightFile targetDir
    hasWeights = weightFile?

    provenance = null
    provenance = readProvenance targetDir if present

    hfModelId = resolveRequestedModelId hfModelIdRaw, provenance
    repoUrl   = "https://huggingface.co/#{hfModelId}"

    if present and hasWeights
      unless provenance?
        throw new Error """
        [init] Existing model directory has weights but no provenance:
        #{provenancePathFor(targetDir)}

        Verify the model manually and either remove the directory or add
        matching provenance for #{hfModelId}.
        """

      if provenance.model_id isnt hfModelId
        throw new Error """
        [init] Existing model directory was recorded for:
        #{provenance.model_id}

        Requested:
        #{hfModelId}

        Remove #{targetDir} to materialize a different base model.
        """

      console.log "[init] Model already present."
      console.log "[init] Weight file:", weightFile
      console.log "[init] Skipping download."
      return

    # ─────────────────────────────────────────────────────────────
    # GUARD (2026-08-05)
    # ─────────────────────────────────────────────────────────────
    # If we reach this point the target dir was NOT usable-as-is:
    # either empty (fine — download proceeds), or PARTIALLY populated
    # (present, no weight file, or present-with-weights whose
    # provenance branch above did not return — meaning the provenance
    # guard did not throw either, and we're in a state the retry loop
    # auto-wipes via removeTargetDirectory.
    #
    # Auto-wiping without asking is what surprises the human after a
    # killed download: the retry step nukes a directory whose true
    # contents nobody has verified. Require an explicit opt-in.
    #
    # Escape hatch: `allow_overwrite: true` in the step's params
    # (drop it in override.yaml when you actually want the wipe).
    allowOverwrite = M.getStepParam(stepName, 'allow_overwrite') is true

    if present and not allowOverwrite
      state = if hasWeights
        "has weights (but did not match the provenance path above)"
      else
        "is partially populated (no recognizable weight file)"
      entries = try (fs.readdirSync targetDir).slice(0, 8).join(', ') catch then '?'
      throw new Error """
      [init] Refusing to overwrite existing model directory:
      #{targetDir}

      The directory #{state}. That state can be the debris of a
      killed download OR a real model whose provenance was not
      recorded — the runner cannot tell which by inspection, and
      auto-wiping would risk destroying a good model.

      Contents (first entries): #{entries}

      To proceed, either:
        1. Remove the directory manually:
             rm -rf "#{targetDir}"
           then re-run this step, OR
        2. Set `allow_overwrite: true` in the download_model step's
           override to authorize the wipe explicitly.
      """

    unless hfModelId.includes '/'
      throw new Error """
      [init] Model '#{hfModelIdRaw}' is not organization-qualified and no
      matching provenance was found in #{targetDir}.

      Use a full Hugging Face model ID such as:
      mlx-community/#{hfModelIdRaw}
      """

    parentDir = path.dirname targetDir
    fs.mkdirSync parentDir,
      recursive: true

    console.log "[init] Model ID:", JSON.stringify hfModelId
    console.log "[init] Repository:", JSON.stringify repoUrl

    # ------------------------------------------------------------
    # Retry loop
    # ------------------------------------------------------------

    lastError = null

    for attempt in [1..MAX_RETRIES]

      console.log "[init] Attempt #{attempt} of #{MAX_RETRIES}"

      try
        # Clean partial state before every attempt.
        removeTargetDirectory targetDir

        # --------------------------------------------------------
        # Verify that the exact repository URL exists.
        # This also produces a clearer failure before cloning.
        # --------------------------------------------------------

        console.log "[init] Checking repository..."

        run(
          'git'
          gitPublicArgs.concat [
            'ls-remote'
            '--exit-code'
            repoUrl
            'HEAD'
          ]
          null
          gitBaseEnv
        )

        # --------------------------------------------------------
        # Clone repository metadata without automatic LFS smudging.
        # --------------------------------------------------------

        console.log "[init] Cloning repository..."

        run(
          'git'
          gitPublicArgs.concat [
            'clone'
            '--depth', '1'
            '--no-tags'
            '--single-branch'
            repoUrl
            targetDir
          ]
          null
          gitCloneEnv
        )

        # --------------------------------------------------------
        # Download Git LFS model objects explicitly.
        # --------------------------------------------------------

        console.log "[init] Pulling Git LFS objects..."

        run(
          'git'
          gitPublicArgs.concat [
            'lfs'
            'pull'
          ]
          targetDir
          gitBaseEnv
        )

        # Ensure all LFS pointer files are materialized.
        console.log "[init] Checking out Git LFS objects..."

        run(
          'git'
          gitPublicArgs.concat [
            'lfs'
            'checkout'
          ]
          targetDir
          gitBaseEnv
        )

        # --------------------------------------------------------
        # Sanity checks
        # --------------------------------------------------------

        unless directoryHasAnyFiles targetDir
          throw new Error "Empty repository after clone"

        weightFile = findWeightFile targetDir

        unless weightFile?
          throw new Error """
          No model weights found after Git LFS pull.

          Expected at least one:
          • *.safetensors
          • *.bin
          """

        console.log "[init] Found weight file:", weightFile

        # Record authority before removing Git metadata.
        writeProvenance targetDir, hfModelId, repoUrl

        # The resulting model directory is now an ordinary local model,
        # not a working Git checkout.
        stripGitDirectory targetDir

        console.log "[init] Model successfully materialized."
        console.log "[init] Local authority:", targetDir
        return

      catch err
        lastError = err

        console.error "[init] ERROR:", err.message

        if attempt < MAX_RETRIES
          console.log "[init] Waiting 10 minutes before retry..."
          sleep SLEEP_10_MIN
        else
          console.log "[init] Exhausted retries."

    # ------------------------------------------------------------
    # Final failure
    # ------------------------------------------------------------

    throw lastError