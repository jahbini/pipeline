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

    L.saveThis "loraTrainingRun{#{runRecord.run_id}}.json", runRecord

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
