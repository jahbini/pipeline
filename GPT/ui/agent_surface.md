# UI as agent surface

Area: `ui_server.coffee` + the `/api/*` HTTP surface

## The reframe (June 2026)

The UI is no longer just a human-facing dashboard. It is a **dual-consumer
surface**: a human at a browser AND a Claude session running on the same
machine, both driving the same pipelines and reading the same results.

That changes what the `/api/*` endpoints are for. They were the HTML page's
private back-channel; they become the canonical contract that both
consumers share. The HTML page becomes a thin wrapper over the same
endpoints Claude calls. Any new agent-driven feature gets a human-visible
reflection for free (or you skip rendering it, fine).

The agent loop the surface needs to support, end to end:

1. **Generate** — create new recipes, override files, step scripts.
2. **Alter** — edit existing recipes/overrides/scripts.
3. **Conduct** — launch runs, monitor status, kill/restart.
4. **Evaluate** — read artifacts on disk, query SQLite for new rows,
   diff state against a prior run.

All of that happens through `/api/*`. The HTML page does a subset of the
same things through the same endpoints.

## Settled decisions

- **Posture: local-only, no auth.** The Claude agent and the experiments
  both live on the mac-mini. The laptop reads the same UI by binding the
  server to `0.0.0.0` via `UI_BIND_MODE=net` (or `npx pipeline-ui net`).
  Trust boundary is the LAN, not the server. The existing
  `GPT/ui/ui_server.md` "Deployment posture" rule (dev-only, no auth,
  no CSRF) stands.
- **Single process, internal split.** One `ui_server.coffee` keeps owning
  the port and the route dispatch. The handlers split into per-concern
  files (recommended layout below). No second process, no second port.
- **Per-active-pipe SQLite views.** The UI's pipe selector already switches
  `CWD`. SQLite views key off `CWD/runtime.sqlite` automatically.
- **Reuse the sqlite meta layer.** New `/api/sqlite/*` endpoints dispatch
  request keys through the same `meta/sqlite.coffee` `REQUESTS` map the
  steps use, via the Memo's `theLowdown`. One source of truth for
  request-keyed SQL; no duplicate handcoded queries in the UI.

## Five structural concerns the agent surface must address

### 1. API formalization

- Stable JSON shape for every endpoint (named fields, no `_extra` bag).
- Idempotency where it matters — `POST /api/launch` twice should not start
  two runs (today's behavior: enforced by `ensureSingleInstance`).
- A `GET /api/manifest` that returns a complete description of what the
  pipe currently has: active pipe, available pipes, available recipes
  (parsed, with step + artifact lists), available sqlite request keys,
  artifacts on disk, and the registered endpoint set. This is the agent's
  entry point: it bootstraps without prior knowledge of names.
- **Stable run IDs.** Today `run.logdir` (the `HH_MM` stem) is the closest
  thing; collisions are possible across days. Promote to a UUIDv4 or to
  `${pipe}-${ISO-timestamp}-${shortHash}` so an agent can refer to a run
  by id and the reference survives.

### 2. Mutation endpoints

The agent needs to write recipes, overrides, step scripts. The
endpoints these expand into:

```
GET  /api/recipe?name=…                  → current recipe yaml + parsed view
PUT  /api/recipe?name=…   body=yaml      → create/replace; returns merged experiment.yaml
GET  /api/override?recipe=…              → current override yaml
PUT  /api/override?recipe=…  body=yaml   → returns merged experiment.yaml
GET  /api/script?path=…                  → current step script source
PUT  /api/script?path=…   body=text      → returns success + resolved location
```

All writes are **CWD-scoped** (per-pipe) by default. Writes outside CWD
(into BASE or EXEC) are rejected — agent-driven changes shouldn't escape
the active pipe without an explicit override.

Every PUT returns the post-write effective state (the merged
`experiment.yaml`, or the resolved script path) so the agent never has
to guess what got persisted. Validation (toposort, `stepScriptCandidates`
resolution, meta handler presence) runs server-side; failure returns
4xx with the specific reason.

### 3. Discovery (the manifest)

`GET /api/manifest` returns roughly:

```yaml
base:           "/Users/jahbini/experiments-withqwen/myproj"
pipe_root:      "/Users/jahbini/experiments-withqwen/myproj/pipe"
active_pipe:    "diary"
pipes:          ["diary", "lora_test"]
recipes:
  available:    ["diary_ite", "lora_ite", "oracle_ite", ...]
  by_name:
    diary_ite:
      steps:        [{name, depends_on, needs, makes}, ...]
      artifacts:    [{name, target, source}, ...]
sqlite_requests:  ["allStories", "kagFor{id}.json", "loraTrainingRuns", ...]
artifacts_on_disk:["out/diary_base.txt", "out/lora_run_record.json", ...]
endpoints:        [{method, path, summary}]
```

This is the agent's bootstrap call. Cheap (assembled from already-loaded
state) so a fresh session can call it on every action without polluting
status polling.

### 4. Evaluation surface

