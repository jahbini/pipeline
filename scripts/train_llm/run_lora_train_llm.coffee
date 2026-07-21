###
  scripts/train_llm/run_lora_train_llm.coffee  —  TRAIN_LLM step
  =============================================================
  Trains a LoRA adapter via the LLM (JS/node-mlx) door.
  Sibling of scripts/train_markdown/lora_train.coffee — which calls
  L.callMLX('lora', ...) (Python) — but does the work in-process
  via L.callLLM({op:'train', ...}) → mlx/lora/train.coffee::trainLoRA.

  Contract:
    needs: []                          (data prep is out of scope; recipe
                                        assumes {train,valid}.jsonl exist
                                        at training_dir)
    makes: lora_stdout, lora_run_record
    params:
      quantized_model_dir  → base model dir (mlx-lm format)
      training_dir         → dir containing train.jsonl / valid.jsonl
                             (falls through to global run.training_dir)
      adapter_path         → output dir for the trained adapter
      test_only            → if true, skip training and just eval on test set
      llm                  → dict of camelCase train opts (batchSize, iters,
                             maxSeqLength, learningRate, loraRank, loraAlpha,
                             stepsPerReport, stepsPerEval, saveEvery, ...)
###

@step =
  desc: "Train a LoRA adapter via L.callLLM(train) and record the run"

  action: (L) ->
    modelDir     = L.param 'quantized_model_dir', null
    trainingDir  = L.param 'training_dir', null
    adapterPath  = L.param 'adapter_path', null
    llmConfig    = L.param 'llm', null
    testOnly     = !!L.param('test_only', false)
    resumeFile   = L.param 'resume_adapter_file', null

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] Missing training_dir param (or global run.training_dir)" unless trainingDir?
    throw new Error "[#{L.stepName}] Missing adapter_path param" unless adapterPath?
    if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))
      throw new Error "[#{L.stepName}] llm must be an object when provided"

    # Capture trainer log lines both to console (visible during run) and to
    # a buffer that becomes the lora_stdout artifact.
    logLines = []
    captureLog = (msg) ->
      line = "[lora] #{msg}"
      console.log line
      logLines.push line

    # Assemble callLLM params. `op` is hardcoded by this step. `dataDir` maps
    # from the recipe's `training_dir` convention. train/test booleans are
    # derived from the step's `test_only` flag.
    llmArgs =
      op: 'train'
      modelDir:    modelDir
      dataDir:     trainingDir
      adapterPath: adapterPath
      train:       not testOnly
      test:        testOnly
      log:         captureLog

    if resumeFile? and String(resumeFile).length
      llmArgs.resumeFile = String(resumeFile)

    if llmConfig?
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op' or key is 'log'    # step owns these
        llmArgs[key] = value

    console.log "[run_lora_train_llm] modelDir:      #{modelDir}"
    console.log "[run_lora_train_llm] trainingDir:   #{trainingDir}"
    console.log "[run_lora_train_llm] adapterPath:   #{adapterPath}"
    console.log "[run_lora_train_llm] mode:          #{if testOnly then 'test' else 'train'}"

    t0 = Date.now()
    result = await L.callLLM llmArgs
    elapsedSec = (Date.now() - t0) / 1000

    stdout = logLines.join('\n') + (if logLines.length then '\n' else '')

    record =
      mode:            'train_llm'
      trained:         !!result.trained
      tested:          !!result.tested
      test_loss:       result.testLoss ? null
      adapter_path:    adapterPath
      model_dir:       modelDir
      training_dir:    trainingDir
      elapsed_sec:     elapsedSec
      iters:           llmArgs.iters ? null
      batch_size:      llmArgs.batchSize ? null
      max_seq_length:  llmArgs.maxSeqLength ? null
      learning_rate:   llmArgs.learningRate ? null
      lora_rank:       llmArgs.loraRank ? null
      lora_alpha:      llmArgs.loraAlpha ? null
      resume_file:     llmArgs.resumeFile ? null

    L.make 'lora_stdout',     stdout
    L.make 'lora_run_record', record

    L.done()
    return
