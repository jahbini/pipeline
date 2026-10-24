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

## Steal-the-socket footgun — FIXED 2026-10-23 (octopus)

Symptom seen on the mini: puppeteer controller (4300) `broker_connected:true`
while the writer puppet (4311) was `broker_connected:false`/`disconnected`
and its whole reactive UI (memo/SSE, spine editor, filters, live
certificate updates) was dead. `lsof` showed the controller STILL
listening on `~/pipeline/state/runner.sock` (fd 12u) — but `stat`/`ls`
reported **no such file**: the socket's directory entry had been
`unlink()`ed out from under the live listener. The controller's own
already-open fds kept working (looked healthy), but **every new client**
— the puppet UI, a fresh browser tab, the next runner — got `ENOENT` on
`connect()`.

Two root causes, both now fixed:

1. **`broker.coffee::listen()` unconditionally `fs.unlinkSync`ed the
   socket before binding.** That is the steal primitive: it removes a
   resident controller's path. Fixed to bind first; only on `EADDRINUSE`
   probe whether a live listener answers — live → refuse (emit `error`
   so the caller falls back to client), refused/missing → stale file,
   reclaim (unlink + retry once). The lone-runner "reclaim a stale
   socket from a crashed owner" path is preserved (verified: a
   SIGKILLed owner's leftover socket is reclaimed).
2. **`wire.coffee` election hosted on a 600ms probe timeout.** A resident
   controller that was briefly slow to `accept` the probe (the old
   `execSync('ssh')` event-loop stalls) made a runner time out → host →
   unlink + steal. Fixed: a probe that neither connects nor errors now
   RETRIES with backoff (`MAX_PROBE=5`) and **never hosts on a stall**;
   only a definitive `ECONNREFUSED`/`ENOENT` (nothing listening) hosts
   promptly (lone-runner fast path, no added latency).

Recovery when it has already happened: restart the puppeteer-ui launchd
job (`launchctl kickstart -k gui/<uid>/com.jahbini.puppeteer-ui`) — it
rebinds a fresh `runner.sock`; puppets reconnect on their own via
`broker_client`'s 2s backoff (no puppet restart needed). Safe only when
no `pipeline_runner` is active. This is the risk UI_MEMO.md and
MARRIAGE.md both predicted ("wire.coffee does unlink-then-listen → a
second runner steals the socket").

## Stage B — SSH-launch + MQTT over SSH — CORE DONE 2026-10-23 (octopus)

Cross-host transport + puppet launch, smoke-tested laptop→mini.

- **`ipc/puppet_supervisor.coffee`** (controller side). For each REMOTE
  puppet in the `puppets:` roster it keeps one long-lived, supervised
  `ssh -R <remoteSock>:<brokerSock> -o StreamLocalBindUnlink=yes -o
  ExitOnForwardFailure=yes -tt <user>@<host> 'cd <base> && exec env
  RUNNER_SOCK=<remoteSock> UI_ROLE=puppet UI_PORT=<n> BROKER_CLIENT_ONLY=1
  coffee <pipeline>/ui_server.coffee net'`. The one ssh does both jobs:
  reverse-forwards the controller's broker socket onto the puppet host
  AND launches the puppet as a client over it. `-tt` means tunnel death
  SIGHUPs the puppet (liveness = the SSH/broker connection). Restart on
  exit with capped backoff; `status()` for `/api/puppets`. LOCAL puppets
  (same host) are skipped — they use the loopback socket directly.
- **`BROKER_CLIENT_ONLY`** (`wire.coffee`, also `opts.clientOnly`): a
  puppet runner NEVER hosts — it goes straight to `becomeClient()` and
  relies on broker_client's infinite 2s-backoff reconnect (so a
  not-yet-ready tunnel just retries). Hosting would fork a local island
  and fight `StreamLocalBindUnlink`.