For "did the run succeed and what did it produce?", agents want one call
per run:

```
GET  /api/run/{run_id}        → status, exit code, stderr tail, produced block:
                                  - artifacts_written: [{key, target, kind, size}]
                                  - sqlite_rows_added: {table: count, ...}
                                  - new_row_ids: {lora_training_runs: ["..."], ...}
GET  /api/sqlite/{key}?...    → run a request key through the meta layer
GET  /api/sqlite/diff?since={run_id}
                              → which rows were added/changed since a prior run
```

The diff endpoint is the most agent-valuable: it answers "what changed
because of this run?" precisely. Cheapest implementation: a per-pipe
`_change_log` table populated by sqlite triggers on the tracked tables.
A run records its start timestamp at launch and uses it as the diff
floor on evaluation.

### 5. Concurrency (deferred, but flagged)

A human at the laptop and Claude on the mini may both write to the same
override.yaml in the same second. Today's UI assumes one editor. Three
options when we hit it:

- **Last-writer-wins.** Simple; the diff is visible because both can read
  the merged file. Acceptable for low-collision workflows.
- **If-Match etag.** PUT requires a header matching the file's mtime/sha.
  Server rejects stale writes; client retries.
- **Lock files.** Heaviest; needed only if we see real corruption.

Default to last-writer-wins. If a real collision shows up, escalate to
etags.

## Recommended file layout

Single process, single `ui_server.coffee` keeps the port + route dispatch.
Handlers split by concern so the file stops growing without bound.

```
ui_server.coffee                 ← keeps: process bind, route dispatch, polling gates
lib/
  api/
    manifest.coffee              ← GET /api/manifest
    status.coffee                ← GET /api/status (existing)
    pipes.coffee                 ← /api/pipes, /api/switch_pipe
    recipes.coffee               ← /api/recipe, /api/override, /api/script CRUD
    runs.coffee                  ← /api/launch, /api/kill, /api/run/{id}, /api/shutdown_ui
    sqlite.coffee                ← /api/sqlite/{key}, /api/sqlite/diff
    artifacts.coffee             ← /api/file, /api/artifact, /api/log
```

Aligns with the streamlining sketched in earlier discussion: leaf
extractions first, then the api/ subfolder once endpoints multiply.

## Status (June 2026) — all five steps landed

The five-step implementation sequence from the original design is now
in production. Each landed as an independently-shipped commit on `api`.

1. **Observability foundation.** ✅
   `GET /api/sqlite/<encoded-request-key>` dispatches through the same
   `meta/sqlite.coffee` REQUESTS map the steps use, via a per-CWD `Memo`
   cache (`getSqliteMemoForPipe` in `ui_server.coffee`). Three new
   collapsible left-column panels: **Stories** (`allStories.jsonl`),
   **Training Runs** (`loraTrainingRuns.jsonl`), **Story Usage**
   (`loraStoryUsage.jsonl`). All default collapsed; refresh on the
   existing 2-second poll cycle.

2. **Manifest + stable run IDs.** ✅
   `GET /api/manifest` returns the full bootstrap payload
   (`base / exec / cwd / pipe_root / active_pipe / pipes / recipes /
   sqlite_requests / artifacts_on_disk / endpoints`). Recipes are parsed
   with `expandIncludes` + step/artifact extraction. The runner generates
   a UUID at launch (`crypto.randomUUID()`), stamps it into
   `state/ui-run.json.id` AND a new `runs` SQLite table via the new
   `runRegister{<id>}.json` / `runUpdate{<id>}.json` meta requests
   (`finalizeRunStatus()` wraps both surfaces). Three additional meta
   requests cover the read side: `runById{<id>}.json`, `runHistory.jsonl`.

3. **Run evaluation endpoint.** ✅
   `GET /api/run/<run-id>` composes: the `runs` row, log+err+artifact-log
   tails, `artifacts_written` (files in `out/` + `build/train/` + `state/`
   whose mtime falls in `[started_at-2s, finished_at+2s]`), and
   `sqlite_rows_added` (per-table count + ids). New "Run History" panel
   in the left column lists the most recent 20 runs; clicking a row
   loads the detail inline. Still-running rows refresh on each poll
   tick via `currentRunDetailId` carry-over.

4. **Mutation endpoints + validation.** ✅
   Six routes — `GET/PUT /api/recipe?name=…`, `GET/PUT /api/override?recipe=…`,
   `GET/PUT /api/script?path=…`. All writes are CWD-scoped. Each PUT
   accepts `{content: "<yaml-or-coffee>"}`; YAML PUTs run through
   `parseYamlSafely` + `discoverStepsLocal` + `validateToposort` (Kahn's
   algorithm; recognizes the `depends_on: never` off-switch); `.coffee`
   script PUTs are compile-checked before write. Path-safety helper
   `ensureSafeRelPath` rejects `..`, leading `/`, embedded spaces, and
   `path.sep` escapes. Every PUT returns the post-write effective state
   — the merged `experiment.yaml` for recipe/override, the resolved
   path + candidates for scripts — so the caller never has to guess.
   405 on method mismatch.

