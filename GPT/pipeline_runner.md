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

## Tools — `S.tools.<name>.<entrypoint>` (design standard)

Shared utilities live in `tools/<name>.coffee` and are reached only via
`S.tools.<name>.<entrypoint>(args...)`. The runner resolves `<name>` with
the same BASE↠EXEC↠CWD shadowing it uses for step scripts: a per-pipe
`{CWD}/tools/<name>.coffee` wins over an experiment override over the
repo-level over the pipeline-bundled default. Resolved path lands in
`params/<step>.yaml` as `tools_resolved.<name>`.

Hard rules: a tool holds no state, takes no runner-injected objects,
cannot `L.need`/`L.make`/`L.callMLX`, is never a recipe step. Tools may
do filesystem I/O — that is not state, the tool remembers nothing
between calls. See `GPT/CONVENTIONS.md` § "Tools: shared utilities
behind `S.tools`" for the canonical rule and the `fs`-stinginess
corollary.

## Step scripts are location-anonymous (design standard)

A step script cannot know where on disk it executes from. No path-relative
`require`, no `__dirname`-relative reads, no hardcoded sibling-directory
references. The runner is free to load step scripts from anywhere — the
current `scripts/<category>/<step>.coffee` layout is incidental.

The legal surface is the `S` ledger, request keys dispatched by the meta
layer, Node built-ins, and packages resolvable by name. Anything else
needed by more than one step belongs in the runner (`S`-exposed) or the
meta layer (request-key-exposed). See `GPT/CONVENTIONS.md` § "Step
scripts are location-anonymous" for the canonical rule and remediation
status of known violations.

## No fallbacks, no prechecks (design standard)

Human directive, repo standard: do not fabricate defaults, guess paths, or
pre-validate data at startup to "help." If something is missing, let the
error happen WHERE it is needed and make the log point directly at the
failing code. Prefer removing a masking fallback over adding a precheck.

## Artifact resolution — `source:` vs `target:` vs `value:`

The recipe's `artifacts:` block declares one of three shapes per key:

- **`value: <literal>`** — the artifact's value is the literal. `resolveArtifact`
  returns it immediately. No meta interaction.
- **`target: <path>`** — the artifact is produced by some step's `L.make` and
  later persisted to the named file via the meta layer (jsonl/json/txt/etc.).
  `resolveArtifact` reads from the memo entry under the artifact name, then
  from the target as a fallback when the producer is already `done`. The
  producer step's `L.make` is the publish point.
- **`source: <path>`** — the artifact's value lives on disk **before any step
  runs**. There is no producer; `resolveArtifact` reads via the meta layer
  using the source path as the key (`txt.coffee` for `.md`/`.txt`, `json.coffee`
  for `.json`, etc.).

For source-only artifacts (`source:` set, `target:` absent), `resolveArtifact`
has a contract that's load-bearing and easy to get wrong:

1. **Synchronous read only.** Call `M.theLowdown(sourcePath)` to invoke the
   matching meta. If the meta returns a value, use it. Do **NOT** `await
   srcEntry.notifier` — no producer step exists to fire that notifier, and the
   await silently hangs forever.
2. **Publish under the artifact name.** Once read, `M.saveThis(artifactKey, val)`
   bridges the source value into the artifact-name slot so consumers that read
   `M.theLowdown(artifactKey)` directly see it (and so the artifact ledger
   records a `SAVE` event symmetric with target-backed artifacts). Idempotent:
   skip when the entry already has a defined value.
3. **Loud diagnostic on miss.** If the meta returns undefined (file missing,
   path wrong, no matching meta handler), `console.error` a structured block
   naming the artifact, the source path, and CWD — then return `undefined`.
   The consumer's `L.need` then raises its own clean
   `Missing required artifact '<key>'` with the step name. Two diagnostics for
   one fault: where the runner looked, and which step couldn't proceed.

