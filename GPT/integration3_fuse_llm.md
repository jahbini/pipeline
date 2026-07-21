> **Provenance note.** Authored 2026-07-22 in `~/development/mlxCoffee/GPT/`.
> Ported verbatim on 2026-07-22.

# Integration 3 — `fuse_llm` recipe (adapter fuse through the recipe system)

_2026-07-22._ Follows [`integration2_train_llm.md`](integration2_train_llm.md). Closes the chat → train → fuse loop.

## Decision

Third and last of the initial three sibling recipes. `fuse_llm` merges a LoRA adapter into a base model's weights and writes a self-contained model dir with no runtime adapter. Backend: `L.callLLM({op:'fuse', ...})` → `mlx/lora/fuse.coffee::fuseAdapter`, in-process node-mlx.

One step. Consumes two directories (base model + adapter), produces one directory (fused model) + one JSON artifact (`fuse_run_record`). No `llm:` block — the math is fully determined by `adapter_config.json` (rank, alpha, wrapped_paths) and the base model's `config.json.quantization` block; there are no tunable numbers.

## Why no `llm:` block

Both prior integrations used the `llm:` block for camelCase numeric knobs (`maxTokens`, `iters`, `batchSize`, ...). Fuse has none — the operation is deterministic given (base, adapter). If tunable behavior is ever needed (e.g. mix ratio for interpolated fuse, per-layer scale multipliers), those go under `llm:` and get plumbed through `fuseAdapter`'s currently-unused `opts` arg. Today: no such need, no block, cleaner recipe.

## Files

- **New:** `config/fuse_llm.yaml` — one-step recipe, three filesystem-path params (base, adapter, target).
- **New:** `scripts/fuse_llm/fuse_llm.coffee` — step body. Pre-checks all three dirs exist, calls `L.callLLM({op:'fuse', baseModelDir, adapterDir, targetModelDir})`, writes `fuse_run_record` with merge stats (`merged_layers`, `output_bytes`, `output_gb`, `elapsed_sec`).
- **New:** `test/stage4_fuse_smoke.coffee` — end-to-end smoke. Requires Stage 3 to have run first (adapter must exist). Verifies exit, ui-run, experiment merge, target dir contents (model.safetensors + config.json + tokenizer.json + **no adapter_config.json**), and fuse_run_record shape.
- **Edited:** `test.sh` — adds Stage 4.
- **New:** this file, `GPT/integration3_fuse_llm.md`.
- **Edited:** `GPT/README.md` — index entry.

## What the run produces on disk

After stage4 runs, `pipes/Qwen_Qwen3-4B-Instruct-2507/` gets:

- `build/model_fused_llm/model.safetensors` — full fused model weights (~2.3 GB for Qwen3-4B 4-bit).
- `build/model_fused_llm/config.json` — copied from base, includes the same `quantization` block (fuse preserves quantization: dequant → add delta → requant with the same group_size/bits).
- `build/model_fused_llm/tokenizer.json`, `tokenizer_config.json`, `generation_config.json`, etc. — copied from base.
- `build/model_fused_llm/` intentionally does **NOT** contain `adapter_config.json` or `adapters.safetensors`. The whole point of fuse is producing a stand-alone model.
- `out/fuse_run_record.json` — `{mode: 'fuse_llm', merged_layers: 72, output_bytes: ~2.3e9, output_gb, elapsed_sec, ...}`.
- `experiment.yaml`, `state/ui-run.json`, `state/step-fuse_llm.json`, `params/fuse_llm.yaml` — standard runner bookkeeping.

The fused model is now consumable by `chat_llm` with no changes — set `quantized_model_dir: build/model_fused_llm` in an override and generation happens against the merged weights, no runtime LoRA wrapping.

## Design decisions

