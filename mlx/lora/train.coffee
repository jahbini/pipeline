# mlx/lora/train.coffee
# ---------------------------------------------------------------------------
# In-process replacement for `mlx_lm.lora --train`. Trains a LoRA adapter
# on a JSONL corpus and writes adapters.safetensors + adapter_config.json
# to opts.adapterPath (mlx-lm compatible layout, consumable by fuse.coffee
# and by session_api's adapter-path load).
#
# Data format (mlx-lm text completion): each JSONL line is {"text": "..."}.
# Loss is next-token cross-entropy over the full sequence (autoregressive LM).
#
# The training loop is intentionally minimal:
#   - random batch from train.jsonl each iter
#   - pad-mask so padding positions don't contribute to the loss
#   - AdamW step via node-mlx optimizer
#   - periodic checkpoint of the adapter (per --save-every)
#   - eval on valid.jsonl every --steps-per-eval
#   - final adapter written to adapters.safetensors
#
# Test-only mode: skips training, loads the resume-file (or the adapter dir's
# adapters.safetensors), reports val/test loss.
#
# Design decision GPT/phase3_lora_and_fuse.md §train.

fs = require 'fs'
path = require 'path'
{core: mx, nn, optimizers} = require '@frost-beta/mlx'
{Tokenizer} = require '@frost-beta/llm'
{loadWeights, readJsonSync} = require '@frost-beta/llm/dist/fs.js'
{applyLoRA, saveAdapter} = require './wrap'

# See session_api.coffee for the same shim rationale.
mx.metal.clearCache      ?= mx.clearCache
mx.metal.getPeakMemory   ?= mx.getPeakMemory
mx.metal.getActiveMemory ?= mx.getActiveMemory

# --- model dispatch (mirrors session_api; kept local to avoid coupling) ----
LOCAL_MODELS =
  qwen3: -> require '../models/qwen3'

resolveModelClass = (modelType) ->
  return LOCAL_MODELS[modelType]().Model if LOCAL_MODELS[modelType]?
  try
    return require("@frost-beta/llm/dist/models/#{modelType}.js").Model
  catch err
    throw new Error "Unsupported model_type: #{modelType}"

# --- data loading ----------------------------------------------------------
loadJsonl = (file) ->
  throw new Error "training data missing: #{file}" unless fs.existsSync file
  raw = fs.readFileSync file, 'utf8'
  rows = []
  for line in raw.split(/\r?\n/) when line.trim().length
    try
      obj = JSON.parse line
    catch err
      throw new Error "bad JSONL in #{file}: #{err.message}"
    text = obj.text ? obj.completion ? null
    throw new Error "row in #{file} missing 'text' field" unless text?
    rows.push text
  throw new Error "no rows in #{file}" unless rows.length
  rows

# Tokenize once, cache — avoids re-tokenizing the same corpus every iter.
tokenizeCorpus = (rows, tokenizer, maxSeqLen) ->
  out = []
  for text in rows
    ids = tokenizer.encode text
    ids = ids[...maxSeqLen] if ids.length > maxSeqLen
    # Need at least 2 tokens to form one input/target pair.
    out.push ids if ids.length >= 2
  out

# --- batch builder ---------------------------------------------------------
# Returns { inputs: [B, T-1], targets: [B, T-1], mask: [B, T-1] } as mx arrays.
# `mask` is 1 where the position is real (target is real, not padding),
# 0 where it's padding — so the loss can be averaged over real tokens only.
buildBatch = (tokenized, batchSize, rng, padId) ->
  picks = []
  for _ in [0...batchSize]
    picks.push tokenized[Math.floor(rng() * tokenized.length)]
  maxLen = 0
  maxLen = ids.length for ids in picks when ids.length > maxLen
  # We produce sequences of length maxLen; input is [:-1], target is [1:].
  T = maxLen - 1
  inputs  = []
  targets = []
  masks   = []
  for ids in picks
    padded = ids.slice()
    real = ids.length
    while padded.length < maxLen
      padded.push padId
    inputs.push  padded[0...T]
    targets.push padded[1...maxLen]
    m = for i in [0...T]
      if (i + 1) < real then 1 else 0
    masks.push m
  {
    inputs:  mx.array inputs,  mx.int32
    targets: mx.array targets, mx.int32
    mask:    mx.array masks,   mx.float32
    tokens:  do ->
      total = 0
      for row in masks
        total += cell for cell in row
      total
  }

# --- loss ------------------------------------------------------------------
# Returns scalar mean loss over non-pad target positions.
makeLossFn = (model) ->
  (inputs, targets, mask) ->
    embeds = model.computeTextEmbeddings inputs
    logits = model.decodeEmbeddings embeds, null, null   # [B, T, V]
    logits = logits.astype mx.float32
    perTok = nn.losses.crossEntropy logits, targets, undefined, -1, 0, 'none'  # [B, T]
    weighted = mx.multiply perTok, mask
    mx.divide mx.sum(weighted), mx.maximum(mx.sum(mask), mx.array(1.0))

