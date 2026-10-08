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
| `wire.coffee` | One-call runner integration. Starts broker + memo, installs memo RPC handler, patches `StepStateStore.write` / `.delete` and the UI recorder's `saveRun` / `event` to publish AFTER the existing disk writes. |
| `status_source.coffee` | UI-side cache fed by broker. Subscribes to `runner/+/+/state`, `step/+`, `event`, `lifecycle`. Exposes `getRun()`, `getSteps()`, `getEvents()` returning cached data OR `null` when disconnected (callers fall back to disk). |

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
```

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
