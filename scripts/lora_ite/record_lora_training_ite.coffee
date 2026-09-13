###
  record_lora_training_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  Persists training-run metadata into sqlite via the
  `loraTrainingRun{run_id}.json` request key, and
  appends each trained story to `lora_trained_stories`
  via `trainedStories.jsonl`. This is what makes the
  iterative pipeline pick up where it left off — the
  next `select_lora_stories_ite` skips anything
  recorded here.
###
@step =
  desc: "Record LoRA training metadata into SQLite and materialize trained story ids"

  action: (L) ->
    runRecord = await L.need 'lora_run_record'
    throw new Error "[#{L.stepName}] lora_run_record must be an object" unless runRecord? and typeof runRecord is 'object' and not Array.isArray(runRecord)
    throw new Error "[#{L.stepName}] lora_run_record missing run_id" unless runRecord.run_id?
    throw new Error "[#{L.stepName}] lora_run_record missing story_ids array" unless Array.isArray(runRecord.story_ids)

    # 2026-09-13: belt-and-suspenders. run_lora_train_ite derives its
    # `status` from checkpoint-file existence via L.tools.adapter, but
    # if that derivation ever regresses (or a future producer of
    # lora_run_record forgets it), the pipeline would silently mark
    # 169 stories as trained without an adapter on disk. Re-probe
    # here: no checkpoint file → the run's stories don't get counted
    # as trained. The bad run row is still written so the failure is
    # visible in `lora_training_runs`, but the story usage is not
    # advanced — so re-running elementary can retry cleanly.
    adapterPath = runRecord.adapter_path
    isTestOnly = runRecord.mode is 'test'
    checkpointExists = if adapterPath? then L.tools.adapter.latestCheckpoint(adapterPath)? else false
    runIsReal = isTestOnly or checkpointExists
    unless runIsReal
      console.log "[record_lora_training_ite] REJECTED run #{runRecord.run_id}: no adapter checkpoint at #{adapterPath ? '(none)'} — story usage NOT advanced"
      rejectedRecord = Object.assign {}, runRecord, {status: 'no-adapter', story_ids: []}
      L.saveThis "loraTrainingRun{#{runRecord.run_id}}.json", rejectedRecord
      L.make 'trained_story_ids', []
      L.done()
      return

    L.saveThis "loraTrainingRun{#{runRecord.run_id}}.json", runRecord

    # Bust the Memo cache on the usage view before re-reading it.
    # `select_lora_stories_ite` reads `loraStoryUsage.jsonl` at the
    # start of the recipe (before any training has happened), and
    # Memo caches that pre-training snapshot. Without this forget,
    # the count below is always 0 in a composed recipe like
    # elementary.yaml — even after `loraTrainingRun{id}` above
    # populated `lora_training_run_stories`. Same bug pattern as
    # seed_story_sqlite's stale `allStories.jsonl` cache. Fixed
    # 2026-09-11.
    L.forget? 'loraStoryUsage.jsonl'
    usageEntry = L.theLowdown 'loraStoryUsage.jsonl'
    usageRows = usageEntry?.value
    if usageRows is undefined
      if typeof usageEntry?.waitFor is 'function'
        usageRows = await usageEntry.waitFor()
      else if usageEntry?.notifier?
          usageRows = await usageEntry.notifier

    throw new Error "[#{L.stepName}] loraStoryUsage.jsonl must be an array" unless Array.isArray usageRows

    trainedStoryIDs = []
    for row in usageRows
      storyID = row?.story_id
      useCount = row?.use_count ? 0
      continue unless storyID?
      continue unless useCount > 0
      trainedStoryIDs.push storyID

    console.log "[record_lora_training_ite] recorded run:", runRecord.run_id
    console.log "[record_lora_training_ite] run stories:", runRecord.story_ids.length
    console.log "[record_lora_training_ite] total stories with LoRA usage:", trainedStoryIDs.length

    L.make 'trained_story_ids', trainedStoryIDs
    L.done()
    return
