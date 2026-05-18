#!/usr/bin/env coffee
###
       step1_setup.coffee  —  TEST PIPELINE  ·  the empty source
       =====================================================

  **What this step teaches.** A pipeline always starts somewhere.
  Step 1 has no `needs:` declared in `config/test.yaml`; it only
  `makes: [input_data]`. So this is the canonical shape of a
  source step:

      action: (M, stepName) ->
        # 1. read params from the recipe YAML
        # 2. build a value
        # 3. M.saveThis <artifact>, <value>
        # 4. M.saveThis "done:<stepName>", true

  **Required-vs-optional params.** `greeting` and `value` are
  declared in the recipe without defaults, so this script throws
  if either is absent. That's the *required-param* pattern; the
  *optional-param* pattern is `M.getStepParam(stepName, key) ? default`.

  Test-pipeline note: the `M` argument is actually the
  `StepLedger` from `pipeline_runner.coffee` §9 — these test
  scripts use the older direct-call surface (`saveThis`,
  `theLowdown`, `getStepParam`) rather than the newer
  `L.param/L.need/L.make` contract API. Both work; new step
  scripts should prefer the contract API because it enforces the
  `needs`/`makes` declaration at runtime.
###
@step =
  name: 'step1_setup'
  desc: 'Generate initial input data for downstream tests.'

  action: (M, stepName) ->
    greeting = M.getStepParam stepName, 'greeting'
    unless greeting?
      throw new Error "[#{stepName}] Missing required key 'greeting'"
    value = M.getStepParam stepName, 'value'
    unless value?
      throw new Error "[#{stepName}] Missing required key 'value'"

    data = { greeting, value }

    M.saveThis "input_data", data
    M.saveThis "done:#{stepName}", true
    console.log "[#{stepName}] wrote output artifact input_data"
    return
