#!/usr/bin/env coffee
###
       step9_handoff.coffee  —  TEST PIPELINE  ·  graceful sign-off
       =====================================================

  **What this step teaches.** A pure side-effect step: no `needs:`,
  no `makes:`, just `depends_on: [test8_sqlite]` so it runs last
  and prints a friendly orientation message after the rest of the
  pipeline has succeeded.

  This is the *intentional* alternative to a fail-on-first-run
  placeholder override. A fresh `npx pipeline-runner init` ships
  with `pipeline: test`, so the first thing a new user sees is
  this message — not an error.

  It is also a real example of a step that exists for human
  output rather than data flow. The runner has no special case
  for it; the side-effect is just `console.log`.
###

@step =
  name: 'step9_handoff'
  desc: 'Print a friendly hand-off to the user after the test pipeline succeeds.'

  action: (M, stepName) ->
    console.log """

      🌟  That's the whole pipeline.

         What you just saw:
           - eight steps wired through a single Memo
           - artifacts crossing through `needs` and `makes`
           - truly-async work that didn't block the runner
           - subprocess calls to curl and python
           - sqlite request keys doing the hidden heavy lifting

         Now you see how it works.  Now it's your opportunity.

         Try this next:
           •  Open  override/test.yaml  and change `pipeline:` to one of
              the recipes shipped under  config/.
           •  Or write your own recipe at  config/<yourname>.yaml  and
              `include: [base_ite.yaml]` to skip the boilerplate.
           •  Or drop a custom step at  scripts/<yourname>.coffee  —
              your script wins over the module's shipped one.

         Happy piping.

      """
    M.saveThis "done:#{stepName}", true
    return
