Trainer contract: `mlx/lora/train.coffee` (native in-process LoRA)

Verified 2026-07-25 by read-only investigation. The installed copy in
writediary's `node_modules` (package hash b9b8e82) is byte-identical to the
`~/pipeline` source for `train.coffee`.

What it is:
- The pipeline package's OWN trainer, built on `@frost-beta/mlx` primitives
  (`nn.valueAndGrad`, `optimizers.AdamW`, `nn.losses.crossEntropy`). NOT
  mlx-lm, NOT `@frost-beta/llm` (that package has no training code).
- Reached via the LLM door: `scripts/lora_ite/run_lora_train_ite.coffee`
  `L.callLLM({op:'train',…})` → `mlx/llm_dispatch.coffee` (`when 'train'` →
  `trainOp` → `trainLoRA`) → `mlx/lora/train.coffee::trainLoRA` (loop, optimizer
  `AdamW`, `valueAndGrad`).

Sequence length & truncation:
- Enforced in `tokenizeCorpus` (train.coffee): `ids = ids[...maxSeqLen]` when
  over length. **Keeps the HEAD, discards the TAIL.** Default `maxSeqLength`
  2048; override via `max-seq-length`/`maxSeqLength`. Truncation is **silent**
  (no log line). Upstream `build_lora_dataset_ite` budgets rows to ~1024 est
  tokens, so this rarely fires — see that step's doc for the one oversized-
  single-sentence path that reaches it.

EOS / stop supervision:
- Rows carry NO explicit EOS/`<|im_end|>` (dataset builder emits raw
  `prompt+completion`). Trainer uses raw `tokenizer.encode` (NOT `llm.encode`,
  so the generation-path EOS-strip does not apply). Any tokenizer-appended EOS
  sits at the tail and is dropped by head-truncation on over-long rows. Net:
  weak/no stop-token supervision; none on truncated rows.

Loss mask (buildBatch):
- **Pad-only.** `m = if (i+1) < real then 1 else 0` — a position contributes
  iff its target is a real (non-pad) token. Loss =
  `sum(perTok*mask)/max(sum(mask),1)`.
- **Prompt tokens are NOT masked.** `text = prompt + completion` is one
  autoregressive sequence; the model is trained to predict the prompt/fragment
  too. This is text-completion LM training, not completion-only masking.

Zero-token guarantee:
- `tokenizeCorpus` keeps a sequence only if `ids.length >= 2`, so contributing
  positions = `real-1 >= 1`. No example contributes zero. Backstop:
  `mx.maximum(mx.sum(mask), 1)` in the loss denominator prevents div-by-zero
  even for a hypothetical all-pad batch.

Generation-path KV cache (memory):
- **`maxKVSize` is NOT set anywhere.** `mlx/session_api.coffee` `generate` and
  `embed` call `llm.generate` without it, so `@frost-beta/llm` builds a plain
  growing `KVCache`, not a size-capped `RotatingKVCache`. `qwen3.coffee`
  `getDecoderKVCacheOptions` returns `{nLayers}` only. KV memory grows with
  prompt + every generated token, uncapped.

Memory / OOM linkage (why the diary sweep dies — see log_scan_reference.md):
- Training peak scales with `T`: loss materializes full `[B,T,V]` logits cast
  to float32 with Qwen's large vocab. Longer rows / higher `iters` → bigger
  spike; checkpoint save is a second spike.
- Generation compounds: no EOS supervision → adapter output tends not to stop
  → runs to `maxTokens`; uncapped KV → memory grows the whole way.
