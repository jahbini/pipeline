# IPC — in-process broker + sqlite memo

**Introduced**: 2026-10-08. **Location**: `pipeline/ipc/*.coffee`.
**Status**: live on the mac-mini; UI falls back to disk reads when
the runner isn't up.

## Why

Before this, the runner's only interface to UI servers was the state
files it writes to disk (`state/ui-run.json`, `state/step-*.json`,
`state/ui-events.jsonl`, …). Every UI poll re-read 8+ files per
`/api/status` tick. Three ui_servers each independently SSH'd to the
mini for peer state. Audit put the per-tick cost at ~2–5s wall-clock
on the puppeteer when a mini call was in-flight.

The broker is a pub/sub + RPC layer **on top of** the disk writes —
disk stays authoritative for crash/restart; the broker publishes
retained snapshots after each write and serves them to subscribers.

## Modules

| File | Role |
|---|---|
| `broker.coffee` | In-process broker. Opens `state/runner.sock` (unix domain). MQTT-style topic matching (`+`, `#`). Retained snapshots served on new subscription. RPC via `req`/`res` frames keyed by `reqid`. Supports a `proxy_handle` frame for the cross-host bridge. |
| `broker_client.coffee` | Reusable socket client. Auto-reconnect (2s backoff), subscribe/publish/request. A no-op `'error'` listener is attached at construct time so a missing socket (runner down) doesn't crash the host process. |
| `memo.coffee` | SQLite-backed key/value store at `state/memo.sqlite`. CAS, bounded history for `ui/intent/*` and run verdicts, auto-publish on change for `memo/ui/*`, `memo/sys/*`, `memo/pipe/*/schedule/*` topics. `rehydrate()` replays retained snapshots on boot. |
| `wire.coffee` | One-call runner integration. Probes the socket: if a switchboard daemon is listening it attaches as a **client** and publishes through it; otherwise it **hosts** its own broker + memo (legacy). Patches `StepStateStore.write` / `.delete` and the UI recorder's `saveRun` / `event` to publish AFTER the existing disk writes, via whichever transport. |
| `switchboard.coffee` | **Standalone per-host broker + memo daemon** (2026-10-21). launchd-managed; owns the Broker + the Memo sqlite on `runner.sock`, resident so memo keys / retained state / the SSE seam work **at idle** (no runner required). `rehydrate()`s memo on boot. See "Broker placement" below. |
| `status_source.coffee` | UI-side cache fed by broker. Subscribes to `runner/+/+/state`, `step/+`, `event`, `lifecycle`, and `memo/#`; an `EventEmitter` that re-emits those for the ui_server's SSE. Exposes `getRun()`, `getSteps()`, `getEvents()` returning cached data OR `null` when disconnected (callers fall back to disk). |

## Invariant

Disk writes are the source of truth. Every `broker.publish(...)` fires
**after** the existing `fs.writeFileSync` returns. Crash mid-write
leaves the disk in a consistent state; the broker simply doesn't emit
for that attempt. On runner restart, retained snapshots are rebuilt
from disk during the first write pass.

## Topic schema (summary; see spec in commit history)

```
runner/<host>/<pipe>/state           retained   ui-run.json equivalent
runner/<host>/<pipe>/step/<idx>      retained   step-*.json
runner/<host>/<pipe>/step/current    retained   {idx, status, done, at}
runner/<host>/<pipe>/event           volatile   append to ui-events.jsonl
runner/<host>/<pipe>/lifecycle       retained   {phase, pid, host, pipe, since}

runner/<host>/<pipe>/meta/sqlite/req       memo RPC request/reply
runner/<host>/<pipe>/meta/sqlite/res/<id>

memo/ui/<key>                        retained   mirror of ui/* memo keys
memo/sys/<key>                       retained   mirror of sys/* memo keys
memo/pipe/<pipe>/schedule/<key>      retained   recipe schedule knobs
memo/story/<key>                     retained   spine library keys (2026-10-21)
memo/run/<run_id>/preview            retained   live step output (2026-10-21)
memo/run/<run_id>/progress           retained   live step progress (2026-10-21)
```

Deletion semantics (fixed 2026-10-21): `memo.del` (or a put of literal
`null`) publishes a **null payload with retain:true** — clearing the
broker's retained record so late subscribers never replay a dead key —
followed by a volatile `{value:null, version, …}` tombstone for live
subscribers. Before this fix, deleted keys replayed their stale value
to every new subscriber for the broker's lifetime.

Liveness (2026-10-21): the runner's `exited` lifecycle publish fires
from `beforeExit`/`exit` hooks and may never flush. The socket-close
event is the authoritative "runner down" signal — `status_source`
synthesizes `lifecycle.phase = 'disconnected'` on close, and
`ui_server` scopes its StatusSource to the workspace's pipe
(`filterPipe`) so another pipe's run can't masquerade as the current
one in `/api/status`.

The topics are an addition; nothing today has moved to pub/sub-only.
The UI reads from both the broker cache AND the disk files — whichever
has fresher data.

## Memo namespaces

```
ui/                 operator intent, cross-UI shared view state
run/<run_id>/       durable per-run facts (verdict, notes, tags)
pipe/<pipe>/        per-pipe durable config (not hot state)
adapter/<id>/       adapter annotations
story/<slug>/       writer-pipeline annotations
sys/                cross-UI coordination (active_runner, presence, freeze)
```

