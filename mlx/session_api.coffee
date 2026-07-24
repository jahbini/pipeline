# mlx/session_api.coffee
# ---------------------------------------------------------------------------
# Lazy, reusable LLM session over @frost-beta/mlx (node-mlx). The direct
# replacement for gypsy/session_api.coffee's createApi(). One session owns:
#   - the loaded (quantized) model
#   - the tokenizer
#   - a persistent KV cache across calls (opt-in)
#
# Contract (design decision GPT/node_mlx_migration.md §3):
#   session = createSession {modelDir, cacheLimitMB, modelType}
#   result  = await session.generate promptText, {maxTokens, systemPrompt, topP, temperature}
#     result: { text, promptTokens, generatedTokens, tokPerSec, ttftSec, peakMemGB }
#   session.dispose()
#
# All architecture-specific concerns (Qwen3 q_norm/k_norm etc.) are inside
# ./models/{model_type}.coffee — session_api stays generic.

path = require 'path'
{core: mx, nn} = require '@frost-beta/mlx'

# --- version-skew shims -----------------------------------------------------
# llm.js 0.4.1 was written against a pre-0.4 node-mlx that put memory helpers
# under mx.metal. In 0.4.0 they were promoted to top-level. Bridge before we
# require any llm.js internal that dereferences mx.metal.*.
mx.metal.clearCache      ?= mx.clearCache
mx.metal.getPeakMemory   ?= mx.getPeakMemory
mx.metal.getActiveMemory ?= mx.getActiveMemory

{Tokenizer, LLM} = require '@frost-beta/llm'
{loadWeights, readJsonSync} = require '@frost-beta/llm/dist/fs.js'
fs = require 'fs'
{applyLoRA, loadAdapter} = require './lora/wrap'

# --- model dispatch ---------------------------------------------------------
# @frost-beta/llm bundles: llama, qwen2, gemma, llava, t5. We add qwen3 here
# via ./models/qwen3. New architectures land under ./models/<model_type>.
LOCAL_MODELS =
  qwen3: -> require './models/qwen3'

resolveModelClass = (modelType) ->
  if LOCAL_MODELS[modelType]?
    return LOCAL_MODELS[modelType]().Model
  # Fall back to @frost-beta/llm's shipped models.
  try
    return require("@frost-beta/llm/dist/models/#{modelType}.js").Model
  catch err
    throw new Error "Unsupported model_type: #{modelType} (not in LOCAL_MODELS and not in @frost-beta/llm)"

# --- ChatML formatter -------------------------------------------------------
# Qwen3 ships chat_template.jinja separately from tokenizer_config.json, so
# @lenml/tokenizers cannot render it. We hard-code the ChatML wrapper for
# Qwen-family models. A future step will merge the template file or add a
# Jinja renderer (GPT/node_mlx_migration.md §5 "known-limitations").
formatChatML = (userText, systemText = null) ->
  parts = []
  parts.push "<|im_start|>system\n#{systemText}<|im_end|>" if systemText?.length
  parts.push "<|im_start|>user\n#{userText}<|im_end|>"
  parts.push "<|im_start|>assistant\n"
  parts.join '\n'

# --- output cleanup ---------------------------------------------------------
# Matches gypsy/session_api.coffee's behaviour: strip trailing special-token
# echoes and known noise lines.
CLEANUP_SPECIALS = /<\|(?:im_start|im_end|endoftext)\|>/
CLEANUP_NOISE = [
  /^=+$/
  /^Prompt:\s+\d+\s+tokens/
  /^Generation:\s+\d+\s+tokens/
  /^Peak memory:\s+/
]

cleanGeneratedText = (raw) ->
  text = String(raw ? '').trim()
  return '' unless text.length
  idx = text.search CLEANUP_SPECIALS
  text = text[...idx].trim() if idx >= 0
  lines = text.split(/\r?\n/).filter (line) ->
    trimmed = line.trim()
    return false for rx in CLEANUP_NOISE when rx.test trimmed
    true
  lines.join('\n').trim()

