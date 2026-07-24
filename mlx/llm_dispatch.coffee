# mlx/llm_dispatch.coffee
# ---------------------------------------------------------------------------
# Dispatch behind L.callLLM(params). Replaces the yesterday-shipped
# mlx/mlx_lm_bridge.coffee. Design decision GPT/stage0_callLLM.md.
#
# Contract (Stage 0):
#   L.callLLM(params) → Promise<opResult>
#     params.op = 'train' | 'generate' | 'fuse'
#     Rest of params are op-specific, camelCase throughout.
#     Return value is the underlying function's native return
#     (no stdout-shaped string parity — that's L.callMLX's job).
#
#   Unknown op → throws. No Python fallback. Two-door rule: this door is
#   in-process only; the grandfathered Python spawn is L.callMLX.

path = require 'path'
{createSession}     = require './session_api'
{trainLoRA}         = require './lora/train'
{fuseAdapter}       = require './lora/fuse'
{quantizeModelDir}  = require './quantize'

# --- session cache (per-modelDir::adapterPath) -----------------------------
sessions = new Map()

getSession = (modelDir, opts = {}) ->
  resolved   = path.resolve modelDir
  adapterKey = if opts.adapterPath? then path.resolve(opts.adapterPath) else ''
  key = "#{resolved}::#{adapterKey}"
  cached = sessions.get key
  return cached if cached?
  session = createSession Object.assign({modelDir: resolved}, opts)
  sessions.set key, session
  session

# --- per-op handlers -------------------------------------------------------
# All handlers take the full params dict and return whatever their underlying
# function returns. No translation to Python-CLI stdout format.

generateOp = (params) ->
  throw new Error "callLLM(generate): 'modelDir' required" unless params.modelDir?
  throw new Error "callLLM(generate): 'prompt' required"   unless params.prompt?

  sessionOpts = {}
  sessionOpts.adapterPath = params.adapterPath if params.adapterPath?

  session = getSession params.modelDir, sessionOpts

  await session.generate params.prompt,
    maxTokens:    params.maxTokens    ? 512
    temperature:  params.temperature  ? 1.0
    topP:         params.topP         ? 0.8
    systemPrompt: params.systemPrompt ? null
    raw:          params.raw          ? false

trainOp = (params) ->
  # trainLoRA already takes camelCase opts (modelDir, dataDir, adapterPath,
  # iters, batchSize, maxSeqLength, learningRate, loraRank, loraAlpha, ...);
  # just pass through, minus the 'op' selector.
  {op, ...opts} = params
  trainLoRA opts

fuseOp = (params) ->
  throw new Error "callLLM(fuse): 'baseModelDir' required"   unless params.baseModelDir?
  throw new Error "callLLM(fuse): 'adapterDir' required"     unless params.adapterDir?
  throw new Error "callLLM(fuse): 'targetModelDir' required" unless params.targetModelDir?
  fuseAdapter params.baseModelDir, params.adapterDir, params.targetModelDir, (params.opts ? {})

embedOp = (params) ->
  throw new Error "callLLM(embed): 'modelDir' required" unless params.modelDir?
  throw new Error "callLLM(embed): 'prompt' required"   unless params.prompt?

  sessionOpts = {}
  sessionOpts.adapterPath = params.adapterPath if params.adapterPath?

  session = getSession params.modelDir, sessionOpts

  await session.embed params.prompt,
    systemPrompt: params.systemPrompt ? null
    raw:          params.raw          ? false

quantizeOp = (params) ->
  throw new Error "callLLM(quantize): 'sourceDir' required" unless params.sourceDir?
  throw new Error "callLLM(quantize): 'targetDir' required" unless params.targetDir?

  opts = {}
  opts.bits      = params.bits      if params.bits?
  opts.groupSize = params.groupSize if params.groupSize?
  opts.mode      = params.mode      if params.mode?
  opts.log       = params.log       if typeof params.log is 'function'

  # quantizeModelDir is synchronous (pure MLX tensor ops + fs). No await
  # needed, but wrap in Promise.resolve so the dispatcher's caller can
  # `await` uniformly with the other ops.
  Promise.resolve quantizeModelDir(params.sourceDir, params.targetDir, opts)

# --- dispatcher ------------------------------------------------------------
dispatch = (params) ->
  throw new Error "callLLM: params must be an object" unless params? and typeof params is 'object'
  switch params.op
    when 'generate' then generateOp params
    when 'train'    then trainOp params
    when 'fuse'     then fuseOp params
    when 'embed'    then embedOp params
    when 'quantize' then quantizeOp params
    else throw new Error "callLLM: unknown op '#{params.op}' (expected train|generate|fuse|embed|quantize)"

module.exports = {dispatch, getSession}
