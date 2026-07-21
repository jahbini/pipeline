> **Provenance note.** Authored 2026-07-22 in `~/development/mlxCoffee/GPT/`.
> Ported verbatim on 2026-07-22. The "laptop memory hard rule" (do not
> set `iters > 20` in `config/train_llm.yaml`) applies in this repo too
> and reinforces the pre-existing HARD RULE in `GPT/README.md` about
> never tuning inside recipe files.

# Integration 2 — `train_llm` recipe (LoRA training through the recipe system)

_2026-07-22._ Follows [`integration1_chat_llm.md`](integration1_chat_llm.md).

## Decision

The second sibling recipe. `train_llm` trains a LoRA adapter via `L.callLLM({op: 'train', ...})` — same shape as Integration 1, but on the training op instead of generation. This is the recipe-system equivalent of the mlxCoffee `train_lora.yaml` grandfathered path (which uses `L.callMLX('lora', ...)` → `python -m mlx_lm lora`).

The recipe is one step. Data-prep chain (md2segments → prepare_training_data) is intentionally out of scope for the first integration — the recipe assumes `{train,valid}.jsonl` already exist at `training_dir`. Adding upstream steps is Integration 2b when we're ready to plumb the full corpus flow.

## The `llm:` block on a train step

Same convention as Integration 1 but the payload maps to `trainLoRA`'s opts instead of `session.generate`'s opts:

```yaml
run_lora_train_llm:
  run: train_llm/run_lora_train_llm.coffee
  adapter_path: build/adapter_llm
  test_only: false
  llm:
    batchSize: 1
    iters: 5
    maxSeqLength: 64
    learningRate: 5.0e-5
    loraRank: 4
    loraAlpha: 8
    stepsPerReport: 1
    stepsPerEval: 1000
    saveEvery: 5
```

Compare the grandfathered MLX sibling shape (from `train_lora.yaml` / `scripts/train_markdown/lora_train.coffee`):

```yaml
lora_train:
  batch_size: 1              # step-level, snake_case
  iters: 200
  max_seq_length: 1024
  learning_rate: 0.00005
  adapter_path: build/adapter
  # (constructed and passed to callMLX inside the step)
```

Two big differences the `llm:` block makes explicit:
- **Backend affinity is visible in the recipe** — reader sees `llm:` and knows this runs in-process JS.
- **Names are camelCase, mapped 1:1 onto `trainLoRA(opts)`** — no CLI-flag translation layer, no kebab-case-to-camelCase mystery.

The step script hardcodes `op: 'train'` and derives `train` / `test` booleans from a `test_only: false` step param (mirrors the grandfathered `test_only` in `scripts/train_markdown/lora_train.coffee`).

## ⚠️ Laptop memory constraint

This laptop cannot complete a full LoRA training run without swap thrash. Yesterday's 200-iter × 1024-seq attempt hit ~25 GB in swap. The recipe defaults are **intentionally smoke-friendly** (`iters: 5, maxSeqLength: 64, batch: 1, rank: 4`) so `test.sh` runs in ~10 s.

Real training runs belong on a bigger machine. Path: drop an `override/train_llm.yaml` in the pipe that sets bigger `iters` / `maxSeqLength` / etc. **Do not edit `config/train_llm.yaml` for tuning** — same hard-rule discipline as `~/pipeline` (`GPT/README.md` § "HARD RULE"): recipes are stable baselines; overrides carry deployment-specific numbers.

## Files

- **New:** `config/train_llm.yaml` — one-step recipe with tiny defaults.
- **New:** `scripts/train_llm/run_lora_train_llm.coffee` — step body. Reads `quantized_model_dir`, `training_dir` (falls through to global `run.training_dir`), `adapter_path`, `test_only`, `llm:` block. Calls `L.callLLM({op:'train', ...})`. Captures the trainer's log via an `opts.log` callback (both to console and to a buffer) and writes it as the `lora_stdout` artifact. Writes `lora_run_record` (JSON) with training config + result.
- **New:** `test/stage3_train_smoke.coffee` — end-to-end smoke that stages a 4-row fixture, clears stale adapter, spawns the runner, verifies 15+ assertions covering exit code, `state/ui-run.json`, `experiment.yaml`, adapter files (`adapters.safetensors`, `adapter_config.json`), and log/run-record content.
- **Edited:** `test/stage2_chat_smoke.coffee` — now writes its own `control_override.yaml` at start (was previously reading a pre-set value; now idempotent across runs where Stage 3 overwrites the file).
- **Edited:** `test.sh` — adds Stage 3.
- **New:** this file, `GPT/integration2_train_llm.md`.
- **Edited:** `GPT/README.md` — index entry.

## What the run produces on disk

After stage3 runs successfully, `pipes/Qwen_Qwen3-4B-Instruct-2507/` gets:

- `build/train/train.jsonl`, `build/train/valid.jsonl` — the 4-row fixture (staged by the smoke if missing; not overwritten if the human has real data there).
- `build/adapter_llm/adapters.safetensors` — trained LoRA weights (~6 MB for a rank-4 Qwen3-4B adapter, 72 wrapped layers).
- `build/adapter_llm/adapter_config.json` — `{rank: 4, alpha: 8, dropout: 0, targets: [selfAttn.qProj, selfAttn.vProj], wrapped_paths: [...]}` — mlx-lm compatible, consumable by the fuse (Integration 3) and adapter-path generate (already in `callLLM({op:'generate', adapterPath})`).
- `out/lora_train.txt` — captured `[lora]` log lines from the trainer (wrapped, tokenize, per-step train_loss, checkpoint).
- `out/lora_run_record.json` — `{mode: 'train_llm', trained: true, iters: 5, batch_size: 1, elapsed_sec, adapter_path, ...}`.
- `experiment.yaml` — merged recipe with the `run_lora_train_llm.llm` block visible.
- `state/ui-run.json` — `{pipeline: 'train_llm', status: 'done', ...}`.
- `state/step-run_lora_train_llm.json` — per-step status.
- `params/run_lora_train_llm.yaml` — resolved params the step saw.

