#!/usr/bin/env coffee
###
Step 3 — table: generate CSV summary
###
@step =
  name: 'step3_table'
  desc: 'Create tabular summary from transformed data.'

  action: (M, stepName) ->
    summary = M.getStepParam stepName, "summary"
    t = M.getStepParam stepName, "transformed"
    t = M.theLowdown t
    unless t?
      throw new Error "[#{stepName}] Missing memo key transformed"

    rows = [
      { key: "greeting", val: t.greeting }
      { key: "doubled",  val: t.doubled }
    ]

    M.saveThis summary, rows
    console.log "[#{stepName}] wrote", summary
    return
