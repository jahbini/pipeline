# LLM-door port plan — folding mlxCoffee's `callLLM` into @jahbini/pipeline

_2026-07-22._ Source of truth: `~/development/mlxCoffee/` (55 smoke
assertions green as of 2026-07-21). Five-commit port. Decision docs
already landed in `GPT/stage0_callLLM.md`, `GPT/stage1_layout.md`,
`GPT/integration{1,2,3}_*.md`. Smoke tests already ported into
`test/llm/`. This file covers the four commits that require Mr.
Hinds's hands.

---

## 16:00 UTC — Commit 1: copy `mlx/*` verbatim

**Context**: mlxCoffee's `mlx/` tree is the in-process LLM backend. Same relative paths in this repo.

**Recommendation**: `cp -R` these eight files (no renames):

```
~/development/mlxCoffee/mlx/llm_dispatch.coffee       →  mlx/llm_dispatch.coffee
~/development/mlxCoffee/mlx/session_api.coffee        →  mlx/session_api.coffee
~/development/mlxCoffee/mlx/quantize.coffee           →  mlx/quantize.coffee
~/development/mlxCoffee/mlx/models/qwen3.coffee       →  mlx/models/qwen3.coffee
~/development/mlxCoffee/mlx/lora/train.coffee         →  mlx/lora/train.coffee
~/development/mlxCoffee/mlx/lora/wrap.coffee          →  mlx/lora/wrap.coffee
~/development/mlxCoffee/mlx/lora/lora_layer.coffee    →  mlx/lora/lora_layer.coffee
~/development/mlxCoffee/mlx/lora/fuse.coffee          →  mlx/lora/fuse.coffee
```

The top-of-file shims in `session_api.coffee` and `lora/train.coffee`
(`mx.metal.clearCache ?= mx.clearCache` etc.) must be preserved
verbatim; they bridge `@frost-beta/llm@0.4.1` against
`@frost-beta/mlx@0.4.0`.

Do NOT copy `mlx/mlx_lm_bridge.coffee.deprecated`. Retire, not port.

**Why**: Direct copy avoids drift. The mlxCoffee tree is the tested
source; five green smoke stages depend on it as-is.

**How to verify**: `find mlx -type f -name '*.coffee' | wc -l` → 8.
Then `coffee -e "require('./mlx/llm_dispatch')"` should exit clean
(module loads, no import cycles) once deps are installed (Commit 3).

---

## 16:05 UTC — Commit 2: `pipeline_runner.coffee` two-hunk patch

**Context**: Add `callLLM` alongside `callMLX` at both the memo and the
StepLedger surface. `callMLX` is not touched. Grep-verify at commit
time: `callMLX`'s method body must still call `spawnSync` and must NOT
`require('./mlx/llm_dispatch')`.

**Recommendation**:

**Hunk 1 — memo entry.** Insert immediately after `callMLX` at line
783 (i.e. after the `res.stdout` line, before the `###` block that
opens §8):

```coffee
  callLLM: (params, dbug = false) ->
    console.error "LLM(in-process) #{params.op}", params if dbug
    {dispatch} = require './mlx/llm_dispatch'
    await dispatch(params)
```

**Hunk 2 — StepLedger surface.** Insert immediately after the
`callMLX` block at line 1438 (before `ledger` on line 1440):

```coffee
    callLLM: (params, dbug) ->
      llmDebug = if arguments.length >= 2 then dbug else @param('debug_llm', false)
      memo.callLLM params, llmDebug
```

Note: unlike `callMLX`'s surface wrapper, `callLLM` does NOT run
payload through `mergeMlxPayload` — the `llm:` block convention has the
step script merging its own `llm:` params (see the ported step
scripts). Keeping the wrapper thin preserves the anti-standard that
`callLLM` is a straight pass-through, not a payload-mangling door.

**Why**: Mirrors `callMLX`'s existing wiring pattern exactly (memo
entry + surface wrapper). The `require` is inside the method body, not
at file top, so cold-load cost stays with `callMLX`-only pipelines.

**How to verify**:
- `grep -n 'callLLM' pipeline_runner.coffee` shows both hunks.
- `grep -n 'spawnSync\|dispatch\|canHandleInProcess' pipeline_runner.coffee` — `callMLX`'s body still contains `spawnSync`, does not contain `dispatch(` or `canHandleInProcess`.
- After Commit 1+3, `test/stage0_smoke.coffee` (already ported) passes all six assertions.

