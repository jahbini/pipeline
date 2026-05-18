#!/usr/bin/env coffee
###
       step7_python.coffee  —  TEST PIPELINE  ·  invoke project Python
       =====================================================

  **What this step teaches.** Spawning the project's `.venv`
  Python interpreter from inside a new-style CoffeeScript step.
  This is the model every MLX-touching step should use, because
  `pipeline_runner.coffee` §2 has already verified at startup
  that `.venv` exists and has the pinned packages installed.

  **`resolvePython` is duplicated here.** The runner has its own
  version (with EXEC fallback and pinned-version validation);
  this script only needs the CWD lookup, so it carries a 5-line
  copy. When the runner becomes an npm module, this helper moves
  to a public export and steps `require('pipeline-runner/python')`
  instead. Until then the duplication is intentional: a step
  should not reach into the runner's private internals.

  Like `step6_curl`, this step captures-not-throws on subprocess
  failure — see that step for the rationale.
###
{ spawnSync } = require 'child_process'
fs = require 'fs'
path = require 'path'

resolvePython = ->
  candidates = [
    path.join(process.cwd(), '.venv', 'bin', 'python')
    path.join(process.cwd(), '.venv', 'bin', 'python3')
  ].filter(Boolean)

  for candidate in candidates when fs.existsSync(candidate)
    return candidate

  throw new Error "Expected project virtualenv at #{path.join(process.cwd(), '.venv')}"

@step =
  name: 'step7_python'
  desc: 'Run Python interpreter and capture version.'

  action: (M, stepName) ->
    console.log "[#{stepName}] querying Python version..."
    inputKey = "curl_result"
    inputEntry = M.theLowdown inputKey
    inputVal = inputEntry?.value
    if inputVal is undefined
      if typeof inputEntry?.waitFor is 'function'
        inputVal = await inputEntry.waitFor()
      else if inputEntry?.notifier?
        inputVal = await inputEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{inputKey}'" if inputVal is undefined

    cmd  = resolvePython()
    args = ['-V']
    result = spawnSync(cmd, args, encoding: 'utf8')

    if result.error
      console.error "[#{stepName}] Python failed:", result.error
      M.saveThis "python_result", { status: 'failed', error: String(result.error) }
      M.saveThis "done:#{stepName}", true
      return

    output = (result.stdout or result.stderr).trim()
    console.log "[#{stepName}] Python responded:", output

    M.saveThis "python_result", { status: 'ok', version: output }
    M.saveThis "done:#{stepName}", true
    return
