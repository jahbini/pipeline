#!/usr/bin/env coffee
###
Step 1 — setup: create dummy input data (no defaults)
###
@step =
  name: 'step1_setup'
  desc: 'Generate initial input data for downstream tests.'

  action: (M, stepName) ->
    greeting = M.getStepParam stepName, 'greeting'
    unless greeting?
      throw new Error "[#{stepName}] Missing required key 'greeting'"

    value = Math.floor(Math.random() * 100)
    data = { greeting, value }

    M.saveThis "data/input.json", data
    console.log "[#{stepName}] wrote data/input.json"
    return
