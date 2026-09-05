# hospital.md — bugs and fixes for pipes stuck in the Hospital ward

Pipes routed to `hospital` are held pending a bug fix rather than
rejected outright. Their disk is preserved so the fix can be tested
end-to-end without re-downloading. This file documents the known
Hospital bug classes and the fix required for each.

## Bug class: `model_loader_attr` — "Received parameters not in model"

**Symptom** — `shutdown_reason` on the last run contains:

    Received parameters not in model: <list of missing param names>

**Throw site** — `@frost-beta/mlx/lib/nn/layers/base.ts:215`, inside
`loadWeights(fileOrWeights, strict = true)`. When the safetensors file
carries any key the declared model class doesn't own, the strict check
throws before the first forward pass.

### Case A — NVFP4 double-quantized checkpoints (sakamaki, others)

Example pipe:
`hf__sakamakismile__qwen3-6-27b-text-nvfp4-mtp`

Missing params look like:

    model.language_model.layers.N.mlp.up_proj.input_scale
    model.language_model.layers.N.mlp.down_proj.weight_scale_2
    model.language_model.layers.N.linear_attn.out_proj.weight_scale_2
    model.language_model.layers.N.linear_attn.out_proj.input_scale
    model.language_model.layers.N.linear_attn.in_proj_z.input_scale
    model.language_model.layers.N.linear_attn.in_proj_qkv.weight_scale_2
    model.language_model.layers.N.linear_attn.in_proj_b.weight_scale
    model.language_model.layers.N.linear_attn.in_proj_a.input_scale

**Two independent architectural gaps** are visible in that list, and a
correct fix requires closing both:

**Gap 1 — `linear_attn` submodule.** The keys `in_proj_a`,
`in_proj_b`, `in_proj_z`, `in_proj_qkv`, `out_proj` are the shape of a
Mamba-style linear-attention block, not standard multi-head attention.
The Qwen3 class in the wrapper only declares MHA. A new
`LinearAttention` module has to be added and referenced from the
transformer block when the config says the layer type is
`linear_attn` (check the model's `config.json` for
`layer_types`/`attention_type` fields; the source model on HF is
authoritative).

**Gap 2 — NVFP4 quant format on Linear.** The wrapper's
`QuantizedLinear` tracks `weight` + `scales` + `biases`. NVFP4 is a
*double-quantized* format that also carries `weight_scale`,
`weight_scale_2`, and `input_scale`. Fixing this means:

  1. Declare those three tensors as parameters on a new
     `NVFP4QuantizedLinear` class (so strict-load accepts them).
  2. Implement the dequant path: at forward time, use
     `weight_scale_2` to reconstruct `weight_scale` from its quantized
     storage, then use `weight_scale` * `weight` to reconstruct
     dense weights, and `input_scale` to scale activations before the
     matmul (or fold it into the reconstructed scales).
  3. Route the model's linear-layer factory to instantiate this class
     when `config.json` reports `quantization_config.quant_method ==
     "nvfp4"` (or whatever the source model uses to advertise it).

### Case B — small Qwen3 with `lm_head` scales (qwen3-0-6b)

Pipe: `hf__qwen__qwen3-0-6b`.

Missing params:

    lm_head.scales
    lm_head.biases
    lm_head.weight

**Root cause** — the wrapper ties the embedding to `lm_head` and
doesn't declare `lm_head` as a separate module. When the checkpoint
ships an *un-tied* quantized `lm_head` (as this build does), those
three params have nowhere to land. Fix: teach the wrapper to detect
`tie_word_embeddings=false` in `config.json` and declare an
independent `QuantizedLinear` for `lm_head`, wired to the final
layer-norm output.

### Non-fixes (please do not commit these)

- **`loadWeights(..., strict=false)`.** Silently drops the extras.
  The model *will* load; it will also generate garbage, because the
  dropped scales are exactly what dequantization needs. This is a
  seductive one-line change and it must be resisted for both cases
  above — they are not "cosmetic extras," they are load-bearing quant
  metadata.
- **Convert to fp16 offline (`mlx-lm convert --dtype float16`).**
  Sidesteps the wrapper entirely; works for small models (this is
  what the `-mlx4 → raw` symlink pattern is doing for pipes whose
  quantize step failed). Does **not** work for sakamaki: 27B fp16 is
  ≈ 54 GB and blows through the mini's ceiling even after
  raise-ceiling. Fine as an escape hatch for smaller NVFP4 models
  that fit in RAM after conversion.

## Working the fix

Because the throw site is inside a third-party package
(`@frost-beta/mlx`), do NOT patch node_modules directly; the patch
will vanish on the next install. Two acceptable homes for the fix:

1. **Fork the wrapper** into a workspace package under
   `pipeline/mlx/` and vendor it (change the resolutions entry in
   `pnpm-lock.yaml` / package.json to point at the workspace copy).
   Preferred if the changes are non-trivial and we expect to keep
   adding architectures.
2. **Monkey-patch** at pipeline startup — subclass the offending
   module and swap the factory. Acceptable only for the `strict=false`
   loophole; won't help for Case A/B because those need real new
   modules registered in the model factory.

## Verification checklist

For any candidate fix, before flipping the pipe back to `continue`:

- Run `reset` clean (already true for Hospital pipes — that's how
  they got here).
- Run **one** `oracle_ite` iteration and confirm it produces
  non-garbage output on the seeded story (not just "load succeeded").
  Loader gaps like Case A/B will pass a smoke load and *still*
  produce token soup because the scales were dropped.
- Only after non-garbage output is confirmed, remove the
  `needs_attention` entry from `state/pipe_states.json` and flip
  state → `continue`. The puppeteer will pick up the queued
  `reembed_clean` / `train_lora` entries on the next Phase A tick.

## Ward disposition rules for this bug class

- **Hospital**, not Cemetery, for now — the fix exists, we just
  haven't written it. Disk is preserved for the eventual fix &
  retest. Do not auto-cemetery `model_loader_attr` failures.
- If a model is BOTH too big to convert fp16 AND requires
  architectural additions we don't plan to build (rare quant format,
  one-off model), that's a judgment call: leave it in Hospital and
  document here, or move to Cemetery with the reason. Sakamaki's
  27B NVFP4 currently qualifies as "documented in Hospital, awaiting
  wrapper work."
