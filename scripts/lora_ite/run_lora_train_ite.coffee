###
  run_lora_train_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  The actual training spawn. Calls `mlx_lm.lora` with
  the dataset shards built by `build_lora_dataset_ite`,
  optionally resuming from a prior adapter checkpoint
  via `L.tools.adapter.resolveResumeFile`. Capture stdout
  for the training-run record. Among the longest-running
  steps in any pipeline; treat it as a black box and let
  the subprocess do its thing.

  Adapter sniffing (checkpoint discovery, adapter_config
  presence) lives in `tools/adapter.coffee` and is reached
  through `L.tools.adapter.*`. See GPT/CONVENTIONS.md
  § "Tools" for the resolver, and "fs stinginess in step
  scripts" for why those probes don't belong here.
###

@step =
  desc: "Run MLX LoRA training using direct Memo access"

  action: (L) ->
    cycleState = await L.need 'lora_cycle_state'
    selectedStoryIDs = await L.need 'selected_story_ids'
    trainRows = await L.need 'train_rows'
    validRows = await L.need 'valid_rows'
    testRows = await L.need 'test_rows'

    throw new Error "[#{L.stepName}] lora_cycle_state must be an object" unless cycleState? and typeof cycleState is 'object' and not Array.isArray(cycleState)
    throw new Error "[#{L.stepName}] selected_story_ids must be an array" unless Array.isArray selectedStoryIDs
    throw new Error "[#{L.stepName}] train_rows must be an array" unless Array.isArray trainRows
    throw new Error "[#{L.stepName}] valid_rows must be an array" unless Array.isArray validRows
    throw new Error "[#{L.stepName}] test_rows must be an array" unless Array.isArray testRows

    testOnly = L.param 'test_only', false
    adapterPath = L.param 'adapter_path'
    resumeFile = L.param 'resume_adapter_file'
    loraLand = L.param 'loraLand'
    trainingDir = L.param 'training_dir'
    modelDir = loraLand

    throw new Error "[#{L.stepName}] Missing model directory" unless modelDir?
    throw new Error "[#{L.stepName}] Missing training_dir" unless trainingDir?

    actualResumeFile = if cycleState.reset_this_run is true then null else L.tools.adapter.resolveResumeFile(adapterPath, resumeFile)
    adapterConfigExists = L.tools.adapter.hasAdapterConfig adapterPath

    args =
      model: modelDir
      data: trainingDir

    if testOnly
      args.test = null
      console.log "[run_lora_train_ite] mode: test"
    else
      args.train = null
      console.log "[run_lora_train_ite] mode: train"

    if testOnly
      if adapterConfigExists
        args["adapter-path"] = adapterPath
      else
        console.log "[run_lora_train_ite] no adapter_config.json at:", adapterPath
    else
      args["adapter-path"] = adapterPath

    args["resume-adapter-file"] = actualResumeFile if actualResumeFile? and not testOnly

    startedAt = new Date().toISOString()
    runID = "lora-#{startedAt.replace(/[:.]/g, '-')}"
    stdoutText = L.callMLX 'lora', args

    finishedAt = new Date().toISOString()
    checkpointPath = L.tools.adapter.latestCheckpoint adapterPath

    runRecord =
      run_id: runID
      started_at: startedAt
      finished_at: finishedAt
      status: 'done'
      model_dir: modelDir
      adapter_path: adapterPath
      resume_adapter_file: actualResumeFile
      training_dir: trainingDir
      stdout_text: stdoutText
      train_rows_count: trainRows.length
      valid_rows_count: validRows.length
      test_rows_count: testRows.length
      checkpoint_path: checkpointPath
      story_ids: selectedStoryIDs
      reset_this_run: cycleState.reset_this_run is true

    console.log "[run_lora_train_ite] train rows:", trainRows.length
    console.log "[run_lora_train_ite] valid rows:", validRows.length
    console.log "[run_lora_train_ite] test rows:", testRows.length
    console.log "[run_lora_train_ite] run id:", runID

    L.make 'lora_stdout', stdoutText
    L.make 'lora_run_record', runRecord
    L.done()
    return
