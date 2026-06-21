# pipeline_runner.coffee — framework-orbit contract

Working memory for the runner core. Framework orbit: changes here are
branch- and project-portable. See `pipeline_architecture.md` for the
universal-substrate framing and `GPT/README.md` for repo-wide conventions.

## EXEC vs CWD (the load-bearing seam)

- `EXEC` = the runner's home. When installed as a dependency this is the
  package dir, `node_modules/@jahbini/pipeline/`. Ships `pipeline_runner.coffee`,
  `config/`, `scripts/`, `meta/`, `requirements.txt`.
- `CWD` = the consumer project the pipeline runs in. Owns `state/`,
  `params/`, `out/`, `experiment.yaml`, `override*.yaml`, `.venv/`, and the
  project's own `scripts/`.
- The pipeline mostly lives in `node_modules`; the consumer's top-level
  `package.json` is responsible for initializing the project dir (incl. the
  venv). `EXEC` is overridable via the `EXEC` env var.

## Override resolution — layered, non-destructive

- `resolveOverrideLayers(pipelineName)` returns every override file that
  EXISTS, low→high precedence: legacy `<CWD>/override.yaml`, then
  recipe-scoped `<CWD>/override/<name>.yaml`. It copies and migrates nothing.
- `createExperimentObject(configPath, overridePaths, controlOverridePath)`
  deep-merges: recipe (`<EXEC>/config/<name>.yaml` + its `include:`) → each
  override layer in order → `control_override.yaml` (highest) → strips UI
  directives → writes `experiment.yaml`.
- Pitfall fixed (do not regress): the old `resolveOverridePath` migrated
  legacy `override.yaml` into `override/<name>.yaml` once and then only ever
  re-read the copy. That silently froze later `override.yaml` edits out of
  `experiment.yaml`. Edits to `override.yaml` must always re-merge.
- The UI (`ui_server.coffee` `readOverride`) owns `override/<recipe>.yaml` as
  its edit surface; recipe-scoped wins over legacy on conflicts. Do not make
  the runner write override files.

## Step script resolution — project-first, no fabrication

- `stepScriptCandidates(run)`: `[run]` if absolute (no `~` expansion), else
  the three tiers, deduped: `[<CWD>/scripts/<run>, <BASE>/scripts/<run>,
  <EXEC>/scripts/<run>]`. Tiers: CWD = per-pipe override/debug, BASE =
  project-shared, EXEC = runner-bundled. BASE coincides with CWD or EXEC in
  some layouts, hence the dedupe (monolith: BASE==EXEC → back to two
  candidates).
- `resolveStepScript(run)` returns the first candidate that EXISTS, or `null`.
  It never fabricates a path.
- recipe configs resolve via `resolveConfigPath(name)`: per-pipe
  `<CWD>/config/<name>.yaml` shadows project-shared `<BASE>/config/<name>.yaml`
  shadows bundled `<EXEC>/config/<name>.yaml`. The CWD tier was added in
  June 2026 with the `experiments-withqwen` convention (see
  `GPT/pipeline_architecture.md`) so a pipe can carry its own recipes.
  Used by the runner's `main()` and mirrored in `ui_server.coffee`
  (`BASE_ROOT` + its own `resolveConfigPath`) so the recipe viewer/selector
  sees per-pipe recipes too. Override-LAYER resolution
  (`resolveOverrideLayers`) is unchanged — still CWD-only.
- param values are run through `substituteBraces` at `L.param` /
  `getStepParam` read time: any `{BASE}`, `{EXEC}`, or `{CWD}` literal in a
  param string (or any string nested in an array/object) is replaced with
  the matching path constant. The merged `experiment.yaml` stays literal —
  substitution is what the step sees, not what the recipe says.
- `runStep` resolves at the point of use; if `null`, it fails the step
  directly: `step <n>: script not found for run '<run>' (looked: …)`. No
  fallback into the legacy spawn with a guessed path.
- `params/<step>.yaml` carries `run_resolved` (the resolved path, or `null`)
  so a human can read it alongside `state/<step>.json`.
- regression cover for the BASE tier: `test/base_tier.sh` +
  `test/base_tier_probe.coffee` (script CWD↠BASE↠EXEC shadowing, recipe
  BASE↠EXEC shadowing).

## No fallbacks, no prechecks (design standard)

Human directive, repo standard: do not fabricate defaults, guess paths, or
pre-validate data at startup to "help." If something is missing, let the
error happen WHERE it is needed and make the log point directly at the
failing code. Prefer removing a masking fallback over adding a precheck.

## Artifact access ledger — opt-in accountability for needs/makes

