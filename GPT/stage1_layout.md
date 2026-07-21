> **Provenance note.** Authored 2026-07-22 in `~/development/mlxCoffee/GPT/`
> as design record for mlxCoffee aligning its on-disk layout to
> `@jahbini/pipeline` (this repo, the exemplar). Ported verbatim on
> 2026-07-22. "This repo" in the original = mlxCoffee. In this codebase
> the pipe-centric CWD, layered overrides, and `state/ui-run.json`
> bookkeeping are already the canonical behavior — this document
> preserves the history and the exact behaviors mlxCoffee copied.

# Stage 1 — layout + runner conventions to match `~/pipeline`

_2026-07-22._ Follows [`stage0_callLLM.md`](stage0_callLLM.md).

## Decision

Bring mlxCoffee's on-disk layout and its `pipeline_runner.coffee`'s override + run-metadata behavior into alignment with the `@jahbini/pipeline` reference runner, so that a Stage 2 swap (`require '@jahbini/pipeline/pipeline_runner'`) becomes a plumbing change rather than a design change.

`@jahbini/pipeline@0.2.0` is installed as a dependency this stage but **remains dormant** — nothing in mlxCoffee `require`s it. It sits in `node_modules/` as evidence-of-parity and as the exemplar the Stage 1c edits were copied from.

Landed in three sub-stages:

## 1a — root debris cleanup

Removed at repo root (all auto-created by prior runs of `pipeline_runner.coffee` when it was invoked with the wrong CWD — the mlxCoffee root instead of `pipes/<pipe>/`):
- `env/`, `params/`, `state/`, `experiment.yaml`

Left in place (not mine or not runner byproducts): `test.log`, `test5.log`, `tokenizer/`, `Full-Provenance.md`, `REPO_MAP.md`, everything else previously tracked.

Discipline going forward: **the runner is only ever invoked with `cwd = pipes/<pipe>/`**. Any file the runner writes lands under that pipe, not at the repo root.

## 1b — pipe layout to writeStory canon

Under `pipes/Qwen_Qwen3-4B-Instruct-2507/`, added the three markers that were missing vs `~/writeStory/pipes/Qwen_Qwen3-4B-Instruct-2507/`:
- `logs/` — where per-run `pipe_HH_MM.log` files land. The runner does NOT create these directly (the UI does, by opening file descriptors and passing them to the spawned runner via `stdio`); the directory just needs to exist.
- `override/` — recipe-scoped overrides (`override/<recipe>.yaml`). Higher precedence than legacy `override.yaml`.
- `control_override.yaml` — UI-materialized run control. Highest precedence.

`runtime.sqlite` skipped — no SQLite-consuming steps in mlxCoffee yet. Will land when needed.

## 1c — runner: layered overrides + `state/ui-run.json`

Two edits to `pipeline_runner.coffee`, both copied nearly verbatim from `~/pipeline/pipeline_runner.coffee`.

### Layered override resolver

New helper `resolveOverrideLayers(pipelineName)` returns every override file that exists under CWD in ascending precedence:

```coffee
resolveOverrideLayers = (pipelineName) ->
  layers = []
  legacyPath = path.join CWD, 'override.yaml'
  layers.push legacyPath if fs.existsSync legacyPath
  name = String(pipelineName ? '').trim()
  if name.length
    recipeOverridePath = path.join CWD, 'override', "#{name}.yaml"
    layers.push recipeOverridePath if fs.existsSync recipeOverridePath
  layers
```

`createExperimentObject` now takes `(configPath, overridePaths, controlOverridePath = null)` — `overridePaths` may be a single path (back-compat) or an array (canon), and `controlOverridePath` is deep-merged last (highest precedence).