# --- eval loop -------------------------------------------------------------
evaluate = (model, tokenized, {batchSize, batches, rng, padId}) ->
  lossFn = makeLossFn model
  totalLoss = 0.0
  totalTokens = 0
  for i in [0...batches]
    b = buildBatch tokenized, batchSize, rng, padId
    loss = lossFn b.inputs, b.targets, b.mask
    mx.eval loss
    lVal = loss.item()
    totalLoss   += lVal * b.tokens
    totalTokens += b.tokens
    mx.dispose? [b.inputs, b.targets, b.mask, loss]
  if totalTokens > 0 then totalLoss / totalTokens else 0

# --- deterministic-ish RNG (mlx-lm uses numpy default; we use a seeded LCG) -
makeRng = (seed = 0) ->
  s = (seed | 0) or 1
  ->
    s = (s * 1103515245 + 12345) & 0x7fffffff
    s / 0x7fffffff

# --- resume: load a raw adapters.safetensors file into an already-wrapped model
loadResumeFile = (resumeFile, wrappedInfo) ->
  throw new Error "resume file missing: #{resumeFile}" unless fs.existsSync resumeFile
  weights = mx.load resumeFile
  camelToSnake = (s) -> s.replace /[A-Z]/g, (c) -> '_' + c.toLowerCase()
  loaded = 0
  for {path: fullKey, wrapper: lora} in wrappedInfo.wrapped
    snake = camelToSnake fullKey
    a = "#{snake}.lora_a"
    b = "#{snake}.lora_b"
    if weights[a]? and weights[b]?
      lora.loraA = weights[a]
      lora.loraB = weights[b]
      loaded += 1
  loaded

