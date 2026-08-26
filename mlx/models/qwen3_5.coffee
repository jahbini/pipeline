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

# ---------- profiler --------------------------------------------------------
# Enable with `QWEN35_PROFILE=1` in the environment. Emits per-layer + per-
# stage wall-clock breakdowns for the first PROFILE_TOKENS tokens (default
# 3) then falls silent so long runs don't drown in logs. Each stage is
# forced to materialize with `mx.eval` so numbers reflect actual work, not
# deferred graph construction.
PROFILE          = process.env.QWEN35_PROFILE is '1'
PROFILE_DEEP     = process.env.QWEN35_PROFILE_DEEP is '1'   # per-stage inside layer (heavier, more memory)
PROFILE_TOKENS   = Number(process.env.QWEN35_PROFILE_TOKENS ? 3)
_profStats       = { tokensSeen: 0, layerAgg: {}, perTokenTotals: [] }

profNow = ->
  return 0 unless PROFILE
  hr = process.hrtime()
  hr[0] * 1000 + hr[1] / 1e6      # milliseconds
profShouldLog = -> PROFILE and _profStats.tokensSeen < PROFILE_TOKENS
# profStep only forces materialization in DEEP mode. Otherwise it measures
# wall-clock around the JS→binding call only (which is what actually costs
# on this per-token loop, since each binding call is synchronous even
# under lazy-graph mode). Shallow mode adds ~0 memory overhead.
profStep = (label, fn) ->
  return fn() unless profShouldLog()
  t0 = profNow()
  r  = fn()
  mx.eval(r) if PROFILE_DEEP and r?.shape?
  dt = profNow() - t0
  _profStats.layerAgg[label] ?= { calls: 0, totalMs: 0 }
  _profStats.layerAgg[label].calls++
  _profStats.layerAgg[label].totalMs += dt
  r
profTokenBegin = ->
  return unless PROFILE
  _profStats._tokenStart = profNow()
  _profStats._tokenLayerStart = _profStats.layerAgg
  _profStats.layerAgg = {}