When `debug_s` is given as an ARRAY of artifact keys (anywhere in the
experiment: `run.debug_s` or any step's `debug_s`), every
`L.need / L.peek / L.make / L.saveThis` call touching one of those keys, in
any step, appends a JSONL line to `logs/<LOGDIR>.artifacts.jsonl`. The
scalar forms `debug_s: true|false` keep their prior per-step verbose-console
meaning — only the array form opens the ledger.

Use this to find rogue writers (e.g. "valid_rows gets corrupted — who else
is writing it?"):
```yaml
# in override/<recipe>.yaml
run:
  debug_s: [valid_rows]
```
Each record carries `{ts, step, op, key, value_kind, value_size,
caller_file, caller_line, ...}`. `op` is one of `need|peek|make|saveThis`.
For `make`, `duplicate` and `make_count` flag a step calling `L.make` on
the same key more than once (silent overwrite). For `saveThis`,
`declared` is false when the compat shim writes a traced artifact key
from a step that does not declare it in `makes:` — the single most common
"second writer" bug.

**Smoking gun example — June 2026 valid_rows bug.** Setting
`run.debug_s: [valid_rows, train_rows, test_rows, selected_story_ids]`
on writediary's `lora_ite` revealed `wireInputsForStep` (the pre-step
"wire each need into the memo" loop) was concurrently interleaving with
`collectOutputsForStep` and writing each need's *previous iteration's*
`v` (the `selected_story_ids` size-4 array) into `train_rows`,
`valid_rows`, `test_rows` — silently corrupting all three artifacts
right before `run_lora_train_ite` read them. Stack capture + a probe
proved the loop variables `k` and `v` desync across `await` boundaries
when other Promise chains run between iterations. **Resolution**:
`wireInputsForStep` now only `await resolveArtifact(k)` to block on the
producer's notifier and does NOT re-save the value to the memo — the
producer's own `L.make` already wrote it there, and the re-save was the
sole source of the race. Do not add back the `M.saveThis k, v` line.

Two recipe-level checks fire at startup regardless of the array form:
- **multi-maker**: an artifact declared in `makes:` by more than one step
  (`[artifact-warn] artifact 'X' is declared in makes: by N steps: ...`)
- **duplicate-make** at runtime: a step calling `L.make` on the same key
  twice in one run (run-wide via `artifactMakeCount`).
Both write to stderr; the multi-maker scan also lands in the ledger's
startup record when it's open.

## state/ ↔ params/ correspondence

- `state/step-<name>.json` records what happened; `params/<step>.yaml` records
  the step's resolved inputs (incl. `run_resolved`). A human diagnoses by
  reading both.
- Crash-resume is intact and is NOT a precheck: a step restored as `done` is
  skipped (keyed by step name, consulted only at startup). Changing a step's
  `run:` does not auto-invalidate its state — by design. The clue lives in
  `params/<step>.yaml` (wrong/`null` `run_resolved`); the human clears that
  step's state file or edits the override.
- `./pipeline.json` (top-level in CWD) is the whole-pipeline death record. A
  non-empty one halts the next launch with the PRIOR failure's reason until
  removed (UI "Erase pipeline.json", or `rm ./pipeline.json`). It is written
  AFTER `experiment.yaml`, so a regenerated experiment can look correct while
  the run still halts on a stale death record.

## Python / MLX env — validate, never fix

- `validatePythonEnvironment(CWD)` (run first in `main()`) resolves the venv
  python via `resolvePython` and checks `mlx`, `mlx-lm`, `mlx-metal` against
  the `==` pins in `<EXEC>/requirements.txt`.
- `resolvePython` candidate order: `<CWD>/.venv` → `<BASE>/.venv` →
  `<EXEC>/.venv` (each `bin/python` then `bin/python3`; dupes collapsed). The
  error names every path tried, in order.
- `BASE` is the project root: if `EXEC` sits inside a `node_modules/`, BASE is
  the dir containing that `node_modules`; otherwise (monolith layout) BASE ==
  EXEC. **This is the load-bearing candidate**: when consumed as an npm package
  `EXEC` is `node_modules/@jahbini/pipeline`, which npm WIPES on every install,
  so a durable venv cannot live in EXEC (nor in CWD, a transient pipe dir). The
  project keeps one `./.venv` at BASE with nothing venv-related in node_modules.
- `requirements.txt` is read from EXEC (the package). The runner only ERRORS on
  a missing/mismatched venv with a clean log; it does NOT create or repair it.
  Building the venv from `requirements.txt` is the upper-level installer's job
  (pipeline-demo / pipeline-pipes). Do not add remediation commands or auto-fix
  here.
- regression cover: `test/python_base.sh` + `test/python_base_probe.coffee`
  prove the BASE venv resolves when neither CWD nor EXEC has one.

## Testing without a venv

`main()` runs only under `require.main is module`; the merge/resolution
internals are exported, so a harness can `require` the runner and exercise
`resolveOverrideLayers` / `createExperimentObject` / `resolveStepScript` /
`stepScriptCandidates` without tripping the Python gate. See `test/test.sh`
+ `test/merge_probe.coffee` (gitignored scratch).
