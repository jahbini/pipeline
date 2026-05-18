###
       step4_wait.coffee  —  TEST PIPELINE  ·  truly async step
       =====================================================

  **What this step teaches.** The runner's new-style loader
  `await`s the Promise returned by `action()`, so a step can do
  *real* async work — `setTimeout`, network I/O, a long-running
  computation — without blocking the runner's event loop.

  **Pattern:** return a `new Promise (resolve) -> ... resolve()`
  and only mark `done:<stepName>` inside the callback. This is
  also the model for cancellation: if you ever wire one, the
  resolve/reject from this Promise is the surface the runner
  should observe.

  No `needs:` is declared (this step demonstrates a synchronization
  point that doesn't consume upstream artifacts), but `depends_on:
  [step3_table]` keeps it serialized.
###
@step =
  name: 'step4_wait'
  desc: 'Simulate time-delayed computation before next step.'

  action: (M, stepName) ->
    console.log "[#{stepName}] simulating work..."
    new Promise (resolve) ->
      payload = 
        done: true
        timestamp: new Date().toISOString()
      setTimeout ->
        M.saveThis "wait_data", payload
        M.saveThis "done:#{stepName}", true
        console.log "[#{stepName}] completed wait phase"
        resolve()
      , 1000