- **`needs: []`** even though the step obviously needs the adapter and base to exist. Reason: the runner's artifact registry is file-typed (each artifact declares a `target:` path to a *file*), and both inputs here are **directories**. A `needs:` on a dir-typed artifact would either need a new registry type or a synthetic marker file. Keeping `needs: []` and using step-level pre-checks (with clear error messages naming the missing dir) is simpler and mirrors how `@jahbini/pipeline`'s `run_lora_train_ite` handles its own dir-typed inputs.
- **No `dependency_on:` chaining across recipes.** `fuse_llm` doesn't declare `depends_on: [run_lora_train_llm]` because they're separate recipes, run separately. `test.sh` sequences them because stage4 depends on stage3's artifacts, not because the runner enforces it. If a caller wants a combined `train_and_fuse.yaml` recipe with both steps, that's a straightforward compose (both scripts read from a shared `run:` block).
- **Target dir is not cleared by the recipe/step** — the smoke clears it for repeatability, but a human running the recipe by hand can rely on fuseAdapter overwriting `model.safetensors` in place. `copyMetadata` in `fuse.coffee` creates the dir if missing and copies non-safetensors files each time (overwriting is fine — they're identical to base).
- **Memory footprint is ~2 GB peak** for Qwen3-4B 4-bit: entire base weights held in RAM to dequant → add delta → requant. Much less than training (no gradients, optimizer state, activations). Safe on the laptop where training must stay tiny.
- **`fuse_run_record` includes both `output_bytes` and `output_gb`** — the bytes number is authoritative; the GB float is a human-friendly convenience. Same principle as writeStory's per-step records that log both raw and derived values.

## Anti-standards

- **Do not put `llm:` block into `config/fuse_llm.yaml` "just for consistency."** The block is a signal that there are tunable knobs. An empty or placeholder block misleads readers into thinking there are. Add it only when a real knob shows up.
- **Do not run fuse on the LIVE base model dir** (i.e., don't set `target_model_dir: build/model4`). fuseAdapter would overwrite `model.safetensors` in place, destroying the base and making the adapter unfusable in the future. The recipe's default `target_model_dir: build/model_fused_llm` deliberately points at a distinct dir; keep it that way.
- **Do not expect the fused model to be numerically identical to base+adapter at inference time.** For quantized bases, `dequant → add → requant` introduces new quantization noise on top of the merged weights. This is the same behavior `mlx_lm.fuse` has — cheap-fused models are "close enough" for inference but not bit-exact vs the base+adapter runtime combination. If a caller needs bit-exact behavior, use `chat_llm` with `adapterPath: build/adapter_llm` instead of fusing.

## Verification (`test/stage4_fuse_smoke.coffee`)

Assertions:

1. **Pre**: base model has `config.json`; adapter has `adapter_config.json` + `adapters.safetensors` (produced by Stage 3).
2. **Runner exit 0** within 5-min wall time (fuse of Qwen3-4B 4-bit expected ~15–60 s).
3. **`state/ui-run.json`**: `pipeline: fuse_llm`, `status: done`.
4. **`experiment.yaml`**: `fuse_llm` block present with `target_model_dir: build/model_fused_llm`, `adapter_dir: build/adapter_llm`.
5. **`build/model_fused_llm/model.safetensors`**: written, > 1 GB.
6. **`build/model_fused_llm/config.json`** and **`tokenizer.json`**: copied.
7. **`build/model_fused_llm/adapter_config.json`**: **absent** (fuse produced a self-contained model, not a copy of the adapter).
8. **`out/fuse_run_record.json`**: `mode: fuse_llm`, `merged_layers > 0` (should be 72 for Qwen3-4B with default targets `selfAttn.qProj` + `selfAttn.vProj` across 36 blocks), `output_bytes > 1 GB`, positive `elapsed_sec`.

## Closing the loop

With Integrations 1, 2, and 3 all green, the mlxCoffee side now has the full chat → train → fuse → chat cycle expressible entirely through `callLLM` recipes:

- `chat_llm` — generate text
- `train_llm` — train an adapter from a JSONL corpus
- `fuse_llm` — merge an adapter into weights
- Re-run `chat_llm` with `quantized_model_dir: build/model_fused_llm` — generate text from the fused model (no override needed on the recipe; just change the pipe's override to point at the fused dir)

That's the complete LoRA lifecycle, all in-process JS, all through the recipe system, no Python spawn anywhere. The grandfathered `L.callMLX` path stays reproducible for any legacy recipe that needs it (`train_lora.yaml`, `full.yaml`, `story*.yaml`, etc.), but the LLM door is now the discoverable, ergonomic default for new work.

## Not proven / not done

- **Round-trip inference of the fused model** (`chat_llm` against `build/model_fused_llm`). Stage 4 verifies the file layout but doesn't load and generate from the fused weights. A tiny follow-up smoke — Stage 5 — would prove the fused model actually loads and produces reasonable output. Trivial add given all the pieces already exist; deferred as "gilding" until it's needed.
- **Numerical comparison** base+adapter (runtime) vs fused (pre-baked). Would prove fuse math is correct beyond "produces sane output." Not needed for plumbing verification; would be a research question, not an integration test.
- **Fuse with non-quantized base**. Our base is 4-bit Qwen3. `fuseAdapter` has an unquantized code path (just `mx.add baseW, delta`) that's untested through the recipe system. Trivial when a fp16 base shows up.