**Precedence** (low → high):
1. `config/<recipe>.yaml` (recipe baseline)
2. `override.yaml` (legacy human layer)
3. `override/<recipe>.yaml` (recipe-scoped human layer; UI's write surface)
4. `control_override.yaml` (UI-owned run control)

`main()` at what was previously line 686 now resolves `pipelineName` from `control_override.yaml` first, then falls back to legacy `override.yaml`. This means a run whose UI has staged a different pipeline in `control_override.yaml` will honor that even if `override.yaml` names a different one.

**Backward compatible**: today's pipe (only `override.yaml` present) yields `resolveOverrideLayers → [override.yaml]`, which `createExperimentObject` deep-merges as before. Identical behavior for the one-file case.

**stripUiDirectives skipped**: `~/pipeline` calls this on the merged config to remove UI form-renderer directives (`[UI_dropdown, …]`) before returning. mlxCoffee has zero such directives today (`grep -R "UI_dropdown\|UI_checkbox\|UI_textarea" config/` → nothing). Will add when we wire a UI.

### `state/ui-run.json` bookkeeping

Added `writeUiRun(patch)` helper that reads-modify-writes `<CWD>/state/ui-run.json` with an updated `updated_at` timestamp. Called at:
- **Startup** — after `pipelineName` is resolved: `status: 'running'`, `pipeline`, `pid`, `cwd`, `exec`, `hh_mm`, `logdir`, `started_at`.
- **Successful completion** — `status: 'done'`, `finished_at`.
- **Failed completion** — `status: 'failed'`, `finished_at`.
- **Pipeline shutdown** (memo-triggered) — `status: 'shutdown'`, `finished_at`, `shutdown: {by, reason}`.
- **SIGTERM** — `status: 'signaled'`, `finished_at`, `signal: 'SIGTERM'` (best-effort, wrapped in `try` since signal handlers can be re-entered).
- **SIGINT** — same shape, `signal: 'SIGINT'`.

**Fields `hh_mm` and `logdir` come from `process.env.HH_MM` and `process.env.LOGDIR`** — set by the UI when it launches the runner via `spawn(..., {env: {..., HH_MM, LOGDIR}})`. On CLI runs both are `null`, matching `~/pipeline`'s behavior for the same case.

**Why write ui-run.json on CLI runs too** (`patch: {status: 'running', ...}` even without env vars): the file is the human-readable record of "when did this pipe last run, was it successful, what pid was it". Cheap; enables Stage 2 UI to see run history immediately once wired; useful for debugging without any UI.

## 1d — `@jahbini/pipeline` dormant install

`package.json`: `"@jahbini/pipeline": "github:jahbini/pipeline"` (installed as `@jahbini/pipeline@0.2.0`).

Verified dormant by source-level check in `test/stage1_smoke.coffee`: `pipeline_runner.coffee` must not contain `require '@jahbini/pipeline'`. If it ever does, we're in Stage 2, not Stage 1.

## Files touched

- **Edited:** `pipeline_runner.coffee` — added `resolveOverrideLayers`, extended `createExperimentObject` arity, rewrote pipeline-name lookup in `main()`, added `writeUiRun` helper with 5 call sites (startup + 4 exit paths).
- **New:** `pipes/Qwen_Qwen3-4B-Instruct-2507/logs/` (dir), `pipes/Qwen_Qwen3-4B-Instruct-2507/override/` (dir), `pipes/Qwen_Qwen3-4B-Instruct-2507/control_override.yaml` (empty file).
- **New:** `test/stage1_smoke.coffee` — source-level Stage 1 assertions.
- **Edited:** `test.sh` — runs both stage0 and stage1 smokes.
- **New:** this file, `GPT/stage1_layout.md`.
- **Edited:** `GPT/README.md` — index entry.
- **Deleted at repo root:** `env/`, `params/`, `state/`, `experiment.yaml`.

## Not done in Stage 1

- **Consuming any `@jahbini/pipeline` code.** Dormant install only.
- **Log file creation by the runner.** UI is responsible for opening `logs/pipe_HH_MM.log` fds and passing to the spawned runner. On CLI runs, stdout goes to shell; no auto-log file.
- **`ui_server.coffee` from `@jahbini/pipeline`.** Not launched, not required.
- **`stripUiDirectives`.** No UI directives in mlxCoffee's recipes yet.
- **SQLite `runtime.sqlite`.** No SQLite-consuming steps yet.
- **Migrating existing recipes to layered overrides.** Old `train_markdown.yaml`, `full.yaml`, etc. can move `pipeline: X` from legacy `override.yaml` to per-recipe `override/X.yaml` at leisure — no rush; both paths work.
- **Recipe conversion to `_ite` shape.** That's a domain-orbit change, not a framework-orbit one. Deferred.

## Anti-standards (Stage 1)

- **Do not run `pipeline_runner.coffee` with `cwd = repo root`.** It'll auto-create `env/`, `params/`, `state/` at the wrong level, which is exactly the mess Stage 1a cleaned up. The UI enforces this by spawning with `cwd: pipeDir`. CLI runs should `cd pipes/<pipe>/` first, or use `env CWD=... pipeline_runner.coffee` — but the current runner uses `process.cwd()`, so `cd` is the reliable path.
- **Do not migrate `override.yaml` values into `override/<recipe>.yaml` and then delete the legacy file.** Both are read on every run. The mistake `~/pipeline`'s design memo calls out — silently freezing legacy edits by migrating-then-ignoring — was avoided by keeping the read-both-merge-both discipline.
- **Do not add `require '@jahbini/pipeline/...'` in Stage 1.** That's Stage 2. The smoke will fail loudly if it happens now.
- **Do not have the runner write to `logs/` directly.** UI owns log file creation via `stdio` fds. If a CLI wrapper wants to redirect stdout to a log, that's the wrapper's job, not the runner's.

## Verification

`test.sh` runs `test/stage0_smoke.coffee` + `test/stage1_smoke.coffee`. Stage 1 smoke checks:
- **1a**: no `env/params/state/experiment.yaml` at repo root
- **1b**: pipe has `logs/`, `override/`, `control_override.yaml`
- **1c**: source-level presence of `resolveOverrideLayers`, 3-arg `createExperimentObject`, `control_override.yaml` + `pipelineName` in main(), `writeUiRun` helper + ≥4 call sites, `state/ui-run.json` reference, `process.env.LOGDIR` + `process.env.HH_MM` reads
- **1d**: package.json declares `@jahbini/pipeline`; module installed; runner does NOT import it (dormancy)

Stage 0 assertions (all 6) run first as a regression check — the runner edits must not break `callLLM`/`callMLX`.

**Behavior test (out of Stage 1 scope, human runs when a real recipe is ready):**
1. Populate `pipes/<pipe>/override/<recipe>.yaml` with something that overrides a value in legacy `override.yaml`.
2. Run the pipeline.
3. Assert `pipes/<pipe>/experiment.yaml` shows the recipe-scoped value winning (deep-merge working correctly).
4. Assert `pipes/<pipe>/state/ui-run.json` has `status: 'done'`, `pipeline`, `pid`, correct timestamps.

## Path to Stage 2

Stage 2 = replace mlxCoffee's `pipeline_runner.coffee` with `require '@jahbini/pipeline/pipeline_runner'` (or the equivalent module import shape). Because Stage 1 aligned the on-disk layout, the override resolver, and the run-metadata bookkeeping with `~/pipeline`'s exact conventions, Stage 2 should be a small edit: the entry point wires `L.callLLM` (still owned by mlxCoffee) onto the imported runner's Memo, keeps `mlx/llm_dispatch.coffee` as the local in-process backend, and everything else is inherited from the module.

The one likely wrinkle in Stage 2: `@jahbini/pipeline`'s runner does not know about `callLLM` (only `callMLX`). Either (a) subclass its Memo to add `callLLM`, or (b) upstream `callLLM` to `@jahbini/pipeline` as a first-class door. Decision deferred to when Stage 2 is scoped.
