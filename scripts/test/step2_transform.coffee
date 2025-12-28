#!/usr/bin/env coffee
###
Step 2 — transform: read input.json and write derived output
###
@step =
  name: 'step2_transform'
  desc: 'Transform input.json into doubled numeric output.'

  action: (M, stepName) ->
    inputName = M.getStepParam stepName, "input"
    input = (M.theLowdown inputName).value
    xformedName = M.getStepParam stepName, "transformed"
   
    unless input?
      throw new Error "[#{stepName}] Missing memo key input"

    transformed =
      greeting: "#{input.greeting}, world!"
      doubled: input.value * 2

    M.saveThis xformedName, transformed
    console.log "[#{stepName}] wrote ", xformedName
    return
