###
Step 4 — wait: simulate asynchronous work
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
        M.saveThis "data/wait.json", payload
        console.log "[#{stepName}] completed wait phase"
        resolve()
      , 1000
