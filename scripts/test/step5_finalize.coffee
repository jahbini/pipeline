#!/usr/bin/env coffee
###
Step 5 — finalize: aggregate results
###
@step =
  name: 'step5_finalize'
  desc: 'Aggregate upstream results into final summary.'

  action: (M, stepName) ->
    input  = M.getStepParam stepName, "input"
    trans  = M.getStepParam stepName, "transformed"
    waitFor = M.getStepParam stepName, "wait"
    input = M.theLowdown input
    trans = M.theLowdown trans
    waited = M.theLowdown waitFor
    # if no value wait for that memo entry to be filled
    waited = await waited.notifier unless waited.value

    summary =
      original:  input.value
      doubled:   trans.value
      waited:    waited
      timestamp: new Date().toISOString()

    M.saveThis "data/final_summary.json", summary
    console.log "[#{stepName}] wrote data/final_summary.json"
    return
