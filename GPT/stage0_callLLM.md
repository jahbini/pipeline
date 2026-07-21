> **Provenance note.** Authored 2026-07-22 in `~/development/mlxCoffee/GPT/`
> as design record for the two-door LLM API. Ported verbatim into
> `@jahbini/pipeline` (this repo) on 2026-07-22 as part of folding the
> in-process LLM door into the runner. "This repo" in the original text
> = mlxCoffee; "the exemplar `@jahbini/pipeline`" = this repo. The
> two-door contract, anti-standards, and validation stages remain
> normative here. See `GPT/advice/2026-07-22.md` for the port plan.

# Stage 0 — `callLLM` alongside grandfathered `callMLX`

_2026-07-22._ Follows [`phase3_lora_and_fuse.md`](phase3_lora_and_fuse.md) and supersedes its "unified callMLX dispatcher" architecture.

## Decision

Two doors, no shared code path:

- **`L.callMLX(cmdType, payload)`** — grandfathered. Always shells out to `python -m mlx_lm <cmdType> --k v ...`. Not touched by any in-process logic. `cmdType` is Python-CLI shape (`'lora'`, `'generate'`, `'fuse'`, `'convert'`). Payload keys are kebab-case (`'adapter-path'`, `'max-tokens'`) because that's what mlx-lm's CLI accepts.
- **`L.callLLM(params)`** — new, in-process, node-mlx. Single params dict. `params.op` selects the operation (`'train'`, `'generate'`, `'fuse'`). All other keys are camelCase (`modelDir`, `adapterPath`, `maxTokens`, `batchSize`, `maxSeqLength`, `learningRate`). Return value is the underlying function's native shape — no stdout-shaped string parity. Unknown op throws.

The two doors never fall through to each other. If `callLLM` fails, it does not silently retry via Python; the call site sees the error. Same the other way. This is deliberate: yesterday's Phase 3 bridge did unify the two paths behind `callMLX` with an internal `canHandleInProcess` check + Python fallback, and that shape hid which backend actually ran, which caller mattered for debugging, and which regressions were which. Stage 0 breaks that ambiguity.

## Why two doors

- **Grandfathering is honest.** The Python path is untouched and stays reproducible for the year of prior recipes that call it. No behavior drift.
- **The new door has a different calling convention.** `callLLM({op, …})` vs `callMLX('cmdType', {…})`. A reader can't confuse them at the call site. That was Mr. Hinds's explicit request: "New stuff should have a different name and calling sequence."
- **No fabricated fallbacks.** If `callLLM(params)` can't service the request, it throws at the point of use. Python fallback is not a bug fix; it's the caller's decision to make.
- **camelCase on the new door** because we're not inheriting mlx-lm's CLI naming. `adapterPath` reads better in JS than `'adapter-path'`. `callMLX` keeps kebab-case because it literally builds `--adapter-path` argv strings.

## What each door owns

| Concern | `callMLX` (grandfathered) | `callLLM` (new) |
|---|---|---|
| Backend | Python subprocess (`mlx_lm` CLI) | node-mlx in-process (`@frost-beta/mlx`) |
| Signature | `(cmdType, payload)` | `(params)` with `params.op` |
| Payload keys | kebab-case | camelCase |
| Return | `Promise<string>` (raw stdout) | `Promise<opResult>` (per-op object) |
| Session cache | none (fresh spawn per call) | keyed on `modelDir::adapterPath`, module-level Map in `mlx/llm_dispatch.coffee` |
| Adapter-path generate | supported (Python does the work) | supported (in-process `applyLoRA` + `loadAdapter` inside `createSession`) |
| Unknown op / cmdType | Python CLI errors upstream | throws `unknown op '...'` at dispatch |
| Debug flag | `debug_mlx` step param | `debug_llm` step param |

## Files (Stage 0)

