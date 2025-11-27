#!/usr/bin/env coffee
###
Step 5 — finalize: aggregate results
###
@step =
  name: 'step5_finalize'
  desc: 'Aggregate upstream results into final summary.'

  action: (M, stepName) ->
    input  = M.theLowdown("data/input.json").value
    trans  = M.theLowdown("data/transformed.json").value
    waited = M.theLowdown("state/wait.json").value

    unless input? and trans? and waited?
      throw new Error "[#{stepName}] Missing prerequisite memo data"

    summary =
      original:  input.value
      doubled:   trans.doubled
      waited:    waited.done
      timestamp: new Date().toISOString()

    M.saveThis "results/final_summary.json", summary
    console.log "[#{stepName}] wrote results/final_summary.json"
    M.saveThis "done:#{stepName}", true
    return