History (June 2026): the June fix to `wireInputsForStep` correctly stopped
re-saving every need's resolved value back to its artifact-name key — that
re-save was masking a concurrent-iteration desync that corrupted
`train_rows`/`valid_rows`/`test_rows`. But that re-save had ALSO been
incidentally bridging source-only artifacts under their own name. With the
re-save gone and no explicit publish in `resolveArtifact`, source-only
artifacts silently hung any consumer's `await L.need`. The fix is the publish
above, not a revert of the wireInputsForStep change. Regression cover:
`run.debug_s: [<source-only-artifact-key>]` should record both a `NEED` event
(from the step) and a `SAVE` event (from `<resolveArtifact>` tagged as the
synthetic step name).

Consumer-side rule: a step that `L.need`s a source-only artifact does **not**
need a type-check prescreen on the result. If the source resolves, the meta
returned the right shape (string for txt, array for jsonl, object for json,
etc.); if it didn't, `resolveArtifact` returned undefined and `L.need` already
threw with the step name. A prescreen like `throw unless typeof raw is 'string'`
produces nothing the natural error wouldn't and violates the no-prechecks rule
above.

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

## Stable run IDs + the SQLite `runs` table

Every launch of `main()` mints a `runId = crypto.randomUUID()` after
the experiment is built. The UUID lives in two places:

- **`state/ui-run.json.id`** — the existing JSON-file surface the UI
  reads. Pre-existing readers tolerate the new field.
- **The `runs` table in `runtime.sqlite`** — populated via the
  `runRegister{<id>}.json` meta request at launch and updated via
  `runUpdate{<id>}.json` from `finalizeRunStatus(status, extra)` at
  every exit path (`shutdown`, `failed`, `done`). The runs table is
  initialized by `meta/sqlite.coffee`'s schema bootstrap, so projects
  without an existing DB get it on first runner boot.

Three read requests cover the agent surface (called from
`ui_server.coffee` via `/api/sqlite/<key>` and `/api/run/<id>`):

- `runById{<id>}.json` — single row + parsed `shutdown` blob.
- `runHistory.jsonl` — all rows, newest first.
- `changesSince{<arg>}.json` — see below.

If the sqlite meta is absent (a non-sqlite project), the runner logs
`[runs] could not register run …` to stderr and continues — the
filesystem `state/ui-run.json` surface still works without the DB.

## Change log + diff (the agent's evaluation surface)

The sqlite meta also bootstraps a `_change_log` table with INSERT/UPDATE/
DELETE triggers on every tracked table (`stories`, `story_parts`,
`expanded_story_parts`, `kag_entries`, `oracle_story_attempts`,
`lora_trained_stories`, `lora_story_usage`, `lora_training_runs`,
`lora_training_run_stories`, `runs`). Each trigger records
`(ts, table_name, op, row_id)`. Compound primary keys are stored as
`<col1>|<col2>`.

`changesSince{<arg>}.json` discriminates the arg shape — UUID resolves
through the `runs` table; ISO 8601 timestamps and integer `change_id`s
are used directly — and returns:

```json
{
  "anchor":        {"kind": "...", "value": "...", "resolved_ts": "...", "resolved_change_id": ...},
  "total_changes": N,
  "by_table":      {"<table>": {"count": N, "inserts": N, "updates": N, "deletes": N, "ids": [...]}}
}
```

`ui_server.coffee`'s `mergeChangeLogCounts` consumes this to replace the
heuristic-`null` entries in `buildRunEvaluation`'s `sqlite_rows_added`
block with precise change-log counts.

**Historical caveat.** Rows in tracked tables that predate the triggers
are not in `_change_log`; the diff is honest about its window. The
schema is idempotent — `CREATE TABLE IF NOT EXISTS` and `CREATE TRIGGER
IF NOT EXISTS` — so existing DBs gain the new surface without manual
migration on next boot.

The full agent contract built atop this is in
[`GPT/ui/agent_surface.md`](ui/agent_surface.md).

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
