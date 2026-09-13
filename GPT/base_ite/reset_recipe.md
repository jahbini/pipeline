# reset recipe — human-controlled targeted reset

**Recipe file**: `config/reset.yaml`
**Trigger**: human, from the writer UI's control panel. Not chained by any other recipe.
**Steps** (unchanged from earlier):

1. `reset_base_environment_ite` — reads the checkbox params, wipes as directed
2. `download_model` — idempotent; skips when model dir is fresh
3. `seed_story_sqlite` — idempotent; skips when stories are populated
4. `quantize_model` — idempotent; skips when the `-mlx4` dir has a matching quantization block

## The four checkboxes

| flag | wipes | fires |
|------|-------|-------|
| `force_lora_reset` | `build/adapter`, `build/adapter_llm`, `build/model_fused_llm` | `loraCycleReset` |
| `force_oracle_reset` | *(no on-disk wipe)* | `oracleReset` |
| `force_download` | `build/model`, `build/model4` | *(triggers download+quant on next step)* |
| `force_full_reset` | every `build/*` dir | `sqliteResetAll` |

Every flag defaults to `false`. Bare-click reset is safe on any pipe — only transient `out/*.json` gets wiped.

## When to use which

- **Pipe is stuck in "no-adapter" loops** (business-truth failing on `train_lora(no-adapter)`)
  → `force_lora_reset: true`. Clears the poisoned `lora_training_run_stories` rows that were preventing `select_lora_stories_ite` from finding fresh work, and removes any half-written adapter dir. Next elementary picks the full 169 stories again and trains a real adapter.

- **KAG entries are wrong / bad prompt / model change requires re-extract**
  → `force_oracle_reset: true`. Clears the oracle side (kag_entries, embeddings, simplifications) but leaves stories + any existing lora work. Next elementary re-oracles.

- **Downloaded model files corrupted or you upgraded a repo**
  → `force_download: true`. Only wipes `build/model[4]`.

- **You truly want to start over** (rare — throws away 20+ minutes of quantize + hours of oracle)
  → `force_full_reset: true`.

- **A pipe just needs its `out/` transients cleared** (e.g. stale cycle state after a crash)
  → Run the recipe with no flags ticked.

## Why this design exists (2026-09-13)

Before this rewrite, `reset_base_environment_ite` was **the first step of `elementary`** and it unconditionally wiped `build/adapter/`. A 2026-09-11 fix had already added a sqlite-preserve guard (so re-running reset wouldn't blow away oracle work), but that guard only covered sqlite, not the adapter file.

The asymmetry: every elementary retry would
- **preserve** `lora_training_run_stories` (169 stories marked used)
- **wipe** `build/adapter/adapters.safetensors`

`select_lora_stories_ite` then read the preserved usage table, found zero fresh stories, and the drain-safe empty-batch path meant no training happened, no adapter got written, business-truth said "no-adapter", daemon re-queued elementary, back to step 0. This is the failure fingerprint on `qwen3-1-7b` and `qwen3-4b` (elementary attempted ~10 times in a few hours; the sqlite `lora_training_runs` still shows exactly one legitimate run from 2026-09-12).

Fix: pull setup out of elementary. Elementary now assumes the pipe is `continue`-blessed and skips reset entirely. Adapters survive across retries. `newborn.yaml` still runs the full setup chain for fresh pipes. `reset.yaml` becomes a human-invoked hospital tool with surgical checkboxes.

## Related

- [reset_base_environment_ite.md](./reset_base_environment_ite.md) — step-level contract
- `~/pipeline/config/elementary.yaml` — header docstring cross-references this file
- `~/pipeline/GPT/lora_ite/record_lora_training_ite.md` — the belt-and-suspenders adapter-presence check
