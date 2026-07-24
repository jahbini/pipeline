###
  run_lora_train_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  The actual training call. Runs LoRA fine-tuning via the
  in-process LLM door: `L.callLLM({op:'train', ...})`
  reaches `mlx/lora/train.coffee::trainLoRA`. No Python
  subprocess, no `mlx_lm.lora`. Optionally resumes from a
  prior adapter checkpoint via `L.tools.adapter.resolveResumeFile`.
  Trainer log is captured via an `opts.log` callback and
  stored as the `lora_stdout` artifact.

  Adapter sniffing (checkpoint discovery, adapter_config
  presence) lives in `tools/adapter.coffee` and is reached
  through `L.tools.adapter.*`. See GPT/CONVENTIONS.md
  § "Tools" for the resolver, and "fs stinginess in step
  scripts" for why those probes don't belong here.
###

@step =
  desc: "Run LoRA training in-process via L.callLLM(train)"

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

    testOnly = !!L.param('test_only', false)
    adapterPath = L.param 'adapter_path'
    resumeFile = L.param 'resume_adapter_file'
    trainingDir = L.param 'training_dir'
    # Prefer quantized_model_dir (build/model4) over loraLand
    # (typically build/model, the raw 16 GB HF download). Training
    # against the quantized base uses ~10× less memory — the raw
    # weights are neither required nor useful once quantized.
    modelDir = L.param('quantized_model_dir', null) ? L.param('loraLand', null)
    llmConfig = L.param('llm', null) ? L.param('mlx', null)

    throw new Error "[#{L.stepName}] Missing model directory (quantized_model_dir or loraLand)" unless modelDir?
    throw new Error "[#{L.stepName}] Missing training_dir" unless trainingDir?
    if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))
      throw new Error "[#{L.stepName}] llm/mlx block must be an object when provided"

    actualResumeFile = if cycleState.reset_this_run is true then null else L.tools.adapter.resolveResumeFile(adapterPath, resumeFile)
    adapterConfigExists = L.tools.adapter.hasAdapterConfig adapterPath

    # Capture trainer log lines both to console (visible during run) and to
    # a buffer that becomes the lora_stdout artifact — replaces the old
    # spawn-stdout capture from L.callMLX.
    logLines = []
    captureLog = (msg) ->
      line = "[lora] #{msg}"
      console.log line
      logLines.push line

    # Map legacy kebab-case (mlx:) keys → camelCase (llm:) as defense
    # against unmigrated overrides. Recipe-level `llm:` blocks pass through
    # unchanged; `mlx:` blocks get translated.
    MLX_TO_LLM = {
      'batch-size':      'batchSize'
      'iters':           'iters'
      'max-seq-length':  'maxSeqLength'
      'learning-rate':   'learningRate'
      'lora-rank':       'loraRank'
      'lora-alpha':      'loraAlpha'
      'steps-per-report':'stepsPerReport'
      'steps-per-eval':  'stepsPerEval'
      'save-every':      'saveEvery'
    }

    llmArgs =
      op:          'train'
      modelDir:    modelDir
      dataDir:     trainingDir
      adapterPath: adapterPath
      train:       not testOnly
      test:        testOnly
      log:         captureLog

    llmArgs.resumeFile = String(actualResumeFile) if actualResumeFile? and not testOnly

    if llmConfig?
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op' or key is 'log'      # step owns these
        camel = MLX_TO_LLM[key] ? key
        llmArgs[camel] = value

    if testOnly and not adapterConfigExists
      console.log "[run_lora_train_ite] no adapter_config.json at: #{adapterPath}"

    console.log "[run_lora_train_ite] modelDir:      #{modelDir}"
    console.log "[run_lora_train_ite] trainingDir:   #{trainingDir}"
    console.log "[run_lora_train_ite] adapterPath:   #{adapterPath}"
    console.log "[run_lora_train_ite] mode:          #{if testOnly then 'test' else 'train'}"
    console.log "[run_lora_train_ite] resume:        #{actualResumeFile ? '(none)'}"

    startedAt = new Date().toISOString()
    runID = "lora-#{startedAt.replace(/[:.]/g, '-')}"

    result = await L.callLLM llmArgs

    finishedAt = new Date().toISOString()
    checkpointPath = L.tools.adapter.latestCheckpoint adapterPath
    stdoutText = logLines.join('\n') + (if logLines.length then '\n' else '')

    runRecord =
      run_id: runID
      started_at: startedAt
      finished_at: finishedAt
      status: 'done'
      mode: if testOnly then 'test' else 'train'
      trained: !!result?.trained
      tested: !!result?.tested
      test_loss: result?.testLoss ? null
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
      iters:          llmArgs.iters          ? null
      batch_size:     llmArgs.batchSize      ? null
      max_seq_length: llmArgs.maxSeqLength   ? null
      learning_rate:  llmArgs.learningRate   ? null
      lora_rank:      llmArgs.loraRank       ? null
      lora_alpha:     llmArgs.loraAlpha      ? null

    console.log "[run_lora_train_ite] train rows:", trainRows.length
    console.log "[run_lora_train_ite] valid rows:", validRows.length
    console.log "[run_lora_train_ite] test rows:", testRows.length
    console.log "[run_lora_train_ite] run id:", runID

    L.make 'lora_stdout', stdoutText
    L.make 'lora_run_record', runRecord
    L.done()
    return
