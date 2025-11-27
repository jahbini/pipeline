#!/usr/bin/env coffee
###
Step 2 — transform: read input.json and write derived output
###
@step =
  name: 'step2_transform'
  desc: 'Transform input.json into doubled numeric output.'

  action: (M, stepName) ->
    input = M.theLowdown("data/input.json").value
    unless input?
      throw new Error "[#{stepName}] Missing memo key data/input.json"

    transformed =
      greeting: "#{input.greeting}, world!"
      doubled: input.value * 2

    M.saveThis "data/transformed.json", transformed
    console.log "[#{stepName}] wrote data/transformed.json"
    M.saveThis "done:#{stepName}", true
    return
