#!/usr/bin/env coffee
###
       step3_table.coffee  —  TEST PIPELINE  ·  tabular artifact
       =====================================================

  **What this step teaches.** Producing an artifact destined for
  CSV via `meta/csv.coffee`. The recipe declares
  `summary_row: { target: tested/table.json }` — note the target
  is `.json`, not `.csv`. The CSV meta device only fires when the
  key itself ends in `.csv`; this step writes JSON.

  The takeaway: an artifact's **logical name** (`summary_row`),
  its **memo key**, and its **on-disk format** are three
  different things wired through `artifacts:` in the recipe.
  This step writes a memo key; the materialization is `meta/`'s
  job.
###
@step =
  name: 'step3_table'
  desc: 'Create tabular summary from transformed data.'

  action: (M, stepName) ->
    transformedKey = "transformed_data"
    transformedEntry = M.theLowdown transformedKey
    transformed = transformedEntry?.value
    if transformed is undefined
      if typeof transformedEntry?.waitFor is 'function'
        transformed = await transformedEntry.waitFor()
      else if transformedEntry?.notifier?
        transformed = await transformedEntry.notifier
    unless transformed?
      throw new Error "[#{stepName}] Missing input key '#{transformedKey}'"

    row =
      greeting: transformed.greeting
      doubled: transformed.doubled

    M.saveThis "summary_row", row
    M.saveThis "done:#{stepName}", true
    console.log "[#{stepName}] wrote output artifact summary_row"
    return
