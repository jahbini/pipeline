# qwen3_5 — Qwen3.5 (a.k.a. Qwen3-Next) model class

_Landed 2026-08-26. Text-only inference for the Qwen3.5 dense checkpoints
(0.8B, 4B, 8B, 14B, 32B) on `@frost-beta/mlx` via `mlx/models/qwen3_5.coffee`._

## Architecture at a glance

Qwen3.5 (Alibaba's internal name: **Qwen3-Next**) is a **hybrid attention
transformer**. Layers alternate 3:1 between **linear attention (Gated
DeltaNet)** and **full attention (gated-output GQA)**. Both use the same
input/post layernorms and SwiGLU MLP; only the token-mixer differs.

- `layer_types[i]` in `text_config` — 24/32/48/64 entries, one per layer
- 3 linear then 1 full, repeated → 75% linear, 25% full
- Multimodal-capable checkpoints ship a `vision_tower`/`model.visual.*`
  encoder + `mtp.*` multi-token-prediction head; both are skip-loaded here

## Files

- `mlx/models/qwen3_5.coffee` — the class (~350 lines). Registered as
  `qwen3_5` in `mlx/session_api.coffee` `LOCAL_MODELS`.
- Reference truth: `transformers/models/qwen3_next/modeling_qwen3_next.py`.
  Reading that file end-to-end is the fastest way to understand what
  every knob in the config does.

## Config quirks (from `text_config`)

| field | meaning | example |
|---|---|---|
| `num_hidden_layers` | Total layers (mix of linear + full per `layer_types`) | 24 (0.8B), 32 (4B), 64 (27B) |
| `hidden_size` | Residual-stream width | 1024 / 2560 / 5120 |
| `intermediate_size` | MLP width | 3584 / 9216 / 17408 |
| `num_attention_heads` | Full-attn Q heads | 8 / 16 / 24 |
| `num_key_value_heads` | Full-attn KV heads (GQA) | 2 / 4 / 4 |
| `head_dim` | Per-head dim for full-attn | 256 (all sizes) |
| `linear_num_key_heads` | DeltaNet Q/K heads | 16 |
| `linear_num_value_heads` | DeltaNet V heads (**= nKey × nGroups**) | 16 / 32 / 48 |
| `linear_key_head_dim` | DeltaNet per-K-head dim | 128 |
| `linear_value_head_dim` | DeltaNet per-V-head dim | 128 |
| `linear_conv_kernel_dim` | Depthwise causal conv1d kernel | 4 |
| `attn_output_gate` | Full-attn q_proj emits 2×width (Q + gate) | true |
| `partial_rotary_factor` | Fraction of head_dim rotated by RoPE | 0.25 (= 64 of 256) |
| `rope_parameters.rope_theta` | RoPE base freq | 10,000,000 |
| `mrope_section` | MRoPE section widths [t, h, w] | [11, 11, 10] — irrelevant for text-only |
| `mtp_num_hidden_layers` | Multi-token prediction head layers | 1 (skip-loaded) |
| `tie_word_embeddings` | lm_head shares embed_tokens | true (0.8B) / false (4B, 27B) |

For text-only generation, `mrope_section` collapses to plain RoPE on the
`partial_rotary_factor · head_dim` (= 64) rotary dims. No MRoPE-specific
code is needed.

## Weight-loading contract (`sanitize` in the class)

Two prefix variants seen in the wild:
- `model.language_model.*` — 0.8B-Base HF release
- `language_model.model.*` — 27B mlx-community 4-bit release

`sanitize` **canonicalizes** to `model.language_model.*` by rewriting any
keys starting with `language_model.model.` or bare `language_model.` at
load time. The class attribute tree mirrors the canonical form:

```
Model
  .model                                → prefix `model.*`
    .languageModel                      → prefix `.language_model.*`
      .embedTokens
      .layers[i]                        → `.layers.<i>.*`
        .input_layernorm
        .post_attention_layernorm
        .mlp                            (SwiGLU, gate/up/down_proj)
        .linearAttn   (if layer_types[i] == 'linear_attention')
          .in_proj_qkv, .in_proj_z
          .in_proj_b,   .in_proj_a
          .A_log (per-head, fp32), .dt_bias
          .conv1d
          .norm         (RMSNorm on head_v_dim)
          .out_proj
        .selfAttn     (if layer_types[i] == 'full_attention')
          .q_proj     (2× width for gate split)
          .k_proj, .v_proj, .o_proj
          .q_norm, .k_norm  (per-head RMSNorm)
      .norm
      .lmHead        (only when tie_word_embeddings is false)
```

Sanitize also:
- **Drops** any weight under `mtp.*`, `model.visual.*`, `vision_tower.*`, `visual.*`
- **Renames** `.A_log` → `.a_log` (the shipped `toSnakeCase` doesn't round-trip a
  leading-capital tensor name)
- **Transposes** `.conv1d.weight` from HF layout `[C, 1, k]` to MLX layout
  `[C, k, 1]` — but ONLY when the shape looks like HF's (`shape[1] == 1`).
  Some mlx-community quantized dumps pre-transpose during conversion.
- **Folds `+1` into RMSNorm weights** for block-level norms
  (`input_layernorm`, `post_attention_layernorm`, `q_norm`, `k_norm`) because
  Qwen3-Next's `Qwen3NextRMSNorm.forward` computes `x_normed * (1 + w)`
  where `w` is initialized to zeros. **Excludes `linear_attn.norm.weight`**
  (that one is `Qwen3NextRMSNormGated`, init to ones, standard `x_normed * w`).
  **Also excludes `model.language_model.norm.weight`** — empirically its
  trained mean (~3.3 for 0.8B) is inconsistent with the `+1` fold; folding
  degrades output quality. We may be missing a checkpoint-specific quirk
  here; revisit if evidence warrants.

## Full attention (Qwen3NextAttention equivalent)

Same as Qwen3 attention plus:
- **Gated output**: `q_proj` emits `2 × nHeads × headDim`. Reshape to
  `[B, L, H, 2·hD]`, split axis=-1 → `q` and `gate` (both `[B, L, H, hD]`).
  After SDPA + reshape, multiply by `sigmoid(gate)` before `o_proj`.
  HF's per-head layout is critical; a flat halves-split mixes q rows with
  gate rows and silently breaks every attention layer.
- **Partial RoPE**: rotate only `head_dim × partial_rotary_factor = 64`
  dims. `nn.RoPE(dims=64, ...)` handles this natively.
- **Per-head q/k RMSNorm** (Qwen3-style), applied before RoPE.
- GQA via `num_key_value_heads` — SDPA in `@frost-beta/mlx` handles the
  broadcast automatically.

## Linear attention (Qwen3NextGatedDeltaNet equivalent)

Recurrence per token, in **fp32** throughout:

```
qkv     = conv1d(k=4, depthwise, causal)( in_proj_qkv(x) )   # silu after
q, k, v = split(qkv, by SIZES [qDim, kDim, vDim])            # NOT equal thirds
q, k    ← L2-normalize along head_dim
q       ← q × keyDim^-0.5
z       = in_proj_z(x)
β       = sigmoid( in_proj_b(x) )                            # [B, L, nVH]
dt      = −exp(A_log) · softplus( in_proj_a(x) + dt_bias )   # [B, L, nVH]
decay   = exp(dt)

# Grouped-query broadcast (nGroups = nVH / nKH). BLOCK pattern:
# K-head i services V-heads {i·nG, i·nG+1, ..., (i+1)·nG−1}.
if nGroups > 1:
    q_per_vh = block_broadcast(q, nGroups)   # [B, L, nVH, keyDim]
    k_per_vh = block_broadcast(k, nGroups)   # [B, L, nVH, keyDim]

# State: [B, nVH, valueDim, keyDim] (transpose of reference's layout;
# math still equivalent). Lives on `cache.deltaState` (survives mx.tidy).
for t in [0..L-1]:
    S ← decay_t · S                                          # broadcast [B, nVH, 1, 1]
    pred  = S · k_t                                          # [B, nVH, vD]
    delta = β_t · (v_t − pred)                               # [B, nVH, vD]
    S     ← S + delta ⊗ k_t                                  # rank-1 outer

    out_t = S · q_t                                          # [B, nVH, vD]

# Cast back to input dtype before norm + gate
out = out.astype(bf16)
out = norm(out) · silu(z_per_vh)                             # gate mul in fp32
return out_proj(out)
```

**Critical details** (from HF reference):
- **fp32 recurrence** — state, q, k, v, β, decay all promoted to fp32
  for the loop. bf16 accumulator drifts too fast; garbage output
  otherwise, especially past ~30 tokens on models with more layers.
- **Persistent conv1d state** across decode steps — stored as
  `cache.convState`, a rolling `[B, k-1, convChannels]` buffer of the
  last (k-1)=3 real qkv inputs. Without it, each decode step's conv sees
  `[0, 0, 0, current_token]` and the model loses 3 tokens of context per
  layer per token.
- **Split-by-sizes for qkv** — `mx.split(qkvConv, [qDim, qDim+kDim], -1)`.
  Equal thirds works only when `nKey == nValue` (0.8B); 4B+ have unequal
  head counts.
- **Delta rule** (`v − pred` before scaling by β), not plain rank-1 outer.
  Fable's key correctness lever.
- **Silu after conv** on qkv, before splitting.
- **Q scale** `keyDim^-0.5` after L2-norm.
- **Gate multiply in fp32** — reference does `hidden_states * silu(gate.to(fp32))`
  which upcasts to fp32; matching this improved speed 4× on 0.8B laptop
  (unblocked MLX kernel fusion).

## Verified working

| Model | Machine | Speed | Notes |
|---|---|---|---|
| Qwen3.5-0.8B-Base | laptop | 17 tok/s | "Paris. Paris is a city…" (base model, greedy-loops after facts) |
| Qwen3.5-4B | mac-mini | 10 tok/s | Correct facts on geography questions it happens to know; small-model hallucination on things it doesn't |
| Qwen3.5-27B-4bit | mac-mini | untested since fp32 fixes landed | Should work — same code paths, just bigger |

Speed on both machines is dispatch-overhead-bound (single-threaded JS
loop across many layers × per-token math). The fp32 gate fix
unexpectedly unblocked ~4× via kernel fusion.

## Not done — future work

**Speed:**
- **Chunked prefill** — port `torch_chunk_gated_delta_rule` to vectorize
  the per-token loop for prefill. Expected 20–50× prefill speedup on long
  prompts. Decode stays per-token. ~half-day of careful math.
- **Fused Metal kernel** for one DeltaNet step — biggest single decode
  win but real project. ~week+.
- **Op-count reduction** in the recurrence — combine expandDims/broadcast/reshape
  into fewer binding calls. Small but useful.

**Correctness (nice-to-have, don't affect text-only inference):**
- `apply_mask_to_padding_states` at DeltaNet input — matters for batched
  inference with padded prompts, not our single-prompt case.
- MoE variants (`Qwen3NextSparseMoeBlock`) — only relevant if you want
  the 80B-A3B MoE checkpoint.
- MTP head — skip-loaded; if you ever want speculative decoding it needs
  implementing.
- Vision tower — skipped by design (text-only project).

**Also worth revisiting one day:**
- Why `model.language_model.norm.weight` is empirically not zero-centered
  despite reference `Qwen3NextRMSNorm` applying `(1 + w)`. Some checkpoint
  quirk we haven't traced.

## Cross-references

- `~/pipeline/GPT/model_paths.md` — `$MODELS` cache layout (unchanged, applies)
- `~/pipeline/GPT/model_identity.md` — recipes don't set `run.model`
- `~/pipeline/GPT/mac-mini-sync.md` — laptop ↔ mac-mini scp workflow
  (current debugging bypasses git during iteration)
