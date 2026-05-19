###
  download_model.coffee  —  DOWNLOAD_MODEL pipeline step
  =====================================================

  Fetches a HuggingFace model into a project-relative directory
  via the project's venv `huggingface-cli`. Operates entirely on
  disk; produces no Memo artifacts beyond the step's `done` marker.

  **Why this exists.** Direct `huggingface-cli download --local-dir`
  invocations from a shell script (or postinstall hook) are brittle:
  the resulting directory used to be HF-cache symlinks that broke if
  you moved the folder. Modern `huggingface_hub` versions default to
  real copies, but we route the call through a runner step anyway
  so it benefits from:
    - the `restart_here` / state protocol if the download is
      interrupted partway through
    - the runner's UI surface (logs, status, abort)
    - per-project override.yaml customization (model name,
      destination dir)

  **Step params:**
    model         required — HF repo path (e.g. Qwen/Qwen3-4B-Instruct-2507)
    download_dir  default: build/model  (relative to project CWD)
###
{ spawnSync } = require 'child_process'
fs = require 'fs'
path = require 'path'

resolveHfCli = ->
  candidates = [
    path.join(process.cwd(), '.venv', 'bin', 'huggingface-cli')
  ]
  for c in candidates when fs.existsSync(c)
    return c
  throw new Error "huggingface-cli not found at #{candidates[0]} — is the project's .venv set up?"

@step =
  name: 'download_model'
  desc: 'Download a HuggingFace model into a project-relative directory.'

  action: (M, stepName) ->
    model = M.getStepParam stepName, 'model'
    unless model? and String(model).trim().length
      throw new Error "[#{stepName}] missing required param 'model' (e.g. Qwen/Qwen3-4B-Instruct-2507)"

    downloadDir = M.getStepParam(stepName, 'download_dir') ? 'build/model'
    fullDir = path.resolve process.cwd(), downloadDir
    fs.mkdirSync fullDir, recursive: true

    hfCli = resolveHfCli()

    console.log "[#{stepName}] downloading #{model} → #{fullDir}"
    result = spawnSync hfCli, ['download', String(model), '--local-dir', fullDir],
      encoding: 'utf8'
      stdio: 'inherit'

    if result.error?
      throw new Error "[#{stepName}] download failed: #{result.error.message}"
    if result.status isnt 0
      throw new Error "[#{stepName}] download failed: exit #{result.status}"

    console.log "[#{stepName}] complete: #{fullDir}"
    M.saveThis "done:#{stepName}", true
    return
