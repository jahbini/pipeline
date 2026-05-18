#!/usr/bin/env coffee
###
       step6_curl.coffee  —  TEST PIPELINE  ·  external subprocess (sync)
       =====================================================

  **What this step teaches.** Calling out to a shell command
  (`curl` here) from inside a new-style step. The pattern is
  plain Node: `require('child_process').spawnSync`, with
  `encoding: 'utf8'` so stdout/stderr come back as strings.

  **Error capture, not error throw.** This step *does not*
  propagate a curl failure to the pipeline — it records
  `{ status: 'failed', error }` into the `curl_result` artifact
  and continues. That's a deliberate choice for a teaching
  example: external-network steps fail often and the
  downstream consumer should see the failure, not have the
  whole pipeline crash. Production steps that genuinely need
  the network result should `L.fail(err)` instead.
###
{ spawnSync } = require 'child_process'

@step =
  name: 'step6_curl'
  desc: 'Spawn a curl request and memoize its result.'

  action: (M, stepName) ->
    console.log "[#{stepName}] running curl..."
    inputKey = "final_summary_json"
    inputEntry = M.theLowdown inputKey
    inputVal = inputEntry?.value
    if inputVal is undefined
      if typeof inputEntry?.waitFor is 'function'
        inputVal = await inputEntry.waitFor()
      else if inputEntry?.notifier?
        inputVal = await inputEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{inputKey}'" if inputVal is undefined

    cmd  = 'curl'
    args = ['-sI', 'https://example.com']
    result = spawnSync(cmd, args, encoding: 'utf8')

    if result.error
      console.error "[#{stepName}] curl failed:", result.error
      M.saveThis "curl_result", { status: 'failed', error: String(result.error) }
      M.saveThis "done:#{stepName}", true
      return

    output = result.stdout.trim()
    console.log "[#{stepName}] curl completed; length:", output.length

    M.saveThis "curl_result", { status: 'ok', output }
    M.saveThis "done:#{stepName}", true
    return
