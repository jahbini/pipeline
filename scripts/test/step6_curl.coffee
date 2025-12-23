#!/usr/bin/env coffee
###
Step 6 — curl: external network test
###
{ spawnSync } = require 'child_process'

@step =
  name: 'step6_curl'
  desc: 'Spawn a curl request and memoize its result.'

  action: (M, stepName) ->
    console.log "[#{stepName}] running curl..."

    cmd  = 'curl'
    args = ['-sI', 'https://example.com']
    result = spawnSync(cmd, args, encoding: 'utf8')

    if result.error
      console.error "[#{stepName}] curl failed:", result.error
      M.saveThis "curl_result.json", { status: 'failed', error: String(result.error) }
      return

    output = result.stdout.trim()
    console.log "[#{stepName}] curl completed; length:", output.length

    M.saveThis "curl_result.json", { status: 'ok', output }
    return