See `pipeline/ipc/memo.coffee` for the full validation regexes and the
`HISTORIED` + `NOTIFIED` pattern lists.

## RPC surface

The runner installs one handler via `memo.installHandlers()`:

```
runner/+/+/meta/sqlite/req   {op, key, value?, if_version?, prefix?, limit?, n?}
```

Operations: `get`, `get_prefix`, `put`, `cas`, `del`, `history`.

The handler responds on the paired `/res/<reqid>` topic — the broker
routes the response back to the originating client automatically.

## UI HTTP surface (2026-10-21)

`pipeline/ui_server.coffee` exposes the broker/memo wedge over HTTP so
the browser never speaks the broker protocol (the ui_server
multiplexes). All added in the 2026-10-21 reactive-UI wedge:

```
GET    /api/ipc_health          {broker_connected, cache_ready, lifecycle, filter_pipe, memo_rows}
GET    /api/events              SSE: event: hello|run|step|event|lifecycle|memo; `: ping` heartbeat every 20s
GET    /api/memo/<key>          {value, version, updated_at, updated_by} | 404; source:'disk' when broker down
POST   /api/memo/<key>          body {value, if_version?}; no if_version → put; if_version → CAS (409 on mismatch)
DELETE /api/memo/<key>          {ok:true} | 404
GET    /api/memo?prefix=<p>     {entries:[...]}; source:'disk' when broker down
```

- The memo endpoints route through `StatusSource.memoRequest(op, args)`
  (RPC to the runner's memo handler). The request topic carries the
  StatusSource's `filterHost/filterPipe` (or `+`) — the broker's
  `matches()` routes it to the `runner/+/+/meta/sqlite/req` handler
  regardless, so a literal `+` segment is fine.
- **Broker-down policy:** WRITES return `503 {error:'runner_down'}`.
  READS fall back to a read-only `DatabaseSync` open of the memo sqlite
  and tag the response `source:'disk'` so a caller never mistakes stale
  disk data for live broker data (UI-must-reflect-truth).
- `StatusSource` is an `EventEmitter`; it emits `run/step/event/`
  `lifecycle/memo` which `/api/events` forwards. `memo` is reshaped to
  the browser contract `{key, value, version, deleted}`. Listeners are
  per-SSE-connection and removed on `req 'close'`; `maxListeners` is
  lifted to 200.

### Socket / DB env overrides (2026-10-21)

`RUNNER_SOCK` overrides the broker unix-socket path; `MEMO_DB`
overrides the memo sqlite path. Both default to the canonical
`$HOME/pipeline/state/{runner.sock,memo.sqlite}` and are honored in
`status_source.coffee`, `wire.coffee`, `memo.coffee`, and
`ui_server.coffee` (health count + disk fallback). They exist for
scratch-broker testing today and give the future MARRIAGE switchboard a
configurable endpoint. Leave unset in production.

## Broker placement: the switchboard daemon (2026-10-21)

Originally the broker lived **inside** the pipeline_runner (`wire.coffee`
hosted it), so memo keys and the SSE seam only existed while a pipeline
happened to be running — a memo-driven UI went dark at idle. Fixed by
extracting a resident daemon:

- **`switchboard.coffee`** is a tiny launchd job (one per host) that owns
  the Broker + Memo on `runner.sock`. It outlives every run, so
  retained run state, `ui/*`/`sys/*`/`story/*` memo keys, and the
  ui_server's `/api/events` stream all work with nothing running.
- **`wire.coffee` elects** on startup: it connects to the socket; if a
  broker answers it runs as a **client** (publishing state/step/event/
  lifecycle through the daemon — the daemon owns the memo + RPC
  handlers); if nothing answers it **hosts** its own broker (legacy
  single-process mode). This avoids the old unlink-then-listen
  socket-steal: a runner never clobbers the daemon's socket.
- **Mini launchd job:** `~/Library/LaunchAgents/com.jahbini.switchboard.plist`
  (`RunAtLoad`+`KeepAlive`), `coffee ~/pipeline/ipc/switchboard.coffee`,
  logs to `~/pipeline/logs/switchboard.{log,err}`. The puppeteer
  ui_server's StatusSource auto-reconnects to it (2s backoff), so the
  daemon and UI start in any order.
- **Known limitation (future refinement):** with the daemon hosting the
  broker, a runner-client's death is its socket dropping *at the
  daemon*, not a close the ui_server observes — so the ui_server can
  still show a dead runner's last retained state. The `exited`
  lifecycle publish is best-effort. MARRIAGE.md's "daemon republishes
  disconnected on client drop" is the eventual fix; not built yet.

This is MARRIAGE.md stage 2 ("extract the switchboard"), landed.

## Cross-host bridge

Not yet implemented. The broker already supports a `proxy_handle`
frame for a bridge process to install forwarding RPC handlers over a
unix socket forwarded by `ssh -L`. Design is in `pipeline/GPT/`
history (search commits for `bridge.coffee`). When built, the bridge
replaces every puppeteer-side `execSync('ssh …')` with a broker RPC —
eliminating the 2–5s event-loop stalls.

## Related

- `[[plugin_system]]` — how the ui_server loads project-specific routes.
- `[[puppeteer_project_plugin]]`, `[[writer_project_plugin]]` — concrete plugins.
- `pipeline_runner.coffee` wires in via `require path.join(EXEC, 'ipc', 'wire')`
  immediately after `U.reset()`, inside a try/catch — the runner never
  fails because the broker failed to start.
