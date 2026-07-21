> **Provenance note.** Authored 2026-07-22 in `~/development/mlxCoffee/GPT/`.
> Ported verbatim on 2026-07-22 as part of folding the in-process LLM
> door into `@jahbini/pipeline`. In this repo, `stripUiDirectives`
> already exists in `pipeline_runner.coffee` and handles the
> `[UI_textarea, ""]` form, so `chat_llm.yaml`'s `prompt_text` can (and
> should) use that directive form here — see `GPT/advice/2026-07-22.md`
> for the port-time deviation from the mlxCoffee original.

# Integration 1 — `chat_llm` recipe (first LLM-door step in the recipe system)

_2026-07-22._ Follows [`stage1_layout.md`](stage1_layout.md).

## Decision

The first sibling step exposed through the recipe/runner system. `chat_llm` is a single-step recipe that calls `L.callLLM({op: 'generate', ...})` on a Qwen3-4B mlx-lm model, produces text, and writes three artifacts (`chat_raw`, `chat_meta`, `chat_text`). It's the smallest recipe that proves the LLM door works end-to-end inside `pipeline_runner.coffee` — no data-prep chain, no adapter, no training.

Modeled directly on `node_modules/@jahbini/pipeline/config/prompt_ite.yaml` + `scripts/prompt_ite/generate_prompt_ite.coffee`. Same shape; only the backend and its param-block name changed.

## The `llm:` block convention (new)

Recipes today put backend-specific params in a per-backend block whose key names the backend:

- `mlx:` — kebab-case CLI-flag names, passed as-is to `L.callMLX('generate', mlxArgs)` which builds `--k v` argv for `python -m mlx_lm`.
- `llm:` — camelCase JS-native names, passed as-is (post `op` injection) to `L.callLLM({op, ...llmArgs})`.

Step scripts read whichever block matches their door. A step calling `callMLX` reads `L.param 'mlx'`; a step calling `callLLM` reads `L.param 'llm'`. The step **hardcodes the `op` selector** (e.g. `chat_llm` always uses `op: 'generate'`) — the recipe/override supplies data only, never the op.

Example — the `chat_llm` recipe's step block:

```yaml
chat_llm:
  run: chat_llm/chat_llm.coffee
  ...
  quantized_model_dir: build/model4
  prompt_text: ""              # default; overridden at run time
  llm:
    maxTokens: 128
    temperature: 0.7
    topP: 0.8
```

Compare the MLX sibling (from the exemplar `prompt_ite.yaml`):

```yaml
generate_prompt_ite:
  run: prompt_ite/generate_prompt_ite.coffee
  ...
  quantized_model_dir: build/model4
  prompt_text: [ UI_textarea, "" ]
  mlx:
    max-tokens: 1600
    temp: 0.7
```

Two visibly different backends, same recipe shape.

## Files

- **New:** `config/chat_llm.yaml` — one-step recipe.
- **New:** `scripts/chat_llm/chat_llm.coffee` — step body. Reads `prompt_text`, `quantized_model_dir`, optional `llm` opts. Calls `L.callLLM({op:'generate', ...})`. Writes `chat_raw`, `chat_meta` (native generate result stats), `chat_text`.
- **New:** `pipes/Qwen_Qwen3-4B-Instruct-2507/control_override.yaml` — populated with `pipeline: chat_llm` + `chat_llm.prompt_text: "The capital of France is"`. Stage 1c's runner picks up `pipeline` from control_override before falling back to legacy `override.yaml`, so this alone selects the recipe.
- **New:** `test/stage2_chat_smoke.coffee` — spawns `pipeline_runner.coffee` in the pipe's CWD, waits (2-min timeout), verifies exit code, `state/ui-run.json`, materialized `experiment.yaml`, and `out/chat.txt` + `out/chat_meta.json` content.
- **Edited:** `test.sh` — runs stage0 + stage1 + stage2 smokes in sequence.

## What the run produces on disk (finally the `experiment.yaml` the human asked about)

After `./test.sh` runs the stage2 smoke, `pipes/Qwen_Qwen3-4B-Instruct-2507/` contains:

