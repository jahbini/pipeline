# mlx/lora/lora_layer.coffee
# ---------------------------------------------------------------------------
# LoRALinear: wraps a frozen Linear or QuantizedLinear with a low-rank
# residual A @ B * scale. Matches the mlx-lm implementation.
#
# Math (row-vector convention as used by nn.Linear):
#   y = linear(x)                               # base output, shape [..., out]
#   z = ((x @ lora_a) @ lora_b) * scale         # residual,    shape [..., out]
#   return y + z.astype(y.dtype)
#
# Shapes:
#   lora_a : [in_dims,  rank]   uniform init (Kaiming-lite)
#   lora_b : [rank,     out_dims]  zeros init  ← keeps the initial adapter a no-op
#   scale  : alpha / rank
#
# Freezing: base `linear` submodule stays frozen; only lora_a and lora_b get
# gradients. Achieved by calling `.freeze()` at the module root, then
# `unfreeze(keys=['lora_a','lora_b'])` on each LoRALinear (see mlx/lora/wrap.coffee).
#
# Design decision GPT/phase3_lora_and_fuse.md §layer.

{core: mx, nn} = require '@frost-beta/mlx'

# Recover input dim from a wrapped Linear/QuantizedLinear.
# Linear: weight.shape = [out, in]                    → in = shape[1]
# QuantizedLinear (4-bit): weight.shape = [out, in/8] → in = shape[1] * (32/bits)
inputDimsOf = (linearLike) ->
  [outDim, innerDim] = linearLike.weight.shape
  if linearLike.bits?    # QuantizedLinear has bits + scales
    return innerDim * (32 / linearLike.bits)
  innerDim

outputDimsOf = (linearLike) -> linearLike.weight.shape[0]

class LoRALinear extends nn.Module
  # Static: wrap an existing Linear/QuantizedLinear into a LoRALinear.
  @wrap: (linear, opts = {}) ->
    rank    = opts.rank    ? 8
    alpha   = opts.alpha   ? 16
    dropout = opts.dropout ? 0.0
    new LoRALinear(linear, rank, alpha, dropout)

  constructor: (linear, rank = 8, alpha = 16, dropout = 0.0) ->
    super()
    @linear  = linear
    @rank    = rank
    @alpha   = alpha
    @scale   = alpha / rank
    @dropout = dropout

    inDims  = inputDimsOf linear
    outDims = outputDimsOf linear
    scaleInit = 1.0 / Math.sqrt(inDims)

    @loraA = mx.random.uniform(-scaleInit, scaleInit, [inDims, rank])
    @loraB = mx.zeros([rank, outDims])

  forward: (x) ->
    y = @linear.forward(x)
    xa = mx.matmul(x, @loraA)
    if @dropout > 0 and @training
      # nn.Dropout is a class; simpler: bernoulli mask inline.
      mask = mx.greater(mx.random.uniform(0, 1, xa.shape), mx.array(@dropout))
      xa = mx.multiply(xa, mask.astype(xa.dtype))
      xa = mx.divide(xa, mx.array(1 - @dropout))
    z = mx.multiply(mx.matmul(xa, @loraB), mx.array(@scale))
    mx.add(y, z.astype(y.dtype))

  # For fusion (Phase 3.3): merged delta weight = (lora_a @ lora_b * scale)^T
  # applied to the base linear's effective [out, in] weight. Consumer decides
  # how to add it (dequantize+add+requantize for quantized bases).
  fusedDeltaWeight: ->
    # [in, rank] @ [rank, out] = [in, out]; transpose to match Linear's [out, in]
    ab = mx.matmul(@loraA, @loraB)
    scaled = mx.multiply(ab, mx.array(@scale))
    mx.transpose(scaled, [1, 0])

module.exports = {LoRALinear, inputDimsOf, outputDimsOf}