- **New:** `mlx/llm_dispatch.coffee` — dispatcher module, exports `{dispatch, getSession}`. Owns the session cache.
- **New:** `test.sh` + `test/stage0_smoke.coffee` — plumbing smoke.
- **Edited:** `pipeline_runner.coffee` — reverted `memo.callMLX` to pure Python spawn (removed the yesterday-added bridge try/catch); added `memo.callLLM = async (params, dbug) -> …`; wrapped both on the ledger surface at the S constructor.
- **Deprecated (renamed, not deleted):** `mlx/mlx_lm_bridge.coffee.deprecated`, `validation/mlx_bridge_smoke.coffee.deprecated`. Kept in-tree as historical reference; not required by any code path.
- **Untouched (still correct as-is):** `mlx/session_api.coffee` (yesterday's `adapterPath` support is what `callLLM({op:'generate'})` uses), `mlx/lora/{train,wrap,fuse,lora_layer}.coffee`, all 9 Phase 2 v2 caller scripts.

## What the caller code looks like

```coffee
# Grandfathered — unchanged behavior
raw = await S.callMLX 'generate', {model: MODEL, prompt: 'hi'}
# spawns `python -m mlx_lm generate --model … --prompt hi`, returns stdout string

# New door — in-process, native object return
result = await S.callLLM {op: 'generate', modelDir: MODEL, prompt: 'hi', maxTokens: 6}
result.text          # string
result.tokPerSec     # number
result.promptTokens  # number

result = await S.callLLM
  op: 'train'
  modelDir: MODEL_DIR
  dataDir: DATA_DIR
  adapterPath: ADAPTER_DIR
  iters: 20
  batchSize: 1
  maxSeqLength: 1024
  learningRate: 5e-5
result.trained       # true if training ran
result.testLoss      # float if test mode

result = await S.callLLM
  op: 'fuse'
  baseModelDir: BASE
  adapterDir: ADAPTER
  targetModelDir: OUT
result.merged        # count of weights merged
result.outputBytes   # size on disk
```

## Op → module map

| `params.op` | Backing module | Signature |
|---|---|---|
| `'train'`    | `mlx/lora/train.coffee::trainLoRA(opts)`                       | opts already camelCase; `{op}` stripped, rest passed through |
| `'generate'` | `mlx/session_api.coffee::createSession(...).generate(prompt, gopts)` | session cached by `(modelDir, adapterPath)` |
| `'fuse'`     | `mlx/lora/fuse.coffee::fuseAdapter(base, adapter, target, opts)`     | positional args destructured from params |

Adding a new op means adding a `when` case in `dispatch()` and a small handler function in `mlx/llm_dispatch.coffee`. No changes needed elsewhere.

## Anti-standards (Stage 0)

- **Do not add a Python fallback to `callLLM`.** If the JS path can't serve, throw. A "fall through to callMLX" would rebuild the exact confusion Stage 0 is fixing.
- **Do not add op-selector logic to `callMLX`.** It stays a pure argv builder + `spawnSync`. If you find yourself extending `callMLX`, you're on the wrong door.
- **Do not use kebab-case keys on `callLLM`.** camelCase discipline is what makes the two doors visually distinct at every call site. `{modelDir, adapterPath}` on `callLLM`; `{'model', 'adapter-path'}` on `callMLX`.
- **Do not re-export `mlx_lm_bridge`.** The `.deprecated` rename is deliberate. If a caller ends up needing bridge behavior, that's a new decision, not a resurrection.
- **Do not conflate `debug_mlx` and `debug_llm`.** Two flags, two doors. A run debugging LLM-side gradient issues doesn't want the Python spawn also printing full argv, and vice versa.

## Validation

`test.sh` (see `test/stage0_smoke.coffee`) covers six assertions:
1. Unknown op → throws with 'unknown op' in message
2. Missing required key (`generate` w/o `modelDir`) → throws with correct message
3. Fuse w/ bogus paths → hits `mlx/lora/fuse.coffee` (message contains 'base config missing'), not a Python spawn error
4. `require('./mlx/lora/train')` yields a `trainLoRA` function (module loads, no import cycles)
5. Real Qwen3-4B generate returns `{text: '…Paris…', tokPerSec: <number>, …}` — native object shape, not stdout string
6. Source-level check that `callMLX`'s method body does NOT import `llm_dispatch` or `mlx_lm_bridge` and still calls `spawnSync` — grandfathered path is genuinely untouched

Assertion 5 is skipped if the Qwen3-4B model isn't at `pipes/Qwen_Qwen3-4B-Instruct-2507/build/model4/`. The other five run standalone.

The smoke does NOT run actual training (that's yesterday's 5-iter check, 9.9s — too heavy for a plumbing smoke, and it doesn't add coverage over "module loads").

## Not done in Stage 0

- **`@jahbini/pipeline` node_module install.** That's Stage 1. Stage 0 sets up mlxCoffee to have the two-door API in place so Stage 1 can start swapping runner internals without also having to invent the API.
- **Migration of any existing caller from `callMLX` to `callLLM`.** All 9 Phase 2 v2 caller scripts stay on `callMLX` (Python). A caller that wants JS behavior is a new sibling step, written when a real need arises.
- **UI hookup, layered overrides, pipe-centric CWD.** Also Stage 1.
- **Delete of `.deprecated` files.** Left in-tree until the migration is done and Mr. Hinds is confident nothing references them.

## Open question for post-Stage-0

- **Which caller should be first to move from `callMLX` to `callLLM`?** Natural candidate: `scripts/train_markdown/lora_train.coffee` (currently uses `callMLX 'lora'`, which spawns Python). A sibling `scripts/train_markdown/lora_train_llm.coffee` calling `callLLM({op:'train', …})` would be the first end-to-end proof that both doors work in a real recipe. Deferred until Stage 1 makes the pipe/runner layout right for such a comparison.