---

## 16:10 UTC — Commit 3: `package.json` deps

**Context**: Both `@frost-beta` packages are required (in-process
generate needs `session_api` even if a consumer only uses train). ~200
MB of prebuilt binaries — accepted.

**Recommendation**: add to `dependencies`:

```json
"@frost-beta/llm": "^0.4.1",
"@frost-beta/mlx": "^0.4.0"
```

Full resulting block:

```json
"dependencies": {
  "@frost-beta/llm": "^0.4.1",
  "@frost-beta/mlx": "^0.4.0",
  "@modelcontextprotocol/sdk": "^1.29.0",
  "coffeescript": "^2.7.0",
  "js-yaml": "^4.1.1"
}
```

Then `npm install` (or `pnpm install`).

**Why**: `mlx/session_api.coffee` requires `@frost-beta/llm` for the
model classes and `@frost-beta/mlx` for the tensor ops. Both are
transitively required by `mlx/llm_dispatch.coffee`.

**How to verify**: `node -e "require('@frost-beta/llm'); require('@frost-beta/mlx')"` exits 0.

---

## 16:15 UTC — Commit 4: three recipes + three step scripts

**Context**: The `llm:` block convention parallels existing `mlx:`
blocks. Step script hardcodes the `op` selector; recipe/override
supplies data only.

**Recommendation**: `cp` these six files, then apply the ONE deviation
noted below for `chat_llm.yaml`:

```
~/development/mlxCoffee/config/chat_llm.yaml               →  config/chat_llm.yaml
~/development/mlxCoffee/config/train_llm.yaml              →  config/train_llm.yaml
~/development/mlxCoffee/config/fuse_llm.yaml               →  config/fuse_llm.yaml
~/development/mlxCoffee/scripts/chat_llm/chat_llm.coffee   →  scripts/chat_llm/chat_llm.coffee
~/development/mlxCoffee/scripts/train_llm/run_lora_train_llm.coffee  →  scripts/train_llm/run_lora_train_llm.coffee
~/development/mlxCoffee/scripts/fuse_llm/fuse_llm.coffee   →  scripts/fuse_llm/fuse_llm.coffee
```

**Deviation for `config/chat_llm.yaml`**: this repo's
`pipeline_runner.coffee` implements `stripUiDirectives` (at line 371)
with `UI_textarea` handling. Change `prompt_text` in the copied file
from:

```yaml
  prompt_text: ""
```

to:

```yaml
  prompt_text: [ UI_textarea, "" ]
```

This matches the pre-existing pattern in `config/prompt_ite.yaml`
(`prompt_text: [ UI_textarea, "" ]`) and lets the UI form-renderer
surface the field. The step script (`scripts/chat_llm/chat_llm.coffee`)
already does `L.param('prompt_text', '')` — `stripUiDirectives` runs
during experiment materialization, so by the time the step reads the
param it's a plain string. No script edit needed.

No changes to `config/train_llm.yaml`, `config/fuse_llm.yaml`, or any
of the three scripts.

**Why**: The `llm:` block + hardcoded-`op` convention is the whole
point of the ported integration docs. The chat_llm deviation harmonizes
with this repo's existing UI-directive pattern without changing the
recipe's shape.

**How to verify**:
- After all four commits + `npm install`: `bash test.sh` runs the five
  smoke stages. Stage 0 (~5s) and Stage 1 (<1s) run standalone. Stage
  2 (~5s), Stage 3 (~13s), Stage 4 (~45s) require
  `pipes/<pipe>/build/model4/` (an mlx-lm-format Qwen3-4B) and skip
  cleanly if absent.
- Check `pipes/<pipe>/experiment.yaml` after Stage 2: `chat_llm` block
  should show `prompt_text: "..."` (plain string, directive stripped)
  and `llm.maxTokens: 128`.

---

## 16:20 UTC — Landing order + rollback

**Recommendation**: land in the numbered order above. Each commit is
independently green (given the previous ones):

1. Commit 1 alone: `mlx/*` files exist but nothing imports them — no
   effect on existing behavior.
2. Commit 1 + 2: runner has `callLLM` wired but no caller uses it yet.
   `test/stage0_smoke.coffee` becomes runnable; source-level assertions
   pass immediately.
