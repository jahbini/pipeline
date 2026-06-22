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

## Implementation sequence (suggested)

Each step independently shippable:

1. **Observability foundation.** New left-column panel showing per-pipe
   SQLite views: Stories (count, list, click-detail), KAG (recent entries),
   Training Runs (history table). Backed by `/api/sqlite/{key}` reusing
   the existing `REQUESTS` map. No mutation yet.
2. **Manifest + stable run IDs.** `/api/manifest` and a UUID run id
   stamped into `run.id` at launch. Run history table in SQLite.
3. **Run evaluation endpoint.** `/api/run/{id}` returning the produced
   block (artifacts + sqlite rows). Powers a "Run Detail" pane in the UI.
4. **Mutation endpoints + validation.** `/api/recipe`, `/api/override`,
   `/api/script` CRUD with server-side validation. The existing
   `Recipe And Overrides` textareas become thin wrappers around these.
5. **SQLite diff.** Per-pipe `_change_log` table + triggers + the
   `/api/sqlite/diff?since=...` endpoint. The killer feature for agent
   evaluation.

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

## See also

- `GPT/ui/ui_server.md` — UI layout, polling gate, deployment posture,
  lifecycle controls.
- `GPT/pipeline_architecture.md` — project layout (`experiments-withqwen`
  convention), BASE/EXEC/CWD resolution tiers, brace substitution.
- `GPT/pipeline_runner.md` — runner contract, the meta dispatch model,
  artifact access ledger.
