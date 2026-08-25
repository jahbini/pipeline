# Qwen3.5 model class for @frost-beta/llm.
# ---------------------------------------------------------------------------
# Hybrid attention architecture — 24 layers arranged as three
# `linear_attention` (Gated DeltaNet) layers followed by one
# `full_attention` layer, repeated ×6. Multimodal capable (skips visual /
# mtp weights at load); text-only inference for now.
#
# Loader-only in this pass — forward paths throw. See qwen3.coffee for the
# sibling straight-Qwen3 class.
#
# Config quirks (from ~/models/Qwen/Qwen3.5-0.8B-Base/config.json):
#   - Nested under `text_config` — modelArgs unwraps it.
#   - `layer_types[i]` selects per-layer attention flavor.
#   - full attention: `attn_output_gate: true` (q_proj emits 2× width;
#     second half is a sigmoid gate on the attention output),
#     partial_rotary_factor = 0.25 (RoPE on 64 of 256 dims),
#     mrope_section = [11,11,10] collapses to plain RoPE for text-only.
#   - linear attention (Gated DeltaNet):
#       in_proj_qkv        Linear
#       in_proj_z          Linear (output gate)
#       in_proj_b          Linear (β, delta-rule scale, per head)
#       in_proj_a          Linear (a, decay logit, per head)
#       A_log, dt_bias     per-head scalars
#       conv1d             depthwise causal Conv1d, kernel_size=4
#       norm               RMSNorm on output
#       out_proj           Linear
#   - No lm_head — tie_word_embeddings: true.
#   - Weight prefix `model.language_model.*` (not `model.*`).
#
# Skip-loaded (via `sanitize`):
#   - mtp.*            (multi-token prediction head)
#   - model.visual.*   (vision encoder)
#
# One case-conversion trap: `A_log` doesn't round-trip through the shipped
# toSnakeCase/toCamelCase pair. `sanitize` renames it to `a_log` at load so
# the class attribute can be `aLog` in the usual way.
#
# SHAPES MARKED "?" ARE BEST GUESSES — verify against loadWeights strict
# mode's error messages on first load, then adjust.

{core: mx, nn} = require '@frost-beta/mlx'
{BaseModel, baseModelArgs, createAttentionMask} = require '@frost-beta/llm'

# ---------- args ------------------------------------------------------------
# Config JSON has model_type at root and a nested text_config with the real
# transformer knobs. Unwrap here so downstream code sees a single flat args.
modelArgs = (json) ->
  textJson = json.text_config ? json
  args = Object.assign
    attentionBias: false
    mlpBias: false
    tieWordEmbeddings: true
    rmsNormEps: 1e-6
    attnOutputGate: false
    partialRotaryFactor: 1.0
    ropeTheta: 10000000
    ropeTraditional: false
    fullAttentionInterval: 4
    linearConvKernelDim: 4
    mtpNumHiddenLayers: 0
  , baseModelArgs(textJson)
  args.numKeyValueHeads      ?= args.numAttentionHeads
  args.hiddenAct             ?= 'silu'
  args.linearNumKeyHeads     ?= args.numAttentionHeads
  args.linearNumValueHeads   ?= args.linearNumKeyHeads
  args.linearKeyHeadDim      ?= args.headDim
  args.linearValueHeadDim    ?= args.linearKeyHeadDim
  # rope_parameters is a nested block on qwen3_5; hoist theta + partial for
  # convenience but leave the whole block accessible via args.ropeParameters.
  if args.ropeParameters?
    args.ropeTheta            ?= args.ropeParameters.ropeTheta
    args.partialRotaryFactor  ?= args.ropeParameters.partialRotaryFactor
  args.rotaryDims             ?= Math.floor(args.headDim * args.partialRotaryFactor)
  args.layerTypes             ?= ('full_attention' for _ in [0...args.numHiddenLayers])
  args

