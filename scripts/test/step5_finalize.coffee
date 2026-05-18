#!/usr/bin/env coffee
###
       step5_finalize.coffee  —  TEST PIPELINE  ·  one step → many artifacts
       =====================================================

  **What this step teaches.** A step may declare multiple
  `makes:` and write to all of them. Here, one summary object
  fans out to three artifacts (`final_summary_json`,
  `final_summary_yaml`, `final_summary_csv`) which the recipe
  then materializes through three different meta devices —
  same source data, three on-disk projections.

  Also demonstrates the **multi-input pattern** — `readInput` is
  a tiny inline helper that wraps the `await notifier` dance for
  three different artifacts. With the contract API this is just
  three `await L.need(...)` calls.

  **Common gotcha.** The recipe must list every output in `makes:`.
  A step that writes to a `done:<stepName>` key (which this one
  does on line 36) does NOT count as `makes:` — that's the
  step-lifecycle key, not an artifact.
###
@step =
  name: 'step5_finalize'
  desc: 'Aggregate upstream results into final summary.'

  action: (M, stepName) ->
    readInput = (key) ->
      memoKey = key
      entry = M.theLowdown memoKey
      value = entry?.value
      if value is undefined
        if typeof entry?.waitFor is 'function'
          value = await entry.waitFor()
        else if entry?.notifier?
          value = await entry.notifier
      throw new Error "[#{stepName}] Missing input key '#{memoKey}'" if value is undefined
      value

    inputVal = await readInput 'input_data'
    transformedVal = await readInput 'transformed_data'
    waited = await readInput 'wait_data'

    summary =
      original:  inputVal
      doubled:   transformedVal?.doubled
      transformed: transformedVal
      waited:    waited
      timestamp: new Date().toISOString()

    M.saveThis "final_summary_json", summary
    M.saveThis "final_summary_yaml", summary
    M.saveThis "final_summary_csv", summary
    M.saveThis "done:#{stepName}", true
    console.log "[#{stepName}] wrote output artifacts final_summary_*"
    return
