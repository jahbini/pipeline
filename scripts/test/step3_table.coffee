#!/usr/bin/env coffee
###
Step 3 — table: generate CSV summary
###
@step =
  name: 'step3_table'
  desc: 'Create tabular summary from transformed data.'

  action: (M, stepName) ->
    t = M.theLowdown("data/transformed.json").value
    unless t?
      throw new Error "[#{stepName}] Missing memo key data/transformed.json"

    rows = [
      { key: "greeting", val: t.greeting }
      { key: "doubled",  val: t.doubled }
    ]

    M.saveThis "reports/summary.csv", rows
    console.log "[#{stepName}] wrote reports/summary.csv"
    M.saveThis "done:#{stepName}", true
    return