# ---------- full attention (gated) ------------------------------------------
# Same shape as qwen3.Attention plus:
#   - q_proj emits 2× n_heads * head_dim (gate split)
#   - After attention output, elementwise sigmoid(gate) * attn_out
#   - RoPE on only `rotaryDims` head dims (partial rotary), rest untouched
class FullAttention extends nn.Module
  constructor: (args) ->
    super()
    dim = args.hiddenSize
    @nHeads = args.numAttentionHeads
    @nKVHeads = args.numKeyValueHeads
    @headDim = args.headDim
    @scale = @headDim ** -0.5
    qOutDim = @nHeads * @headDim
    qOutDim = qOutDim * 2 if args.attnOutputGate
    @qProj = new nn.Linear(dim, qOutDim, args.attentionBias)
    @kProj = new nn.Linear(dim, @nKVHeads * @headDim, args.attentionBias)
    @vProj = new nn.Linear(dim, @nKVHeads * @headDim, args.attentionBias)
    @oProj = new nn.Linear(@nHeads * @headDim, dim, args.attentionBias)
    @qNorm = new nn.RMSNorm(@headDim, args.rmsNormEps)
    @kNorm = new nn.RMSNorm(@headDim, args.rmsNormEps)
    @rope = new nn.RoPE(args.rotaryDims, args.ropeTraditional, args.ropeTheta, 1.0)
    @gated = args.attnOutputGate is true
  forward: (x, mask, cache) ->
    [B, L, D] = x.shape
    qOut = @qProj.forward(x)                                   # [B, L, nHeads*headDim] or ×2 if gated
    if @gated
      # HF interleaves q and gate PER HEAD: q_proj emits 2*headDim per
      # head, arranged as [head_0 q, head_0 gate, head_1 q, head_1 gate, ...]
      # per the last axis. Reshape then split-axis=-1 is the correct layout;
      # a flat half-split mixes q rows with gate rows.
      qGate = qOut.reshape(B, L, @nHeads, 2 * @headDim)        # [B, L, H, 2*hD]
      [qHeads, gate] = mx.split(qGate, 2, -1)                  # each [B, L, H, hD]
      queries = qHeads.transpose(0, 2, 1, 3)                   # [B, H, L, hD]
    else
      queries = qOut.reshape(B, L, @nHeads, @headDim).transpose(0, 2, 1, 3)
      gate = null
    k = @kProj.forward(x)
    v = @vProj.forward(x)
    keys    = k.reshape(B, L, @nKVHeads, @headDim).transpose(0, 2, 1, 3)
    values  = v.reshape(B, L, @nKVHeads, @headDim).transpose(0, 2, 1, 3)
    queries = @qNorm.forward(queries)
    keys    = @kNorm.forward(keys)
    if cache
      queries = @rope.forward(queries, cache.offset)
      keys    = @rope.forward(keys,    cache.offset)
      [keys, values] = cache.updateAndFetch(keys, values)
    else
      queries = @rope.forward(queries)
      keys    = @rope.forward(keys)
    out = mx.fast.scaledDotProductAttention(queries, keys, values, @scale, mask)
    out = out.transpose(0, 2, 1, 3)                            # [B, L, H, hD]
    if @gated
      out = mx.multiply(out, mx.sigmoid(gate))                 # gate is [B, L, H, hD]
    out = out.reshape(B, L, @nHeads * @headDim)
    @oProj.forward(out)