- `experiment.yaml` — the materialized merged recipe. Should include the merged `chat_llm.prompt_text` value from `control_override.yaml`, the `llm:` block from `config/chat_llm.yaml`, and everything from the recipe's `run:` global block.
- `state/ui-run.json` — `{pipeline: 'chat_llm', pid, status: 'done', started_at, finished_at, hh_mm: null, logdir: null}`.
- `state/step-chat_llm.json` — per-step status.
- `params/chat_llm.yaml` — the resolved params the step actually consumed.
- `params/_global.yaml` — the `run:` block.
- `out/chat.txt` — the generated text (cleaned).
- `out/chat_raw.txt` — the raw text as returned by callLLM.
- `out/chat_meta.json` — generation stats (`tok_per_sec`, `generated_tokens`, `elapsed_sec`, ...).

If the smoke fails at any assertion, the runner's captured stdout/stderr is dumped into `test/stage2_smoke.log` for debugging.

## Design decisions worth flagging

- **`op` is not a recipe key.** Step scripts hardcode which callLLM op they need. This keeps the recipe surface stable (a recipe entry describes intent — "generate chat" — not implementation dispatch) and prevents a mistuned override from turning a generate step into a train step by accident.
- **The `llm:` block is optional.** If absent, `callLLM({op:'generate', modelDir, prompt})` uses `session_api`'s defaults (maxTokens=512, temp=1.0, topP=0.8). The recipe supplies explicit values for reproducibility.
- **`quantized_model_dir` is intentionally the same key name the `_ite` recipes use.** No JS-vs-MLX naming difference here — it's just a filesystem path. Only the backend-tunable params live under the backend-tagged block.
- **`prompt_text` default is empty string, not `[UI_textarea, ""]`.** UI directives require Stage 1c's stripUiDirectives step which we deliberately skipped. When the UI wires in later, the recipe can move to the directive form; for now, plain string default + required-non-empty check in the step body.
  > **@jahbini/pipeline port note:** this repo's `pipeline_runner.coffee`
  > already implements `stripUiDirectives` (at line 371) with
  > `UI_textarea` handling. In the ported recipe here, use the directive
  > form `prompt_text: [ UI_textarea, "" ]` for UI consistency.
- **No `depends_on: [never]` sibling toggling in this recipe** — chat_llm is a standalone recipe, not a fork of an existing one. If we wanted a Python-CLI-based `chat_mlx.yaml` sibling later, that'd be a separate recipe file.

## Anti-standards

- **Do not put `op` in the `llm:` block.** The step script owns it. Recipe/override supplies data only. A misplaced `op` in a yaml is a bug that will silently overwrite the step's hardcoded op via the `for own key of llmConfig` merge loop.
- **Do not add both `mlx:` and `llm:` blocks to the same step.** Each step calls exactly one door. A step needing both is actually two steps.
- **Do not manually create `pipe/experiment.yaml`.** The runner writes it. Any hand-created copy is stale within one run.
- **Do not add `mlx-lm`-style kebab-case keys to `llm:` blocks.** camelCase is the two-door signal at every call site (see `GPT/stage0_callLLM.md` §Anti-standards).

## Verification (`test/stage2_chat_smoke.coffee`)

Assertions:

1. **Pre**: pipe has `build/model4/config.json`; `control_override.yaml` selects `chat_llm`.
2. **Runner exit code == 0** after ≤2-min wall time.
3. **`state/ui-run.json`**: `pipeline: 'chat_llm'`, `status: 'done'`, `started_at` and `finished_at` present, `pid` recorded.
4. **`experiment.yaml`**: contains a `chat_llm` block with `prompt_text: "The capital of France is"` (proves control_override merged) and `llm.maxTokens: 128` (proves recipe baseline merged).
5. **`out/chat.txt`**: non-empty text.
6. **`out/chat_meta.json`**: `mode: 'chat_llm'`, `tok_per_sec > 0`, `generated_tokens > 0` (proves callLLM's native object return shape survived the runner and got persisted).

The 5-iter smoke on the model directly (from Stage 3c) already proved the trainer and generation math. Stage 2 additionally proves those work through the DAG/memo/override/state layer of the runner — which is what "integrated into the recipe system" actually means.

## Not done in Integration 1

- **Adapter-path generation** — chat_llm doesn't set `adapterPath`. A follow-up sibling (`chat_llm_adapter.yaml` or a param toggle) can add it.
- **UI wiring** — the recipe uses plain `prompt_text: ""`, not the UI directive form. Later.
  > **Port note:** this repo does wire UI directives; port uses `[UI_textarea, ""]` form.
- **Cleanup of stale artifacts on run start** — the smoke does this itself (deletes prior `out/chat.txt` etc. before spawning) so we know we're reading fresh output. The runner itself does not clean out/ between runs.
- **Sibling training / fuse recipes** — Integration 2 & 3.