## Design decisions worth flagging

- **Step reads `training_dir` via param fall-through to `run.training_dir`.** No per-step override needed for the common case — global recipe says `training_dir: build/train`, step uses it. If a specific run wants a different data dir, drop it in `override/train_llm.yaml` at the step or global level; both work.
- **`resume_adapter_file` supported but not defaulted.** Grandfathered `lora_train.coffee` had a `resolveResumeFile` helper that auto-discovered the latest checkpoint. `trainLoRA` in `mlx/lora/train.coffee` takes a `resumeFile` opt but doesn't auto-discover. The step passes it through if set; auto-discovery is a Integration 2b concern (currently no step needs it — 5-iter runs don't produce useful resume points).
- **The step captures the trainer's log via `opts.log` callback**, not by intercepting stdout. Cleaner separation: `console.log` gets the human-visible mirror; the buffer gets the artifact copy. Also decouples us from Node stdout redirection which is fragile.
- **`op: 'op'` and `log:` in the `llm:` block are filtered out** by the step-side merge (`continue if key is 'op' or key is 'log'`). This is defense-in-depth against a mistuned override — if someone puts `op: generate` in `override/train_llm.yaml`, the step ignores it. The recipe/override never gets to overwrite what the step owns.
- **`saveEvery: 5` matches `iters: 5`** so the only checkpoint written is the final one. Larger real runs would use `saveEvery: 100` to get intermediate checkpoints.
- **`stepsPerEval: 1000` effectively disables eval** during the smoke — 5 iters × valid batches was pure overhead for a plumbing test. Real training runs override this.

## Anti-standards

- **Do not put training data-prep steps into `config/train_llm.yaml`.** The recipe declares one training step. If a pipeline needs data prep, a separate chain (e.g., `train_llm_full.yaml`) can `depends_on:` the prep steps and reuse `run_lora_train_llm.coffee`. Keeping this recipe minimal makes it easy to verify.
- **Do not set `iters > 20` in `config/train_llm.yaml`.** That's a tuning number and belongs in an override. Yesterday's 200-iter run in a recipe file was the specific mistake that caused swap thrash on this laptop before we could catch it.
- **Do not have the step call `trainLoRA` directly.** Always via `L.callLLM({op:'train', ...})`. That's the whole point of the two-door API — a step that reaches into the internal dispatch table has no observable difference from the outside but is invisible to future runner instrumentation (`state/ui-run.json`, `debug_llm`, params logging).

## Verification (`test/stage3_train_smoke.coffee`)

Assertions:

1. **Pre**: pipe has `build/model4/config.json`.
2. **Fixture**: `build/train/{train,valid}.jsonl` present (staged if missing).
3. **Runner exit 0** within 3-min wall time (~10 s expected for the 5-iter smoke).
4. **`state/ui-run.json`**: `pipeline: train_llm`, `status: done`.
5. **`experiment.yaml`**: `run_lora_train_llm` block present with `llm.iters: 5`, `llm.maxSeqLength: 64`, `adapter_path: build/adapter_llm` (proves recipe merged).
6. **`adapters.safetensors`** written, > 1000 bytes.
7. **`adapter_config.json`**: `rank: 4`, `alpha: 8`, non-empty `wrapped_paths`.
8. **`out/lora_run_record.json`**: `mode: train_llm`, `trained: true`, `iters: 5`, positive `elapsed_sec`.
9. **`out/lora_train.txt`**: contains `[lora]` prefix + `train_loss` values + `wrapped` line.

## What's proven vs. what's not

**Proven by a green stage3:**
- `L.callLLM({op: 'train'})` reaches `trainLoRA` in-process
- LoRA layer wrapping fires on Qwen3-4B through the recipe system
- Adapter files write to disk in mlx-lm-compatible format
- Trainer log flows out via `L.make` → artifact registry → `out/lora_train.txt`
- `run_lora_train_record` captures training config for downstream consumers (eval, fuse)

**Not proven** (and deferred):
- **Training quality**: 5 iters × noisy batch-1 loss is not evidence of learning. Real proof would be sustained loss decrease over 100+ iters on a real corpus — laptop can't do that.
- **Full data-prep chain**: this recipe assumes JSONL exists. Piping md → segments → JSONL → training in one run is Integration 2b.
- **Resume from checkpoint**: `trainLoRA` supports `resumeFile` opt, step passes it through, but the recipe doesn't wire it. Adding requires either auto-discovery (like grandfathered `resolveResumeFile`) or an explicit path in an override.
- **Adapter consumption**: the produced adapter should work with `L.callLLM({op: 'generate', adapterPath})` and `L.callLLM({op: 'fuse', adapterDir})` — proven at the module level, not yet through the recipe system. Integration 3 covers the recipe-level round-trip.

## Path to Integration 3

Integration 3 = `fuse_llm` recipe. Small — one step that reads a trained adapter (from Integration 2's output) and merges it into base weights, producing a new self-contained model dir. Follows the same pattern: recipe with `llm:` block, step calling `L.callLLM({op: 'fuse', ...})`. Together with Integrations 1 and 2, that closes the loop: chat → train → fuse → chat (with the fused model).