# ---------- linear attention (Gated DeltaNet) -------------------------------
# Fused Q/K/V projection width is a BEST GUESS:
#     inProjQkv:  hidden → nKey*keyDim + nKey*keyDim + nValue*valueDim   (Q,K,V)
#   z / b / a widths similarly guessed; verify against safetensors shape
#   when the weight file finishes downloading.
class LinearAttention extends nn.Module
  constructor: (args) ->
    super()
    dim = args.hiddenSize
    @nHeads = args.linearNumKeyHeads
    @nValueHeads = args.linearNumValueHeads
    @keyDim = args.linearKeyHeadDim
    @valueDim = args.linearValueHeadDim
    qDim = @nHeads * @keyDim
    kDim = @nHeads * @keyDim
    vDim = @nValueHeads * @valueDim
    convChannels = qDim + kDim + vDim   # ?
    @inProjQkv = new nn.Linear(dim, convChannels, false)
    @inProjZ   = new nn.Linear(dim, vDim, false)              # gate on the output stream (?)
    @inProjB   = new nn.Linear(dim, @nValueHeads, false)      # β per head (?)
    @inProjA   = new nn.Linear(dim, @nValueHeads, false)      # decay logit per head (?)
    # Per-head learnable scalars. Named with the underscore-uppercase form
    # the safetensors file uses; sanitize() renames `A_log` → `a_log` at
    # load time so the class attribute here is plain camelCase.
    @aLog   = mx.zeros [@nValueHeads]
    @dtBias = mx.zeros [@nValueHeads]
    @conv1d = new nn.Conv1d(convChannels, convChannels, args.linearConvKernelDim, 1, 0, 1, convChannels, false)
    # Per-head RMSNorm on the DeltaNet output — normalize each head's
    # valueDim vector independently, not the full concat.
    @norm    = new nn.RMSNorm(@valueDim, args.rmsNormEps)
    @outProj = new nn.Linear(vDim, dim, false)
    @_hiddenSize = dim
    @_convKernel = args.linearConvKernelDim
    # Fake KV shape used only to prime the sibling KVCache slot so
    # @frost-beta/llm's `step` can call `.state` on every layer. The
    # DeltaNet's real state lives in @_state (below).
    @_fakeNKVHeads = args.numKeyValueHeads
    @_fakeHeadDim  = args.headDim
    # Recurrent state S ([B, nHeads, valueDim, keyDim]) is stored on
    # the cache slot as `cache.deltaState`. Storing it on the module
    # would work in isolation but not under mx.tidy — the tidy pass
    # disposes any array not reachable from the callback's return,
    # and only `cache` is guaranteed to be returned (see @frost-beta/
    # llm base.js step()). So keeping state ON the cache keeps it
    # alive across tidy boundaries.

  # Gated DeltaNet forward — decode + naive per-token prefill.
  # Not yet chunked / not GPU-scan-fused. Correctness first.
  #
  # Per token (following Fable's spec + Qwen3.5 config):
  #   qkv     = conv1d(causal, k=4)( in_proj_qkv(x) )
  #   split → q, k, v (each [B, L, nH, hD])
  #   q, k   ← L2-normalize along hD
  #   z       = in_proj_z(x)                        [B, L, nH*vHD]
  #   β       = sigmoid( in_proj_b(x) )             [B, L, nH]
  #   dt      = −exp(A_log) · softplus( in_proj_a(x) + dt_bias )
  #   decay   = exp(dt)                              (0,1]
  #   S       ← decay · S + β · (v ⊗ k)             rank-1 outer per head
  #   out_t   = S · q_t
  #   out     = RMSNorm(out) · silu(z)
  #   result  = out_proj(out)
  forward: (x, mask, cache) ->
    [B, L, D] = x.shape

    # (0) State lives on the cache slot to survive mx.tidy passes.
    #     Fresh session (cache.offset == 0) → allocate zeros.
    if not cache? or cache.offset == 0
      cache.deltaState = mx.zeros [B, @nHeads, @valueDim, @keyDim], x.dtype
    state = cache.deltaState

    # (1) Depthwise causal conv over the sequence axis, then silu, then split.
    #     Conv1d input is channel-last [B, L, C]; padding=0 shrinks L
    #     by (k-1), so we left-pad to preserve length + get causality.
    #     Silu after conv is the trained-in activation (per HF reference).
    qkv = @inProjQkv.forward(x)                                   # [B, L, 3*nH*kHD]
    padded = mx.pad qkv, [[0,0], [@_convKernel - 1, 0], [0,0]]    # [B, L+k-1, C]
    qkvConv = nn.silu(@conv1d.forward(padded))                    # [B, L, C]
    parts = mx.split(qkvConv, 3, -1)                              # 3× [B, L, nH*hD]
    q = parts[0].reshape B, L, @nHeads,      @keyDim
    k = parts[1].reshape B, L, @nHeads,      @keyDim
    v = parts[2].reshape B, L, @nValueHeads, @valueDim

    # (2) L2-normalize q, k along the head dim. Then scale q by 1/√keyDim
    #     (the recurrent kernel's attention scaling; RMSNorm on output
    #     mostly cancels this but keep for fidelity to the reference).
    l2norm = (t) ->
      denom = mx.rsqrt mx.add(mx.sum(mx.square(t), -1, true), 1e-6)
      mx.multiply t, denom
    q = l2norm q
    k = l2norm k
    qScale = @keyDim ** -0.5
    q = mx.multiply q, qScale

    # (3) Auxiliary projections + gate math.
    #     A_log ships as float32 per `mamba_ssm_dtype`; everything else
    #     from the model is bf16. Mixed-dtype ops fail with
    #     "Unsupported array type", so cast fp32 params to x.dtype at
    #     the point of use. (A promote-everything-to-fp32 path would
    #     be more faithful to the reference impl; revisit if numerical
    #     quality suffers.)
    z    = @inProjZ.forward(x)                                    # [B, L, nH*vHD]
    beta = mx.sigmoid @inProjB.forward(x)                         # [B, L, nH]
    aRaw = @inProjA.forward(x)                                    # [B, L, nH]
    # softplus(y) = log1p(exp(y)) — sufficient at these magnitudes.
    sp     = mx.log1p mx.exp(mx.add(aRaw, @dtBias))
    aLogX  = @aLog.astype(x.dtype)
    # dt = -exp(A_log) · softplus, decay = exp(dt) ∈ (0, 1]
    dt     = mx.multiply mx.negative(mx.exp(aLogX)), sp
    decay  = mx.exp dt                                             # [B, L, nH]

    # (4) Pre-slice the per-token tensors to avoid re-indexing in the loop.
    qSl     = mx.split q,     L, 1
    kSl     = mx.split k,     L, 1
    vSl     = mx.split v,     L, 1
    betaSl  = mx.split beta,  L, 1
    decaySl = mx.split decay, L, 1

    outs = []
    for t in [0...L]
      qT      = qSl[t].reshape     B, @nHeads,      @keyDim
      kT      = kSl[t].reshape     B, @nHeads,      @keyDim
      vT      = vSl[t].reshape     B, @nValueHeads, @valueDim
      betaT   = betaSl[t].reshape  B, @nValueHeads
      decayT  = decaySl[t].reshape B, @nValueHeads

      # Decay: S ← decay_t · S    (broadcast [B, nH, 1, 1] over [..., vHD, kHD])
      dExp = decayT.reshape B, @nHeads, 1, 1
      state = mx.multiply state, dExp

      # Delta rule (not plain rank-1 outer):
      #   pred  = S · k_t                       ← what S currently returns for k
      #   delta = β_t · (v_t − pred)            ← prediction error, not v alone
      #   S    += delta ⊗ k_t
      kCol  = mx.expandDims kT, -1                                   # [B, nH, kHD, 1]
      pred  = mx.matmul(state, kCol).reshape(B, @nValueHeads, @valueDim)  # [B, nH, vHD]
      err   = mx.subtract vT, pred                                   # [B, nH, vHD]
      delta = mx.multiply err, betaT.reshape(B, @nValueHeads, 1)     # [B, nH, vHD]
      dExpV = mx.expandDims delta, -1                                # [B, nH, vHD, 1]
      kExpK = mx.expandDims kT,    -2                                # [B, nH, 1,   kHD]
      state = mx.add state, mx.multiply(dExpV, kExpK)

      # Readout: out_t = S · q_t
      qCol = mx.expandDims qT, -1                                    # [B, nH, kHD, 1]
      outT = mx.matmul(state, qCol).reshape(B, @nHeads, @valueDim)   # [B, nH, vHD]
      outs.push outT

    # Persist final S back onto the cache slot.
    cache.deltaState = state

    out = mx.stack outs, 1                                           # [B, L, nH, vHD]

    # (5) Per-head RMSNorm (weight shape [vHD]) then multiply by silu(z).
    out = @norm.forward out                                          # normalizes along vHD
    zR = z.reshape B, L, @nHeads, @valueDim
    out = mx.multiply out, nn.silu(zR)

    # (6) Flatten heads + output projection.
    out = out.reshape B, L, @nHeads * @valueDim
    result = @outProj.forward out

    # (7) Prime the sibling KVCache with a 1-token zero pair so the
    #     framework's `state` getter has something to eval. The tensor
    #     is discarded; only the assignment inside cache matters.
    if cache?
      fake = mx.zeros [B, @_fakeNKVHeads, 1, @_fakeHeadDim], x.dtype
      cache.updateAndFetch(fake, fake)

    result