# --- public API ------------------------------------------------------------
# opts:
#   modelDir:        base model directory (safetensors + config)
#   dataDir:         directory containing train.jsonl, valid.jsonl, test.jsonl
#   adapterPath:     output directory for adapter checkpoints
#   train:           boolean — run training loop
#   test:            boolean — run evaluation on test.jsonl (may combine w/ train)
#   iters:           number of training iterations
#   batchSize:       examples per batch
#   maxSeqLength:    truncate examples to this many tokens
#   learningRate:    AdamW LR
#   loraLayers:      how many transformer blocks (from the top) get LoRA (default: all matching)
#   loraRank:        LoRA rank (default 8)
#   loraAlpha:       LoRA alpha (default 16)
#   loraDropout:     LoRA dropout (default 0.0)
#   stepsPerReport:  print training loss every N iters (default 10)
#   stepsPerEval:    evaluate on valid.jsonl every N iters (default 200)
#   valBatches:      how many valid batches per eval (default 25)
#   saveEvery:       checkpoint adapter every N iters (default 100)
#   resumeFile:      path to .safetensors to warm-start from (optional)
#   log:             (msg) -> ... for progress; defaults to console.log
#   seed:            RNG seed (default 0)
trainLoRA = (opts) ->
  log = opts.log ? (msg) -> console.log "[lora] #{msg}"

  modelDir     = opts.modelDir ? throw new Error 'trainLoRA: modelDir required'
  dataDir      = opts.dataDir  ? throw new Error 'trainLoRA: dataDir required'
  adapterPath  = opts.adapterPath ? throw new Error 'trainLoRA: adapterPath required'
  wantTrain    = !!opts.train
  wantTest     = !!opts.test
  iters        = opts.iters        ? 100
  batchSize    = opts.batchSize    ? 4
  maxSeqLength = opts.maxSeqLength ? 2048
  learningRate = opts.learningRate ? 1e-5
  loraRank     = opts.loraRank     ? 8
  loraAlpha    = opts.loraAlpha    ? 16
  loraDropout  = opts.loraDropout  ? 0.0
  stepsPerReport = opts.stepsPerReport ? 10
  stepsPerEval = opts.stepsPerEval ? 200
  valBatches   = opts.valBatches   ? 25
  saveEvery    = opts.saveEvery    ? 100
  seed         = opts.seed         ? 0

  # --- build model ---------------------------------------------------------
  config = readJsonSync path.join(modelDir, 'config.json')
  modelType = opts.modelType ? config.model_type
  ModelClass = resolveModelClass modelType
  model = new ModelClass config

  weights = loadWeights modelDir
  model.sanitize?(weights)
  if config.quantization
    {group_size, bits} = config.quantization
    predicate = (paramPath, mod) ->
      (mod instanceof nn.Linear or mod instanceof nn.Embedding) and "#{paramPath}.scales" of weights
    nn.quantize model, group_size, bits, predicate
  model.loadWeights Object.entries(weights)
  mx.eval model.parameters()
  log "loaded base model #{modelType} from #{modelDir}"

  # --- wrap with LoRA ------------------------------------------------------
  wrapOpts = {rank: loraRank, alpha: loraAlpha, dropout: loraDropout}
  wrapOpts.targets = opts.loraTargets if opts.loraTargets?
  wrappedInfo = applyLoRA model, wrapOpts
  log "wrapped #{wrappedInfo.count} layers (rank=#{loraRank} alpha=#{loraAlpha})"

  # --- optional resume -----------------------------------------------------
  if opts.resumeFile?
    n = loadResumeFile opts.resumeFile, wrappedInfo
    log "resumed #{n}/#{wrappedInfo.count} layers from #{opts.resumeFile}"

  # --- tokenizer + data ----------------------------------------------------
  tokenizer = new Tokenizer modelDir
  padId = tokenizer.tokenizer?.pad_token_id ? tokenizer.tokenizer?.eos_token_id ? 0

  trainTokenized = null
  validTokenized = null
  testTokenized  = null
  if wantTrain
    log "tokenizing train.jsonl…"
    trainTokenized = tokenizeCorpus loadJsonl(path.join(dataDir, 'train.jsonl')), tokenizer, maxSeqLength
    log "  #{trainTokenized.length} train sequences"
    validFile = path.join(dataDir, 'valid.jsonl')
    if fs.existsSync validFile
      log "tokenizing valid.jsonl…"
      validTokenized = tokenizeCorpus loadJsonl(validFile), tokenizer, maxSeqLength
      log "  #{validTokenized.length} valid sequences"
  if wantTest
    log "tokenizing test.jsonl…"
    testTokenized = tokenizeCorpus loadJsonl(path.join(dataDir, 'test.jsonl')), tokenizer, maxSeqLength
    log "  #{testTokenized.length} test sequences"

  rng = makeRng seed

  # --- training loop -------------------------------------------------------
  if wantTrain
    lossFn = makeLossFn model
    lossAndGrad = nn.valueAndGrad model, lossFn
    optimizer = new optimizers.AdamW learningRate

    log "training #{iters} iters, batchSize=#{batchSize}, maxSeqLen=#{maxSeqLength}, lr=#{learningRate}"
    fs.mkdirSync adapterPath, recursive: true

    accumLoss = 0.0
    accumTokens = 0
    tStart = Date.now()

    for step in [1..iters]
      b = buildBatch trainTokenized, batchSize, rng, padId
      [loss, grads] = lossAndGrad b.inputs, b.targets, b.mask
      optimizer.update model, grads
      mx.eval model.parameters(), optimizer.state, loss

      lVal = loss.item()
      accumLoss   += lVal * b.tokens
      accumTokens += b.tokens
      mx.dispose? [b.inputs, b.targets, b.mask, loss]

      if step % stepsPerReport is 0 or step is iters
        avg = if accumTokens > 0 then accumLoss / accumTokens else lVal
        elapsed = (Date.now() - tStart) / 1000
        rate = step / elapsed
        log "step #{step}/#{iters}  train_loss=#{avg.toFixed 4}  (#{rate.toFixed 2} it/s)"
        accumLoss = 0.0
        accumTokens = 0

      if step % stepsPerEval is 0 and validTokenized?
        vLoss = evaluate model, validTokenized, {batchSize, batches: valBatches, rng, padId}
        log "  valid_loss=#{vLoss.toFixed 4}"

      if step % saveEvery is 0 or step is iters
        # Checkpoint filename matches mlx-lm convention: <step>_adapters.safetensors
        ckptDir = adapterPath
        stepName = String(step).padStart 7, '0'
        # saveAdapter writes both adapters.safetensors and adapter_config.json.
        # For intermediate checkpoints we also want a step-suffixed copy so
        # resolveResumeFile in scripts/train_markdown/lora_train.coffee can
        # find the latest one on restart.
        saveAdapter ckptDir, wrappedInfo
        srcSt = path.join ckptDir, 'adapters.safetensors'
        dstSt = path.join ckptDir, "#{stepName}_adapters.safetensors"
        fs.copyFileSync srcSt, dstSt unless step is iters
        log "  checkpoint step #{step} → #{srcSt}"

  # --- final eval ----------------------------------------------------------
  results = {trained: wantTrain, tested: wantTest}
  if wantTest and testTokenized?
    tLoss = evaluate model, testTokenized, {batchSize, batches: Math.min(valBatches, Math.ceil(testTokenized.length / batchSize)), rng, padId}
    log "test_loss=#{tLoss.toFixed 4}"
    results.testLoss = tLoss

  results

module.exports = {trainLoRA, loadJsonl, makeLossFn, buildBatch}
