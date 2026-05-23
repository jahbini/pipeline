# Gypsy Strategy & Standards

Captured from the May 2026 work that took Qwen3-4B native generation from
1.37 tok/s / 6 GB to ~10 tok/s / ~2 GB.

This document complements `gypsy/STATUS.md` (the current state) and
`gypsy/README.md` (the original strategic intent).

---

## Strategy

### Where speed actually came from

Four wins, in descending impact:

1. **Preallocated expanded KV cache (`mlx_prealloc_kv`).** Each layer keeps a
   resident `[1, q_heads, capacity, head_dim]` array and writes new K/V via
   `slice_update`. Avoids the per-token `concatenate` chain.
2. **Custom Metal embedding-row kernel.** Replaces `dequantize(W) + take(idx, 0)`
   which materialized the full vocab×hidden float32 matrix as an intermediate.
3. **bfloat16 hidden states + KV cache.** Halves activation/KV bandwidth.
   Qwen's trained precision, so the resulting token sequence is the natural
   bf16 variant (not numerically identical to fp32, but coherent).
4. **`mlx::core::set_cache_limit(512 MB)`.** Caps MLX's free-buffer pool so
   large transients (1+ GB) are returned to the OS instead of pooled.

### What did not pay

- **Native GQA (kv_heads in KV cache, MLX SDPA's GQA path).** Catastrophically
  slow in single-token decode for reasons not fully diagnosed (likely SDPA
  vector kernel's gqa_factor>1 dispatch). Reverted to explicit 32-way
  expansion via `mlx::core::repeat`.
- **Hand-rolled fused `quantized_matmul + rms_norm + RoPE` Metal kernel.**
  Correctness was perfect (token-for-token match with MLX). Speed was a wash
  or slightly worse. The fusion saved kernel-dispatch overhead but the
  hand-written matmul (1 thread per output element, 128 threads per head)
  couldn't beat MLX's tiled SIMD-group quantized matmul.

---

## Standards

### S1 — Do not hand-roll matmul to replace MLX

MLX's `quantized_matmul` is a tuned tiled SIMD-group kernel. A naive
"one thread per output" Metal kernel cannot match it, even after fusing
neighboring ops (norm, rope, activation) into the same kernel.

If a fused kernel must exist for some other reason (e.g. memory-layout
control), it must use SIMD-group cooperative matmul techniques. Otherwise
defer the matmul to `mlx::core::quantized_matmul` and only fuse the cheap
elementwise tail.

The rust project landed in the same place: "rust generation is correct but
0.25× the speed of MLX." Treat this as a settled result.

### S2 — Avoid materializing the full vocab matrix

Anything of the form `dequantize(embedding_weights) → take/gather/slice`
will materialize the full `[vocab, hidden]` float32 matrix as an
intermediate. For Qwen3-4B that is 1.56 GB per token.

Use a custom Metal kernel that dequantizes only the selected rows, or use
`quantized_matmul` with a one-hot input (608 KB, much smaller than 1.56 GB).
The logits path already does the right thing via `quantized_matmul`
(weight-side fused dequant). The embedding-lookup path needed the custom
row-extraction kernel.

### S3 — Cap MLX's free pool

`mlx::core::set_cache_limit(N)` returns large transient buffers to the OS
rather than holding them in MLX's free list. Use a modest cap (~512 MB) so
the pool doesn't hide leaks of multi-GB intermediates. The cap does not
prevent large allocations — it only controls how much is held in the pool
after free.

### S4 — Use Metal datatypes at boundaries (carry-over from `gypsy/README.md`)

- packed INT4 weights enter Metal as `device uint*` (uint32, 8 nibbles per
  word)
- BF16 scales/biases/norm weights enter Metal as `device half*` and are
  promoted to `float` for accumulation
- hidden states enter Metal as `float` unless the kernel explicitly
  declares otherwise
- token indices and dimensions are `int32` / `uint32`

When a Metal step gives plausible-looking wrong numbers, debug the boundary
datatypes first.

### S5 — bfloat16 is the right compute dtype for inference

Qwen was trained in bfloat16. There is no precision benefit to running
inference in float32. Use `compute_dtype = mlx::core::bfloat16` for
activations and KV cache. Cast back to float32 only at the host readback
boundary (top-token scoring) and at host-side debug paths.

### S6 — One eval per token, in the hot path

The active path calls `mlx::core::eval(top_id_array, top_score_array)`
exactly once per generated token. The full forward graph is built lazily
and evaluated by that one call. Adding extra `eval()` calls (e.g. to read
back KV cache or to materialize intermediates for inspection) destroys the
laziness benefit and effectively serializes the pipeline.

Diagnostic readbacks may exist behind flags but must not fire by default.

### S7 — Run-to-run timing variance is real

On a busy Mac, generation timing varies ±25–40 % run-to-run. Always look at
the best-of-N before claiming a speedup or regression. The fused-QK kernel
"regression" turned out to be within the noise band.

### S8 — Output is allowed to diverge in bf16

Switching from fp32 to bf16 produces a different token sequence at greedy
temperature. Both are "correct" — bf16 matches what MLX would produce in
bf16 mode. Do not treat token divergence as a bug if the text remains
coherent. (Document this in step contracts so callers know to expect it.)

---

## Anti-Standards (do not pursue)

- Re-implementing MLX's quantized matmul in a custom kernel
- Adding per-layer host readbacks or per-segment validators to the hot loop
- Loading weights into CPU memory during generation
- Driving one token or one layer at a time from CoffeeScript
- Treating "one larger Objective-C++ helper call" as native execution
  ownership when the helper still copies weights / waits on layer boundaries

---

---

## Speculative Decode — Phase Status (May 2026)

Goal: B+1 tokens per forward pass by using a cheap draft model + one batched verify pass.

### Completed phases

**Phase 1 — Batched forward probe (`batchForwardProbe`)**

B tokens at the same position in a single `[B, hidden]` forward pass (no KV cache).
Promotes GEMV → GEMM. Timing: B=1: 508ms, B=4: 555ms total (3.66× per-token), B=8: 981ms (4.14×).
Test: `test/batch_forward_probe.coffee` — all pass.

**Phase 2 — Batch verify with prefix KV (`batchVerifyProbe`)**

Two-stage:
1. Prefix pass: autoregressive, builds KV cache for `prefix_len` tokens.
2. Draft verify pass: B draft tokens as `[1, q_heads, B, head_dim]` SDPA against prefix KV, with causal mask.

Key bug fixed: `[B*heads, dim]` → `[1, heads, B, dim]` requires transpose-then-reshape (not direct reshape) to preserve per-token head ordering.

Timing: B=4 draft verify ≈ 110ms (vs 660ms for B=4 forward without prefix KV).
Test: `test/batch_verify_probe.coffee` — all pass.

**Phase 3 — Naive spec decode step (`specDecodeStep`)**

Uses same model as both draft and target. Greedy acceptance always accepts all B tokens + bonus.
Proved: verify[d] == draft[d+1] for all d (same model). B=4 verify ≈ 85ms vs draft_gen ≈ 140ms.
Test: `test/spec_decode_step.coffee` — all pass.

**Phase 4 — Stochastic acceptance sampling (`specDecodeSampleStep`)**

Extends Phase 3 with Leviathan et al. (2023) acceptance:
- `accept_prob = min(1, p_target(draft[d]) / p_draft(draft[d]))`
- On rejection at position d: sample correction from `max(0, q-p)+` normalized.
- temperature=0: reduces to greedy (accept iff verify argmax == draft token).

Key correctness: draft_tokens[0] is ALWAYS accepted (it's drawn from the same target distribution as logits_prefix). Positions d=1..B-1 compare against logits_b[d-1] (shifted by 1 vs naive intuition).

With same model: p_target = p_draft everywhere → allAccepted always true at any temperature.
Accept overhead: ~0.3ms (negligible). Stores full draft logits [B, vocab] for rejection correction.
Test: `test/spec_decode_sample.coffee` — all pass including bit-identical match with Phase 3 at temp=0.

### Pending phases

_(none — Phases 1–5 all complete)_

### Findings from Phase 5 (May 2026)

**Phase 5 — Cheap draft model (layer-skip)** — COMPLETE

Function: `specDecodeLayerSkip(sessionHandle, prefixTokenIds[], draftLen, draftLayerCount, temperature)`.
Test: `test/spec_decode_layer_skip.coffee` — all pass.

Timing (B=4, median of 3 runs):
- draftLayerCount=6: draftGenMs ≈ 42ms  (3.36x faster than full-model draft)
- draftLayerCount=36: draftGenMs ≈ 141ms

**Acceptance rate at draftLayerCount=6: ~25%.** Token 47734 repeats every step — the 6-layer
model has insufficient depth to produce diverse predictions. This is too low for worthwhile speedup.

**Practical finding**: 6 layers is too shallow. Next tuning target is draftLayerCount=12–18
to find the layer count where accept rate × draft-speedup is maximized. At 25% acceptance
with B=4, effective throughput ≈ 16 tok/s — no gain over plain generation. Need ≥ 60% to benefit.

The `GypsySpecDecodeLayerSkip` implementation correctly reuses the first K layers of the
verify KV cache for draft generation (no copy), captures `draft_hidden_snap` at layer K-1,
and applies full Leviathan 2023 acceptance including correction sampling.

### Implementation location

All spec decode functions live in `metal/metal_llm_node.cpp` between the
`GypsyBatchForwardProbe` section and `// Module INIT`.

Exports: `batchForwardProbe`, `batchVerifyProbe`, `specDecodeStep`, `specDecodeSampleStep`, `specDecodeLayerSkip`.

---

## Pointer Index

- live status: `gypsy/STATUS.md`
- original strategic intent: `gypsy/README.md`
- protocol surface: `gypsy/PROTOCOL_DESIGN.md`
- failure history: `gypsy/DIRECTIVE_FAILURES.md`
- production entry: `scripts/prompt_ite/generate_prompt_gypsy_ite.coffee`
- production config: `config/prompt_ite.yaml` (`generate_prompt_gypsy_ite`)
- step contract: `GPT/prompt_ite/generate_prompt_gypsy_ite.md`