- **ui_server wiring:** controller starts the supervisor once its broker
  is `listening`; a puppet heartbeats a retained `sys/presence/<host>`
  memo key every 30s (so the controller's fleet view sees it); new
  `GET /api/puppets` → `{role, puppets:{<key>:{host,ui_port,up,pid,
  restarts,lastExit,remote_sock}}}`.

Smoke test (laptop harness = Broker+Memo+PuppetSupervisor → mini writer
puppet on 4321, NOT prod 4311): puppet `/api/ipc_health` →
`broker_connected:true` (its StatusSource reached the LAPTOP broker over
the tunnel); `sys/presence/mac-mini` landed in the laptop memo;
`sup.stop()` → tunnel closed → puppet died. `ssh -R` unix-socket
forwarding needs OpenSSH ≥6.7 (both hosts are 10.x) + socket paths
<104 bytes (macOS sun_path limit — long scratchpad paths give EINVAL).

**Not yet done (B production cutover):** the mini's resident puppeteer
still runs the writer as a standalone same-host process (local socket),
not as a supervised puppet; and the `execSync('ssh …')` peer panels in
`puppeteer/ui/project.coffee` still SSH-poll instead of reading the
broker. That migration (keep SSH as fallback) is the latency win and the
riskier half — gate it.

## Stage D — fleet leases — SUBSTRATE DONE 2026-10-23 (octopus)

CAS leases on the memo so N pipes run concurrently and serialize only on
real contention. Keys (both under `sys/`, already in `NOTIFIED`):

    sys/gpu_lease/<host>   {holder, step, since, heartbeat, evicted?}   # one exclusive holder
    sys/cpu_slots/<host>   {max, held:[{pipe, since, heartbeat}]}       # up to max concurrent

- **`ipc/lease.coffee` — `LeaseClient(memoReq, {ttl,pollMs,hbMs,who})`.**
  `acquireGpu(key, holder, step, {timeoutMs,onWait})` and
  `acquireCpuSlot(key, pipe, max, …)` return a handle `{release()}`; the
  handle self-heartbeats on `hbMs`. **Crash-release (not deferrable):**
  each lease carries a `heartbeat`; a waiter CAS-evicts a holder whose
  heartbeat is older than `ttl`. Decided 2026-10-23: **ttl 60 000 ms,
  CPU max 4.** All acquire/refresh/evict/release ride the memo's `cas`
  (`{ok:false,reason:'version_mismatch'}` on a lost race, `if_version:0`
  = create-if-absent) — one writer, no new primitive.
- **Runner surface (`wire.coffee`):** the `ipc` object from `wireRunner`
  now carries `ipc.memoRequest(op,args)` — works in BOTH roles (client →
  broker RPC to the controller's single-writer memo, even over the ssh -R
  tunnel; host → its own in-process memo), after waiting out the election
  window — and `ipc.lease` (a `LeaseClient` preset to 60s/`who=pipe`) +
  `ipc.leaseHost`. A GPU step uses:

      h = await ipc.lease.acquireGpu "sys/gpu_lease/#{ipc.leaseHost}", ipc.pipe, L.stepName
      try … MLX work … finally await h.release()

- **Verified:** lease logic 10/10 against a direct Memo (exclusivity,
  release, clear, crash-eviction records `evicted`, CPU cap+blocking);
  PASS over the real broker RPC (client path); PASS from the `wireRunner`
  surface (host path).

**Runner surface DONE + proven on the live mini (2026-10-23):**
`pipeline_runner.coffee` hangs `ipc` off `M` (`M.ipc = ipc`), and
`createStepLedger`'s call site attaches to every step ledger:
`L.withGpu(fn)`, `L.withCpuSlot(fn, max=4)`, `L.memoRequest`,
`L.leaseHost` (host-slugged lowercase for the memo charset). A GPU step
writes `await L.withGpu => … MLX …`; it DEGRADES GRACEFULLY — no broker
⇒ the body runs directly (today's single-pipe behaviour). Verified
end-to-end on the live mini: a real `wireRunner` elected CLIENT of the
production controller broker, `L.withGpu`'s acquire put
`sys/gpu_lease/mac-mini` (holder visible on the controller's `/api/memo`),
release cleared it.

**GPU auto-lease WIRED + PROVEN LIVE (2026-10-23).** Rather than edit the
shared `pipeline/mlx/llm_dispatch.coffee` (no `L` in scope), the runner
wraps `L.callLLM` itself: the FIRST `callLLM` in a step lazily acquires
`sys/gpu_lease/<host>` and HOLDS it until the step ends (released in
`finish()` via `settle`), so a pipe owns the GPU for its whole generate
step and frees it before its CPU-side steps. Non-GPU steps never call
`callLLM` → never lease. Zero recipe edits; degrades to direct call with
no broker. **Live proof:** two real runners launched concurrently on the
mini (`hf__qwen__qwen3-0-6b` + `…1-5b`, instance-guard skipped) — the 1.5b
pipe held the GPU and generated while the 0.6b pipe logged
`phase:waiting_gpu holder:…1-5b waited_ms:6028→15050` (parked, NOT
loading its model); on release the 0.6b pipe acquired + generated. Exactly
one GPU holder at a time, clean handoff, no double model-load.

**Still NOT done — the scheduler auto-fan-out:**
`puppeteer/scripts/queue_run_ite.coffee` is still serial (its PRE-ENTRY
IDLE WAIT waits for the peer to go idle before launching the next pipe),
AND the peer's `/api/launch` does `switch_pipe` which KILLS the active
runner — so concurrent fan-out is NOT a queue flag, it needs the peer to
support N concurrent runners (one per pipe dir, `PIPELINE_SKIP_INSTANCE_GUARD`,
the resident-puppet model). The lease CAPABILITY is proven (manual
concurrent launch above); wiring the scheduler to auto-launch concurrent
runners that park on the lease is the remaining Stage D work (overlaps
MARRIAGE Stage C). CPU slots (`L.withCpuSlot`, `sys/cpu_slots/<host>`,
max 4) are available but not auto-wired — opt-in per step.

## Termination → mascot diagnosis (NOT blind restart) — 2026-10-23

Decision + rule: `puppeteer/GPT/rules/puppeteer_decides_restart.md`.
Restart is a scheduling decision owned by the puppeteer — NOT launchd
`KeepAlive`, NOT a blind supervisor loop.

- `ipc/puppet_supervisor.coffee` reshaped into TWO separate concerns:
  (1) **transport liveness** — reconnect the `ssh -R` tunnel with backoff
  (keeps a remote puppet reachable; not work-restart); (2) **work
  termination** — `attachLifecycle(statusSource)` subscribes
  `runner/+/+/lifecycle`, and on a terminal phase (`exited`/`failed`/
  `disconnected`) calls `handleTermination` → de-dupe → `diagnose` →
  record `pipe/<slug>/last_termination` to the memo → emit `termination`
  → **no restart**.
- `ipc/mascot_diagnose.coffee` — default diagnose: clean `exited` → `{done,
  wait}` (no LLM); else `helper_llm.classify_failure` + `summarize_log` +
  `schedule` (→ a SCHEDULE_ACTION). The mascot = the helper LLM;
  `runCapability` already wraps each call in the file-based `gpu_claim`
  (a SECOND GPU arbiter coexisting with the memo `sys/gpu_lease` —
  unify later).
- `ui_server.coffee` (controller) constructs the supervisor even with no
  remote puppets and `attachLifecycle(ipcStatus)` on broker-up.
- Proven live: a `chat_llm` exit recorded
  `pipe/hf__qwen__qwen3-0-6b/last_termination = {category:done,
  recommendation:wait}`; no restart.

### Follow-ups done 2026-10-23 (same day)

- **GPU arbiter UNIFIED on `gpu_claim`.** The runner's GPU hold
  (`L.withGpu` + the lazy `callLLM` auto-hold) now takes the host-local
  `mlx/gpu_claim` file lock — the SAME lock `helper_llm.runCapability`
  (the mascot) uses — so generation and mascot diagnosis are mutually
  exclusive on the one GPU. The memo `sys/gpu_lease/<host>` is written
  THROUGH for the fleet dashboard only (advisory, `via:gpu_claim`). CPU
  slots stay on the memo lease. Proven: a live `chat_llm` held
  `~/puppeteer/state/gpu_claim.lock` (tag `<pipe>.chat_llm`) while the
  memo showed the holder. `lease.coffee` is now GPU-unused (kept for CPU
  slots + as the cross-host memo primitive).
- **Reason enrichment.** `wire.coffee` cleanup reads `<CWD>/pipeline.json`
  (`{status,by,reason}` written on shutdown/fail) and carries
  `{ok, reason}` on the exit lifecycle, so the mascot diagnoses a real
  failure. Proven live: an injected OOM reason → mascot
  `classify_failure`→`category:oom (0.95)`, `schedule`→`hospitalize`,
  recorded. (Clean exit → no reason → fast-path `{done,wait}`.)
- **`mascot_diagnose` is SEQUENTIAL.** classify → summarize → schedule
  awaited in turn — NEVER `Promise.all`. node-mlx runs one generation
  per process and `gpu_claim` is reentrant per-pid (doesn't serialize
  same-process calls), so concurrent mascot generations HANG. (Hit this;
  fixed.)
- **`HELPER_LLM_MODEL_DIR` glob-resolved at controller boot** (`ui_server`
  top): the launchd plist literal `/Volumes/bigbig 1/…` went stale after
  a DiskArb remount to `/Volumes/bigbig`, silently breaking the mascot
  (it fell back to `escalate`). `ui_server` now scans `/Volumes` for the
  mounted `bigbig*` variant holding the model and rewrites
  `process.env.HELPER_LLM_MODEL_DIR` before anything loads helper_llm.
  Honors the "MODELS is a glob, not a literal" rule.

### Open
- **Scheduler must ACT** on `pipe/<slug>/last_termination` / the
  `termination` event (today it is recorded, not consumed).
- **Fast-crash gap.** A runner that dies in <1s (e.g. missing model dir)
  NEVER connects to the broker, so it publishes no terminal lifecycle →
  the controller's lifecycle watcher never sees it → no diagnosis. The
  reliable route for those is the **scheduler observing the exit of the
  runner IT launched** and reading `pipeline.json` — i.e., the scheduler
  side of "the puppeteer inspects a terminated pipe", still to build.
  The broker-lifecycle path covers runners that live long enough to
  connect.
- **Two GPU arbiters → one, but note:** `gpu_claim` is now the lock;
  the memo `sys/gpu_lease` is advisory. If a future design wants the
  memo to be authoritative (cross-host leases), re-unify the other way.

## Related

- `[[plugin_system]]` — how the ui_server loads project-specific routes.
- `[[puppeteer_project_plugin]]`, `[[writer_project_plugin]]` — concrete plugins.
- `pipeline_runner.coffee` wires in via `require path.join(EXEC, 'ipc', 'wire')`
  immediately after `U.reset()`, inside a try/catch — the runner never
  fails because the broker failed to start.
