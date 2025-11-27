#!/usr/bin/env coffee
###
Step 1 — setup: create dummy input data (no defaults)
###
@step =
  name: 'step1_setup'
  desc: 'Generate initial input data for downstream tests.'

  action: (M, stepName) ->
    cfg = M.theLowdown('experiment.yaml').value
    stepCfg = cfg?[stepName]
    unless stepCfg?
      throw new Error "[#{stepName}] Missing configuration section in experiment.yaml"

    greeting = stepCfg.greeting
    unless greeting?
      throw new Error "[#{stepName}] Missing required key 'greeting'"

    value = Math.floor(Math.random() * 100)
    data = { greeting, value }

    M.saveThis "data/input.json", data
    console.log "[#{stepName}] wrote data/input.json"
    M.saveThis "done:#{stepName}", true
    console.log "saved the done?"
    return
