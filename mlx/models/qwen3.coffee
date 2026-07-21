# Qwen3 model class for @frost-beta/llm.
# Extends the Llama-style architecture with Qwen3-specific tweaks:
#   - explicit head_dim (not hidden/heads)
#   - no attention biases
#   - per-head RMSNorm on Q and K after projection, before RoPE

{core: mx, nn} = require '@frost-beta/mlx'
{BaseModel, baseModelArgs, createAttentionMask} = require '@frost-beta/llm'

modelArgs = (json) ->
  args = Object.assign
    attentionBias: false
    mlpBias: false
    ropeTheta: 1000000
    ropeTraditional: false
    tieWordEmbeddings: true
    rmsNormEps: 1e-6
  , baseModelArgs(json)
  args.attentionOutProjectionBias ?= args.attentionBias
  args.hiddenAct ?= 'silu'
  args.numKeyValueHeads ?= args.numAttentionHeads
  args

class Attention extends nn.Module
  constructor: (args) ->
    super()
    dim = args.hiddenSize
    @nHeads = args.numAttentionHeads
    @nKVHeads = args.numKeyValueHeads
    @headDim = args.headDim ? Math.floor(dim / @nHeads)
    @scale = @headDim ** -0.5
    @qProj = new nn.Linear(dim, @nHeads * @headDim, args.attentionBias)
    @kProj = new nn.Linear(dim, @nKVHeads * @headDim, args.attentionBias)
    @vProj = new nn.Linear(dim, @nKVHeads * @headDim, args.attentionBias)
    @oProj = new nn.Linear(@nHeads * @headDim, dim, args.attentionOutProjectionBias)
    @qNorm = new nn.RMSNorm(@headDim, args.rmsNormEps)
    @kNorm = new nn.RMSNorm(@headDim, args.rmsNormEps)
    @rope = new nn.RoPE(@headDim, args.ropeTraditional, args.ropeTheta, 1.0)

  forward: (x, mask, cache) ->
    [B, L, D] = x.shape
    queries = @qProj.forward(x)
    keys = @kProj.forward(x)
    values = @vProj.forward(x)
    queries = queries.reshape(B, L, @nHeads, @headDim).transpose(0, 2, 1, 3)
    keys    = keys.reshape(B, L, @nKVHeads, @headDim).transpose(0, 2, 1, 3)
    values  = values.reshape(B, L, @nKVHeads, @headDim).transpose(0, 2, 1, 3)
    # Qwen3-specific: per-head RMSNorm on Q and K before RoPE.
    queries = @qNorm.forward(queries)
    keys    = @kNorm.forward(keys)
    if cache
      queries = @rope.forward(queries, cache.offset)
      keys    = @rope.forward(keys, cache.offset)
      [keys, values] = cache.updateAndFetch(keys, values)
    else
      queries = @rope.forward(queries)
      keys    = @rope.forward(keys)
    out = mx.fast.scaledDotProductAttention(queries, keys, values, @scale, mask)
    out = out.transpose(0, 2, 1, 3).reshape(B, L, -1)
    @oProj.forward(out)

class MLP extends nn.Module
  constructor: (args) ->
    super()
    dim = args.hiddenSize
    hiddenDim = args.intermediateSize
    @gateProj = new nn.Linear(dim, hiddenDim, args.mlpBias)
    @downProj = new nn.Linear(hiddenDim, dim, args.mlpBias)
    @upProj = new nn.Linear(dim, hiddenDim, args.mlpBias)
    @_act = nn.silu
  forward: (x) ->
    @downProj.forward(mx.multiply(@_act(@gateProj.forward(x)), @upProj.forward(x)))

class TransformerBlock extends nn.Module
  constructor: (args) ->
    super()
    @selfAttn = new Attention(args)
    @mlp = new MLP(args)
    @inputLayernorm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
    @postAttentionLayernorm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
  forward: (x, mask, cache) ->
    r = @selfAttn.forward(@inputLayernorm.forward(x), mask, cache)
    h = mx.add(x, r)
    r2 = @mlp.forward(@postAttentionLayernorm.forward(h))
    mx.add(h, r2)

class Qwen3Inner extends nn.Module
  constructor: (args) ->
    super()
    @embedTokens = new nn.Embedding(args.vocabSize, args.hiddenSize)
    @layers = (new TransformerBlock(args) for i in [0...args.numHiddenLayers])
    @norm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
  forward: (embeddings, cache) ->
    h = embeddings
    mask = createAttentionMask(h, cache)
    for layer, i in @layers
      h = layer.forward(h, mask, if cache then cache[i] else undefined)
    @norm.forward(h)

class Model extends BaseModel
  constructor: (json) ->
    super()
    @args = modelArgs(json)
    @model = new Qwen3Inner(@args)
    unless @args.tieWordEmbeddings
      @lmHead = new nn.Linear(@args.hiddenSize, @args.vocabSize, false)

  computeTextEmbeddings: (inputs) ->
    @model.embedTokens.forward(inputs)

  decodeEmbeddings: (embeddings, memory, cache) ->
    throw new Error('This model has no encoder.') if memory
    out = @model.forward(embeddings, cache)
    if @args.tieWordEmbeddings
      @model.embedTokens.asLinear(out)
    else
      @lmHead.forward(out)

  getDecoderKVCacheOptions: -> {nLayers: @model.layers.length}

exports.Model = Model
exports.modelArgs = modelArgs