5. **SQLite diff.** ✅
   New `_change_log(change_id, ts, table_name, op, row_id)` table with
   `ts` and `table_name` indexes. 30 triggers cover INSERT/UPDATE/DELETE
   on the ten tracked tables (`stories`, `story_parts`,
   `expanded_story_parts`, `kag_entries`, `oracle_story_attempts`,
   `lora_trained_stories`, `lora_story_usage`, `lora_training_runs`,
   `lora_training_run_stories`, `runs`); compound primary keys are joined
   with `|`. Triggers timestamp via `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')`
   so they compare lex-cleanly against `runs.started_at`. New
   `changesSince{<arg>}.json` meta request — discriminates UUID
   (resolves to `runs.started_at`), ISO timestamp (direct), or integer
   (treated as `change_id` anchor). `GET /api/sqlite/diff?since=…` is the
   client-friendly route, registered **before** the generic
   `/api/sqlite/<key>` handler to avoid mis-dispatch; performs
   client-side shape validation and returns specific 400s with an
   `accepted_shapes` hint on malformed input. `buildRunEvaluation`
   pipes `sqliteRowsInWindow(...)` through `mergeChangeLogCounts(...)`
   so every tracked table reports a precise `{count, source: 'change_log'}`
   in `/api/run/{id}`, including the previously-`null` ones at
   `{count: 0}` when no changes occurred.

The endpoint count in `KNOWN_ENDPOINTS` advertised by `/api/manifest`
is 20 (12 read + 6 mutation + 2 lifecycle composites). The recipe selector
auto-discovers from CWD + BASE + EXEC `config/` (the three-tier
`resolveConfigPath`). Every recipe in `config/<name>.yaml` is callable
through this API without further setup.

## Operational notes

- **Where things land:**
  - SQLite schema + triggers + `changesSince`: `meta/sqlite.coffee`.
  - Run lifecycle hooks (UUID, `finalizeRunStatus`): `pipeline_runner.coffee`.
  - All routes + composite endpoints + helpers: `ui_server.coffee`.
  - UI panels + the click-to-load Run Detail JS: `ui/index.html`.
- **State files affected:** `state/ui-run.json` gains an `id` field
  (UUID). Existing readers tolerate unknown fields.
- **DB migrations:** the bootstrap `db.exec` block is `CREATE TABLE IF
  NOT EXISTS` / `CREATE TRIGGER IF NOT EXISTS`. Existing DBs add the
  `_change_log` table and triggers on next runner or `ui_server` boot
  with no manual migration. **Historical rows predating the triggers
  are not in `_change_log`**; the diff is honest about its window.
- **Path conventions:** all PUTs write under CWD (`config/`, `override/`,
  `scripts/`). The agent **cannot** write into BASE or EXEC via these
  routes — intentional, so generated artifacts stay scoped to the active
  pipe.

## Out of scope (deliberately)

- Auth/CSRF/CORS — the LAN is the trust boundary; the existing
  `ui_server.md` deployment posture stands.
- Cross-pipe roll-ups (e.g., training history across all pipes under a
  BASE) — per-active-pipe is the rule; if cross-pipe becomes useful
  later, add a separate top-level endpoint, don't smear it into
  `/api/sqlite/{key}`.
- A separate `api_server` process — single process, internal split, end
  of discussion.
- WebSocket / SSE event streams — polling at the existing cadence is
  sufficient until proven otherwise. The 2-second poll gate that already
  exists is the right granularity for an agent loop too.

## Deferred follow-ups (will compound the agent surface, not yet built)

- **`_change_log` pruning.** The table grows unbounded. A
  `pruneChangeLog{<keep-after-change-id>}.json` write request or a
  retention policy (e.g., keep last N runs' worth) becomes worth
  building once the table approaches single-digit MB. Until then, it's
  cheap append-only storage and Claude's diffs all care about the
  recent tail.
- **Streaming / SSE.** If poll latency becomes a problem for fast
  agent loops, an SSE channel reading `_change_log` tail-style is
  the natural fit. The change-log architecture already supports it;
  only the transport is missing.
- **Cross-pipe / project-wide manifest.** A separate
  `GET /api/projects` or `GET /api/all_runs` could roll up across pipes
  if the agent loop ever spans them. Add as a *new* endpoint, never by
  widening the per-pipe contracts.
- **`lib/api/` extraction.** `ui_server.coffee` is now ~2 KLoC. The
  per-concern split sketched in "Recommended file layout" above is the
  natural next refactor. Independent of features.

## See also

- `GPT/ui/ui_server.md` — UI layout, polling gate, deployment posture,
  lifecycle controls.
- `GPT/pipeline_architecture.md` — project layout (`experiments-withqwen`
  convention), BASE/EXEC/CWD resolution tiers, brace substitution.
- `GPT/pipeline_runner.md` — runner contract, the meta dispatch model,
  artifact access ledger.
