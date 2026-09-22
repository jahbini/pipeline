---
name: helper-adapter-v1-lemon
description: "The 2026-09-17 scheduling adapter (rank-8, 50 iters, 17 seed rows) memorized JSON shape but forgot how to reason — do not use in production"
metadata: 
  node_type: memory
  type: project
  originSessionId: d0eb8cb2-39e1-4813-b17d-dda7493cfc5d
---

Adapter at `~/pipeline/mlx/helper_lora/adapter/` (also archived at `~/pipeline/mlx/helper_lora/adapter_v1_scheduling_2026-09-17/`) is a lemon. Trained on peer via SSH after laptop OOM.

**What it does wrong:**
1. **Memorizes JSON shape** — every field present, schema-correct, `confidence` field emitted (which base+few-shot omits).
2. **Forgot how to reason** — attempt 1 (temp 0.2) regurgitates the training thinkPrefill catalog verbatim inside `<think>` and never closes it; attempt 2 (temp 0.08) skips think entirely and dumps JSON with the `reason` field stuck in a sentence loop (same clause repeated 3–4×).
3. **Hallucinates** — e.g. calls Mistral-Nemo "Llama-2-70b, a small model that overfits."
4. **Still leaks `target_recipe` on state-only actions** — the exact bug the adapter was supposed to fix, unfixed.
5. Picks wrong actions (reject where reset is correct on empty-sqlite pattern).

**Why:** classic tiny-corpus LoRA failure — 17 rows × 50 iters × rank 8 alpha 16 is wildly over-parameterized. Memorization + catastrophic forgetting.

**How to apply:**
- Do not enable via `HELPER_LLM_ADAPTER_PATH` in production.
- Approach A (base + full few-shot from `helper_training_examples where source='rule'`) is currently better; use it via `helper.schedule({examples})`.
- Before retraining: expand corpus to 200–500 rows via templated perturbation (see [[helper-kag-design]] for the schema that makes this cheap to mine), drop rank to 4 or halve iters, save_every=5 so we can pick the least-fried checkpoint.
- Evidence lives in `/private/tmp/.../scratchpad/peek_adapter.coffee` output (session-scoped, ephemeral).

Related: [[helper-reason-mining]] (why we're studying the base model's reasoning), [[helper-kag-design]] (the retrieval scheme that replaces bulk few-shot).
