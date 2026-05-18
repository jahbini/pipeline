#!/usr/bin/env coffee
###
       step2_transform.coffee  —  TEST PIPELINE  ·  needs + makes
       =====================================================

  **What this step teaches.** The simplest "depends on previous
  step" shape: `needs: [input_data]`, `makes: [transformed_data]`.

  **The `await notifier` dance.** This script demonstrates the
  *manual* form of awaiting an upstream artifact:

      entry = M.theLowdown inputKey
      input = entry?.value
      input = await entry.notifier if input is undefined

  When the runner schedules a step, it calls `wireInputsForStep`
  beforehand to make sure every declared `need:` is materialized
  into the Memo. So in practice `entry?.value` is already defined
  by the time this step runs — the `await` branch is defensive,
  not the hot path. The contract-API equivalent is one line:
  `input = await L.need(inputKey)`, which throws if undeclared.
###
@step =
  name: 'step2_transform'
  desc: 'Transform input.json into doubled numeric output.'

  action: (M, stepName) ->
    inputKey = "input_data"
    inputEntry = M.theLowdown inputKey
    input = inputEntry?.value
    if input is undefined
      if typeof inputEntry?.waitFor is 'function'
        input = await inputEntry.waitFor()
      else if inputEntry?.notifier?
        input = await inputEntry.notifier
    unless input?
      throw new Error "[#{stepName}] Missing input key '#{inputKey}'"

    transformed =
      greeting: "#{input.greeting}, world!"
      doubled: input.value * 2

    M.saveThis "transformed_data", transformed
    M.saveThis "done:#{stepName}", true
    console.log "[#{stepName}] wrote output artifact transformed_data"
    return