# ---------- MLP -------------------------------------------------------------
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

# ---------- one transformer block, per-layer type dispatch ------------------
class TransformerBlock extends nn.Module
  constructor: (args, layerType) ->
    super()
    if layerType is 'full_attention'
      @selfAttn = new FullAttention(args)
    else
      @linearAttn = new LinearAttention(args)
    @mlp = new MLP(args)
    @inputLayernorm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
    @postAttentionLayernorm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
  forward: (x, mask, cache) ->
    attn = @selfAttn ? @linearAttn
    r = attn.forward(@inputLayernorm.forward(x), mask, cache)
    h = mx.add(x, r)
    r2 = @mlp.forward(@postAttentionLayernorm.forward(h))
    mx.add(h, r2)

# ---------- inner language model --------------------------------------------
class LanguageModelInner extends nn.Module
  constructor: (args) ->
    super()
    @embedTokens = new nn.Embedding(args.vocabSize, args.hiddenSize)
    @layers = (new TransformerBlock(args, args.layerTypes[i]) for i in [0...args.numHiddenLayers])
    @norm = new nn.RMSNorm(args.hiddenSize, args.rmsNormEps)
  forward: (embeddings, cache) ->
    h = embeddings
    mask = createAttentionMask(h, cache)
    for layer, i in @layers
      h = layer.forward(h, mask, if cache then cache[i] else undefined)
    @norm.forward(h)