3. Commit 1 + 2 + 3: deps installed; Stage 0 assertion 5 (real Qwen3-4B
   generate) can run if the model is present.
4. Commit 1 + 2 + 3 + 4: three new recipes selectable via
   `pipeline: chat_llm|train_llm|fuse_llm` in `control_override.yaml`.

**Rollback**: any single commit reverts cleanly. The `mlx/` tree is a
new top-level dir (no conflicts). The runner diff is 20 lines in two
localized hunks. `package.json` adds two lines. The recipes and scripts
are new files under new subdirectories.

**After landing**: cut a release. mlxCoffee's planned Stage 2 becomes
`require '@jahbini/pipeline/pipeline_runner'` and inherits the LLM door
already present — mlxCoffee stops carrying the code twice.

---

## 16:22 UTC — Smoke tests landed (companion to Commits 1–4)

**Context**: Test surface is mine. Smoke tests ported into
`test/llm/`.

**What's landed** (already on disk, not requiring your hands):
- `test/llm/stage0_smoke.coffee` — callLLM dispatch, callMLX purity,
  6 assertions.
- `test/llm/stage1_source_smoke.coffee` — adapted for this repo.
  Original mlxCoffee stage 1 was a port checklist for its runner
  aligning to this repo; I dropped 1a (root debris), 1b (bundled pipe
  layout), 1d (dormant install — moot since we ARE the package). Kept
  1c (runner source-level presence of `resolveOverrideLayers`,
  `createExperimentObject`'s 3-arg form, `writeUiRun` + call sites,
  `state/ui-run.json`, `LOGDIR`/`HH_MM` env-var reads) as a regression
  net. Added one new assertion: `callLLM` presence on the runner
  (guards against partial revert of Commit 2).
- `test/llm/stage2_chat_smoke.coffee` — verbatim from mlxCoffee, path
  refs re-rooted from `test/` to `test/llm/`.
- `test/llm/stage3_train_smoke.coffee` — verbatim, same path fix.
- `test/llm/stage4_fuse_smoke.coffee` — verbatim, same path fix.
- `test/llm/smoke.sh` — driver, chmod +x. Runs all five sequentially,
  logs to `test/llm/stage{0,1,2,3,4}_smoke.log`.

**Not landed** (deliberate): the repo-root `test.sh` is untouched.
That file is 539 lines of live-probe infrastructure for `eval_ite`
etc.; opt-in `bash test/llm/smoke.sh` keeps LLM-door verification
separate until you decide how (or whether) to fold it into the top
level.

**How to verify**:
- Stage 0 + Stage 1 (source smoke) will run standalone once Commits 1
  and 2 land — no model/deps needed for their source-level checks;
  Stage 0's assertion 5 (real generate) needs Commit 3 (deps) + the
  Qwen3-4B model.
- Stages 2–4 need `pipes/Qwen_Qwen3-4B-Instruct-2507/` with a full
  mlx-lm-format Qwen3-4B at `build/model4/`. If absent, the tests skip
  cleanly at their pre-check.
- Full run: `bash test/llm/smoke.sh`. Wall times (from mlxCoffee):
  ~5s + <1s + ~5s + ~13s + ~45s ≈ 70s.

---

## 16:25 UTC — Anti-standards import (for `GPT/README.md`)

**Recommendation**: after the recipes land, add these bullets to
`GPT/README.md`'s HARD RULE section (they parallel the existing
`config/*.yaml` no-tuning rule):

- Do not add a Python fallback to `callLLM`. Unknown op throws; no
  `canHandleInProcess`-style gate.
- Do not put `op` in an `llm:` block. Step script owns the op selector.
- Do not use kebab-case keys in `llm:` blocks. camelCase is the
  two-door signal at every call site.
- Do not add `iters > 20` to `config/train_llm.yaml`. Tuning numbers
  go in `pipes/<pipe>/override/train_llm.yaml`.
- Do not fuse into the live base model dir. `target_model_dir` must be
  distinct from `quantized_model_dir`.

**Why**: These are the load-bearing invariants from the three
integration docs. Elevating them to `GPT/README.md` makes them
discoverable at the project-wide level rather than only inside the
integration records.

**How to verify**: N/A — this is documentation.