# --- session factory --------------------------------------------------------
createSession = (opts = {}) ->
  modelDir = opts.modelDir ? throw new Error 'createSession: modelDir required'
  modelDir = path.resolve modelDir
  cacheLimitMB = opts.cacheLimitMB ? 512

  # Load config; the model_type field drives dispatch.
  config = readJsonSync path.join(modelDir, 'config.json')
  modelType = opts.modelType ? config.model_type

  # Configure MLX memory envelope (Gypsy set 512MB; keep the same default).
  mx.setCacheLimit cacheLimitMB * 1024 * 1024

  # Build model.
  ModelClass = resolveModelClass modelType
  model = new ModelClass(config)

  # Load & quantize weights.
  weights = loadWeights modelDir
  model.sanitize?(weights)
  if config.quantization
    {group_size, bits} = config.quantization
    predicate = (paramPath, mod) ->
      (mod instanceof nn.Linear or mod instanceof nn.Embedding) and "#{paramPath}.scales" of weights
    nn.quantize model, group_size, bits, predicate
  model.loadWeights Object.entries(weights)
  mx.eval model.parameters()

  # Optional LoRA adapter: wrap targeted layers and load trained A/B tensors.
  if opts.adapterPath?
    adapterPath = path.resolve opts.adapterPath
    configFile = path.join adapterPath, 'adapter_config.json'
    throw new Error "adapter_config.json missing in #{adapterPath}" unless fs.existsSync configFile
    aConfig = JSON.parse fs.readFileSync(configFile, 'utf8')
    wrapOpts = {}
    wrapOpts.rank    = aConfig.rank    if aConfig.rank?
    wrapOpts.alpha   = aConfig.alpha   if aConfig.alpha?
    wrapOpts.dropout = aConfig.dropout if aConfig.dropout?
    wrapOpts.targets = aConfig.targets if aConfig.targets?
    wrappedInfo = applyLoRA model, wrapOpts
    loadAdapter adapterPath, wrappedInfo
    mx.eval model.parameters()

  tokenizer = new Tokenizer(modelDir)
  llm = new LLM(model, tokenizer)

  api =
    modelDir: modelDir
    modelType: modelType
    config: config

    generate: (userText, gopts = {}) ->
      maxTokens = gopts.maxTokens ? 512
      topP = gopts.topP ? 0.8
      temperature = gopts.temperature ? 1.0
      systemPrompt = gopts.systemPrompt ? null

      prompt = if gopts.raw then userText else formatChatML(userText, systemPrompt)
      promptEmbeds = await llm.encode(prompt)
      mx.eval promptEmbeds
      promptTokens = promptEmbeds.shape[1]

      tStart = Date.now()
      firstTokenAt = null
      chunks = []
      count = 0
      for await pieces from llm.generate(promptEmbeds, {maxTokens, topP, temperature})
        firstTokenAt ?= Date.now()
        chunks.push pieces[0]
        count += 1
      tEnd = Date.now()

      elapsed = (tEnd - tStart) / 1000
      ttftSec = if firstTokenAt then (firstTokenAt - tStart) / 1000 else elapsed
      decodeSec = if firstTokenAt then (tEnd - firstTokenAt) / 1000 else 0
      tokPerSec = if decodeSec > 0 then (count - 1) / decodeSec else 0

      rawText = chunks.join ''

      text:            cleanGeneratedText(rawText)
      rawText:         rawText
      promptTokens:    promptTokens
      generatedTokens: count
      elapsedSec:      elapsed
      ttftSec:         ttftSec
      tokPerSec:       tokPerSec
      peakMemGB:       (mx.getPeakMemory?() ? 0) / (1024*1024*1024)
      activeMemGB:     (mx.getActiveMemory?() ? 0) / (1024*1024*1024)

    # Embed a prompt into a fixed-dim voice fingerprint. Runs the prompt
    # through the model once, extracts last-layer V from the KV cache,
    # mean-pools across the prompt's seq axis, returns Float32Array
    # of length (kv_heads × head_dim). Same shape and semantics as
    # `mlx_lm cache_prompt` + tools/cache_embedding.coffee's
    # embeddingFromCacheFile — no disk detour.
    #
    # KV cache is disposed before and after so the fingerprint is a
    # pure prompt signal (no cross-call contamination).
    embed: (userText, gopts = {}) ->
      systemPrompt = gopts.systemPrompt ? null
      prompt = if gopts.raw then userText else formatChatML(userText, systemPrompt)

      mx.dispose?(llm.kvCache) if llm.kvCache
      llm.kvCache = null

      promptEmbeds = await llm.encode(prompt)
      mx.eval promptEmbeds
      promptTokens = promptEmbeds.shape[1]

      # Consume exactly one iteration so prefill happens and llm.kvCache
      # gets populated via the library's normal path. The sampled token
      # itself is discarded; we only care about the KV state it produced.
      for await pieces from llm.generate(promptEmbeds, {maxTokens: 1, topP: 1.0, temperature: 0.0})
        break

      cache = llm.kvCache
      throw new Error "embed: kvCache empty after prefill" unless cache?.length > 0
      layer = cache[cache.length - 1]
      valuesTensor = layer.values                            # [B, kv_heads, capacity, head_dim]
      offset = layer.offset ? valuesTensor.shape[2]

      # Slice to just the prompt positions (drop the +1 sampled token so
      # the fingerprint exactly matches the cache_prompt file version).
      keep = Math.min(promptTokens, offset)
      keep = 1 if keep < 1
      promptV = mx.slice(valuesTensor, [0], [2], [keep])     # [B, kv_heads, keep, head_dim]
      pooled = promptV.mean(2)                               # [B, kv_heads, head_dim]
      flat = pooled.astype(mx.float32).flatten()             # [B * kv_heads * head_dim]
      mx.eval flat
      typed = flat.toTypedArray()                            # Float32Array (view into mlx buffer)

      # Copy so the returned Float32Array owns its memory (safe after
      # we dispose the tensors and clear the mlx cache below).
      out = new Float32Array(typed.length)
      out.set(typed)

      mx.dispose?(llm.kvCache) if llm.kvCache
      llm.kvCache = null
      mx.clearCache?()

      embedding: out
      promptTokens: promptTokens
      dim: out.length
      peakMemGB:   (mx.getPeakMemory?() ? 0) / (1024*1024*1024)
      activeMemGB: (mx.getActiveMemory?() ? 0) / (1024*1024*1024)

    dispose: ->
      # Release the persistent KV cache the LLM instance may hold.
      mx.dispose?(llm.kvCache) if llm.kvCache
      llm.kvCache = null
      mx.clearCache?()

  api

module.exports = {createSession, formatChatML, cleanGeneratedText}