# Extra nesting to match `model.language_model.*` safetensors prefix.
class ModelWrapper extends nn.Module
  constructor: (args) ->
    super()
    @languageModel = new LanguageModelInner(args)

# ---------- top-level Model -------------------------------------------------
class Model extends BaseModel
  constructor: (json) ->
    super()
    @args = modelArgs(json)
    @model = new ModelWrapper(@args)
    unless @args.tieWordEmbeddings
      @lmHead = new nn.Linear(@args.hiddenSize, @args.vocabSize, false)

  # Called by session_api BEFORE loadWeights. Two jobs:
  #   1. Drop weight keys we deliberately don't model:
  #        mtp.*             (multi-token prediction head)
  #        model.visual.*    (vision encoder)
  #   2. Rename `A_log` → `a_log` — the shipped toSnakeCase/toCamelCase pair
  #      doesn't round-trip a leading-capital tensor name (see mlx/dist/
  #      utils.js), so aliasing it here lets the class attribute be plain
  #      camelCase (`aLog`).
  sanitize: (weights) ->
    dropped = 0
    renamed = 0
    convTransposed = 0
    normFolded = 0
    for own key of weights
      if key.startsWith('mtp.') or key.startsWith('model.visual.')
        delete weights[key]
        dropped++
        continue
      if key.endsWith('.A_log')
        newKey = key.slice(0, -('.A_log'.length)) + '.a_log'
        weights[newKey] = weights[key]
        delete weights[key]
        renamed++
        continue
      # Depthwise Conv1d weight layout differs: PyTorch/HF ships
      # [outCh, inCh/groups, kernel]; MLX wants [outCh, kernel, inCh/groups].
      # Transpose the last two axes for every conv1d.weight tensor.
      if key.endsWith('.conv1d.weight')
        w = weights[key]
        if w?.shape?.length is 3
          weights[key] = w.transpose(0, 2, 1)
          convTransposed++
        continue
      # Qwen3-Next / Qwen3.5 stores block-level RMSNorm weights
      # zero-centered — modeling code applies `x_normed * (1 + w)`.
      # Fold the +1 at load so downstream nn.RMSNorm (`x_normed * w`)
      # matches. Excludes `linear_attn.norm.weight` (initialized to
      # ones, standard RMSNorm layout).
      # Excludes `linear_attn.norm.weight` (init to 1 per traditional
      # RMSNorm convention; observed mean ≈ 0.95). Also excludes
      # `model.language_model.norm.weight` — observed mean = 3.3, i.e.
      # already trained WITHOUT the +1 fold convention.
      if key.endsWith('.weight') and key.indexOf('layernorm') >= 0 or
         key.endsWith('.q_norm.weight') or
         key.endsWith('.k_norm.weight')
        weights[key] = mx.add(weights[key], 1.0)
        normFolded++
    console.log "[qwen3_5.sanitize] dropped #{dropped} unused (mtp/visual), renamed #{renamed} (A_log→a_log), transposed #{convTransposed} conv1d, folded +1 into #{normFolded} zero-centered norms"
    return

  computeTextEmbeddings: (inputs) ->
    @model.languageModel.embedTokens.forward(inputs)

  decodeEmbeddings: (embeddings, memory, cache) ->
    throw new Error('This model has no encoder.') if memory
    out = @model.languageModel.forward(embeddings, cache)
    if @args.tieWordEmbeddings
      @model.languageModel.embedTokens.asLinear(out)
    else
      @lmHead.forward(out)

  getDecoderKVCacheOptions: -> {nLayers: @model.languageModel.layers.length}

exports.Model = Model
exports.modelArgs = modelArgs
