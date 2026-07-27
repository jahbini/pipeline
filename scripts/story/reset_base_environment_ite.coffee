fs = require 'fs'
path = require 'path'

MAX_CYCLES = 10
ADAPTER_FILE = 'build/adapter/adapters.safetensors'

@step =
  desc: "Cycle-cap guard + adapter-aligned lora DB reset (if adapter wiped, reset training-run + story-usage rows)"

  action: (S) ->
    adapterFullPath = path.join(process.cwd(), ADAPTER_FILE)
    adapterPresent = fs.existsSync adapterFullPath

    unless adapterPresent
      # Adapter was deliberately wiped → align DB state: clear
      # lora_training_runs, lora_training_run_stories, lora_story_usage,
      # lora_trained_stories so the new adapter starts from a fresh
      # story-rotation pool too.
      console.log "[reset_base_environment_ite] adapter missing; resetting lora DB tracking"
      S.saveThis 'loraCycleReset.json',
        mode: 'full'
        reset_at: new Date().toISOString()
      S.done()
      return

    runsEntry = S.theLowdown 'loraTrainingRuns.jsonl'
    runsRows = runsEntry?.value
    runsRows = [] unless Array.isArray runsRows

    completedCycles = runsRows.length
    console.log "[reset_base_environment_ite] completed cycles:", completedCycles, "cap:", MAX_CYCLES

    if completedCycles >= MAX_CYCLES
      S.saveThis 'pipeline:shutdown',
        by: S.stepName
        reason: "cycle cap reached: #{completedCycles} of #{MAX_CYCLES} loraTrainingRuns"
        timestamp: new Date().toISOString()
      S.done()
      return

    S.done()
    return