profTokenEnd = ->
  return unless profShouldLog()
  totalMs = profNow() - _profStats._tokenStart
  _profStats.perTokenTotals.push totalMs
  console.log "\n[qwen3_5 PROFILE] token #{_profStats.tokensSeen + 1} = #{totalMs.toFixed(1)}ms"
  rows = ([label, s.calls, s.totalMs, (s.totalMs / s.calls).toFixed(2)] for own label, s of _profStats.layerAgg)
  rows.sort (a, b) -> b[2] - a[2]
  console.log "  %-32s %6s %10s %10s", 'stage', 'calls', 'total_ms', 'avg_ms'
  for [label, calls, total, avg] in rows
    console.log "  %-32s %6d %10.1f %10s", label, calls, total, avg
  _profStats.tokensSeen++
  _profStats.layerAgg = {}

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
    #     State has one matrix per VALUE head. On 27B nValueHeads > nHeads
    #     (48 vs 16); each K/Q head serves nGroups=nValueHeads/nHeads V
    #     heads (grouped-query linear attention).
    if not cache? or cache.offset == 0
      cache.deltaState = mx.zeros [B, @nValueHeads, @valueDim, @keyDim], x.dtype
    state = cache.deltaState
    nGroups = Math.floor(@nValueHeads / @nHeads)

    # (1) Depthwise causal conv over the sequence axis, then silu, then split.
    #     Conv1d input is channel-last [B, L, C]; padding=0 shrinks L
    #     by (k-1), so we left-pad to preserve length + get causality.
    #     Silu after conv is the trained-in activation (per HF reference).
    qkv     = profStep 'la.inProjQkv',  => @inProjQkv.forward(x)
    padded  = profStep 'la.pad',        => mx.pad qkv, [[0,0], [@_convKernel - 1, 0], [0,0]]
    qkvConv = profStep 'la.conv+silu',  => nn.silu(@conv1d.forward(padded))
    # Split by SIZES (not equal thirds) — on 27B, vDim = 48*128 = 6144
    # while qDim = kDim = 16*128 = 2048. Equal thirds would mangle it.
    qDim = @nHeads * @keyDim
    kDim = @nHeads * @keyDim
    parts = mx.split(qkvConv, [qDim, qDim + kDim], -1)            # [q, k, v]
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
    z    = profStep 'la.inProjZ',    => @inProjZ.forward(x)
    beta = profStep 'la.inProjB+sig',=> mx.sigmoid @inProjB.forward(x)
    aRaw = profStep 'la.inProjA',    => @inProjA.forward(x)
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

    # Broadcast a per-K-head tensor [B, nHeads, dim] to per-V-head
    # [B, nValueHeads, dim] by repeating each K head nGroups times.
    # No-op when nGroups=1 (0.8B, where nHeads == nValueHeads).
    kToV = (t, dim) ->
      return t if nGroups is 1
      # [B, nH, dim] → [B, nH, 1, dim] → broadcast → [B, nH, nGroups, dim]
      # → [B, nH*nGroups, dim]. mx.broadcastTo is a top-level function
      # (not a tensor method) in @frost-beta/mlx.
      expanded = t.reshape(B, @nHeads, 1, dim)
      broad    = mx.broadcastTo(expanded, [B, @nHeads, nGroups, dim])
      broad.reshape(B, @nValueHeads, dim)

    loopT0 = profNow()
    outs = []
    for t in [0...L]
      qT_kh   = qSl[t].reshape     B, @nHeads,      @keyDim         # per-K-head
      kT_kh   = kSl[t].reshape     B, @nHeads,      @keyDim
      qT      = kToV.call this, qT_kh, @keyDim                     # → per-V-head
      kT      = kToV.call this, kT_kh, @keyDim
      vT      = vSl[t].reshape     B, @nValueHeads, @valueDim
      betaT   = betaSl[t].reshape  B, @nValueHeads
      decayT  = decaySl[t].reshape B, @nValueHeads

      # Decay: S ← decay_t · S    (broadcast [B, nVH, 1, 1] over [..., vHD, kHD])
      dExp = decayT.reshape B, @nValueHeads, 1, 1
      state = mx.multiply state, dExp

      # Delta rule:
      #   pred  = S · k_t
      #   delta = β_t · (v_t − pred)
      #   S    += delta ⊗ k_t
      kCol  = mx.expandDims kT, -1                                   # [B, nVH, kHD, 1]
      pred  = mx.matmul(state, kCol).reshape(B, @nValueHeads, @valueDim)
      err   = mx.subtract vT, pred                                   # [B, nVH, vHD]
      delta = mx.multiply err, betaT.reshape(B, @nValueHeads, 1)
      dExpV = mx.expandDims delta, -1                                # [B, nVH, vHD, 1]
      kExpK = mx.expandDims kT,    -2                                # [B, nVH, 1,   kHD]
      state = mx.add state, mx.multiply(dExpV, kExpK)

      # Readout: out_t = S · q_t
      qCol = mx.expandDims qT, -1                                    # [B, nVH, kHD, 1]
      outT = mx.matmul(state, qCol).reshape(B, @nValueHeads, @valueDim)
      outs.push outT

    # Persist final S back onto the cache slot.
    cache.deltaState = state

    if profShouldLog()
      mx.eval(outs[outs.length - 1]) if PROFILE_DEEP and outs.length     # force loop materialize (deep only)
      dtLoop = profNow() - loopT0
      _profStats.layerAgg['la.perTokenLoop'] ?= { calls: 0, totalMs: 0 }
      _profStats.layerAgg['la.perTokenLoop'].calls++
      _profStats.layerAgg['la.perTokenLoop'].totalMs += dtLoop

    out = profStep 'la.stack',       => mx.stack outs, 1              # [B, L, nVH, vHD]

    # (5) Per-head RMSNorm (weight shape [vHD]) then multiply by silu(z).
    #     z has shape [B, L, nValueHeads * valueDim] — reshape to per-head.
    out = @norm.forward out                                          # normalizes along vHD
    zR = z.reshape B, L, @nValueHeads, @valueDim
    out = mx.multiply out, nn.silu(zR)

    # (6) Flatten heads + output projection.
    out = out.reshape B, L, @nValueHeads * @valueDim
    result = profStep 'la.outProj',  => @outProj.forward out

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
    # 27B ships tie_word_embeddings=false and stores lm_head UNDER the
    # language_model subtree (path `model.language_model.lm_head`).
    # 0.8B ships tie_word_embeddings=true and has no lm_head at all.
    unless args.tieWordEmbeddings
      @lmHead = new nn.Linear(args.hiddenSize, args.vocabSize, false)
  forward: (embeddings, cache) ->
    profTokenBegin()
    h = embeddings
    mask = createAttentionMask(h, cache)
    tFullSum = 0
    tLinSum  = 0
    tMlpSum  = 0
    for layer, i in @layers
      cSlot = if cache then cache[i] else undefined
      if profShouldLog()
        t0 = profNow()
        h  = layer.forward(h, mask, cSlot)
        mx.eval h if PROFILE_DEEP     # force per-layer materialization only in deep mode
        dt = profNow() - t0
        if layer.selfAttn?
          tFullSum += dt
        else
          tLinSum += dt
      else
        h = layer.forward(h, mask, cSlot)
    if profShouldLog()
      nFull = 0; nLin = 0
      nFull++ for layer in @layers when layer.selfAttn?
      nLin = @layers.length - nFull
      _profStats.layerAgg['block.fullAttnLayers']   = { calls: nFull, totalMs: tFullSum }
      _profStats.layerAgg['block.linearAttnLayers'] = { calls: nLin,  totalMs: tLinSum }
    h = @norm.forward(h)
    profTokenEnd()
    h

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
    # lm_head lives on LanguageModelInner for qwen3_5 (see comment there).
    # No top-level @lmHead here — the safetensors doesn't have one at that
    # path, and creating it would fail loadWeights strict mode.

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
    # Prefix canonicalization: some Qwen3.5 exports nest as
    #   `model.language_model.<...>`  (0.8B-Base HF release), others as
    #   `language_model.model.<...>`  (27B mlx-community quantized).
    # Rewrite the latter to the former so the rest of sanitize + the
    # class attribute tree only needs to speak one dialect.
    if weights['language_model.model.embed_tokens.weight']?
      prefixRewrites = 0
      for own key of weights
        if key.startsWith('language_model.model.')
          newKey = 'model.language_model.' + key.slice('language_model.model.'.length)
          weights[newKey] = weights[key]
          delete weights[key]
          prefixRewrites++
        else if key.startsWith('language_model.') and not key.startsWith('language_model.model.')
          # e.g. `language_model.norm.weight` -> `model.language_model.norm.weight`
          newKey = 'model.language_model.' + key.slice('language_model.'.length)
          weights[newKey] = weights[key]
          delete weights[key]
          prefixRewrites++
      console.log "[qwen3_5.sanitize] rewrote #{prefixRewrites} keys: language_model.model.* → model.language_model.*"

    # Vision / MTP prefixes vary across qwen3_5 checkpoints:
    #   0.8B-Base uses `model.visual.*`, 27B-4bit uses `vision_tower.*`.
    # Also seen: `visual.*` (no prefix) on some HF exports. Drop all
    # three variants + any mtp head weights.
    dropPrefixes = ['mtp.', 'model.visual.', 'vision_tower.', 'visual.']
    for own key of weights
      shouldDrop = false
      for pfx in dropPrefixes when key.startsWith(pfx)
        shouldDrop = true
        break
      if shouldDrop
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
      # Only transpose when we see HF layout — some mlx-community
      # quantized dumps (e.g. Qwen3.8-27B-4bit) pre-transpose to MLX
      # layout at their convert step, and a blanket transpose here
      # would UN-do that. Heuristic: depthwise groups=channels means
      # inCh/groups == 1, so shape[1]==1 → HF, shape[1]>1 → already MLX.
      if key.endsWith('.conv1d.weight')
        w = weights[key]
        if w?.shape?.length is 3 and w.shape[1] is 1
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
      @model.languageModel.lmHead.forward(out)

  getDecoderKVCacheOptions: -> {nLayers: @model.languageModel.layers.length}

exports.Model = Model
exports.modelArgs = modelArgs
