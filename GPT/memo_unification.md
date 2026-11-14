# Memo unification — ONE memo, in-process; broker = transport only

**Status: BUILT + probed 2026-11-07 on the laptop. NOT synced to the mini
(jahbini: mini off-limits for a few hours — see the pending-sync list in
`~/claude_zone/nov_7/MEMORY_KNOWLEDGE.md`). Activates per node on restart.**

jahbini's ruling (2026-11-07): "The split memo/broker needs to be addressed
immediately. And the use of the meta to handle file, sqlite, ssh and http
requests must be honored." This doc records what the split actually was and
what was cut. Doctrine: marriage.md ("the memo is the runner's IN-PROCESS
memo — never state/memo.sqlite, never a broker RPC", jahbini 2026-10-28).

## What the split was (diagnosed, not assumed)

Three stores claimed to be "the memo":

1. **The live one** — the fused node's in-process `M` (`meta/ui` rule gives
   `ui/*` + `sys/*` memo semantics; browser `/api/ui` + `/api/memo` both
   write `M.saveThis`; SSE streams off `M.ui.subscribe`; `sys/*` converges
   across nodes via the retained-message replication over `M.certBus`).
2. **A ZOMBIE RPC plane** — `bootFusedNode` hosts the broker with **no Memo
   and no RPC handlers**, while `wireRunner` (fired in every `runRecipe`)
   attached as a client and handed steps `L.memoRequest` = RPC into that
   handler-less broker. Every step memoRequest silently fell to its
   catch-default (e.g. `fleetMode()` could never return anything but
   'serial').
3. **A STALE sqlite** — `~/pipeline/state/memo.sqlite`, written only when
   some past process won a socket election; `queue_run_ite.isFleetFrozen`
   read it directly. Split-brain: `sys/freeze` SET in the live memo while
   the sqlite peek said not-frozen.

## The cut (2026-11-07)

- `ipc/wire.coffee` — `becomeHost` no longer instantiates the sqlite
  `Memo` (forensics escape hatch: `LEGACY_SQLITE_MEMO=1`). Broker hosting
  stays: TRANSPORT only (step/state/lifecycle publishes, retained
  messages, sys/* replication, cert push).
- `pipe_ui_runner.coffee` — `L.memoRequest` is now served **in-process**
  by `M` (get/put/del/get_prefix, same vocabulary as meta/ui's plugin
  shim). Steps finally read/write the same store the browser does.
- `meta/ui.coffee` — **sys/\* durability**: writes persist (500ms
  debounce) to `<base>/state/sys_memo.json`, rehydrated at device load.
  Durability is the FILESYSTEM, per doctrine — `sys/freeze` now survives
  a node restart. `ui/*` stays process-local by design.
- `queue_run_ite.coffee` — `isFleetFrozen(L)` reads the in-process memo
  via the ledger; the direct-sqlite `_readMemoValue` is deleted.
- **`meta/http.coffee` (NEW device)** — HTTP as request keys
  (`<name>.http`, struct `{method, host?, port, path, body?, timeout_ms?}`),
  mirror of `meta/remote`'s `.remote` notifier contract. `agent: false`
  (a pooled keep-alive socket whose far end closes crashes the node with
  an unhandled ECONNRESET — probed under Node 24).
- `writer_scheduler_ite.coffee` — rewritten with **zero direct I/O**: no
  fs/path/http requires. pipe_states via meta/json key
  (`state/pipe_states.json`), dir/artifact probes via NEW
  `tools/pipe_probe.coffee`, memory gate via `tools/model_footprint`,
  all HTTP via `meta/http` keys, freeze via `L.theLowdown('sys/freeze')`.
  Its "sanctioned dispatcher exception" header claim was false — removed,
  and CONVENTIONS now states explicitly there is NO dispatcher exception.
- **Bug fixed in `meta/http`, `meta/remote`, AND `meta/hfchat`**: the
  error-path `.catch` ended with `latest.notifier = rejected` —
  CoffeeScript's implicit return handed the rejected promise back to the
  chain → **unhandled rejection → process-fatal** under Node's default.
  Explicit `return` added in all three. (Latent in remote + hfchat since
  they were written.)

## Request-key await contract (loose-end audit, same day)

Two traps found reviewing the first cut — both fixed, both load-bearing:

1. **`L.need` throws for undeclared keys** in the fused ledger
   (pipe_ui_runner `need:` checks needs/makes). The `.remote` docstring's
   `await L.need 'probe.remote'` pattern does NOT work from a step unless
   the key is declared. The working pattern for request keys:
   `L.saveThis tag, struct` then `entry = L.theLowdown tag` then
   `await entry.notifier` (the two calls are synchronous back-to-back, so
   the entry is guaranteed to be the pending one; check
   `entry.value isnt undefined` first for belt-and-braces).
2. **Replacing `entry.notifier` with a rejected promise cannot reject a
   promise an awaiter already holds** — the `.remote`/`.hfchat` error
   convention would HANG such an awaiter forever. `meta/http` instead
   resolves errors through the sanctioned pass-through path: the entry
   hydrates to `{ok: false, __http_error}`; callers check the marker.
   (remote/hfchat keep their convention for L.need-time reads — flagged,
   not migrated.)

Also from the audit: `puppeteer/params/_global.yaml` remote_peers UI_PORT
4311 → 8100; `sys/presence/*` + `sys/pipe_inventory/*` are excluded from
sys_memo.json persistence/rehydrate (ephemeral beats, meaningless across
restarts). Live-verified on the laptop :8100 node: a `.http` key hydrated
through the real Memo, and sys/* writes landed in `state/sys_memo.json`.

Probes: `pipeline/test/memo_unification_probe.coffee` — 6/6 (http
dispatch/hydrate/error-reject; sys persist; ui not persisted; restart
rehydrate).

## Invariants

- M1: one store per node — `M`. Nothing instantiates `ipc/memo.coffee` in
  the fused world; nothing reads `state/memo.sqlite`.
- M2: `L.memoRequest`, `/api/ui`, `/api/memo`, SSE, and step `theLowdown`
  all observe the same value for the same key, immediately.
- M3: `sys/*` survives node restart (sys_memo.json) and converges across
  same-host nodes (broker replication). `ui/*` is node-local.
- M4: steps do no direct I/O — file/sqlite/ssh/http all via meta
  (request keys) or `S.tools` (fs probes). No dispatcher exception.

## Named debt (not done today)

- `ipc/lease.coffee` CPU slots + `status_source.coffee` still speak
  broker-RPC-memo; `M.ipc.lease` degrades gracefully (unused today).
- `queue_run_ite`'s remaining direct-I/O inventory (pipe_states fs,
  callPeer fetch, execSync pgrep, spawn_log sqlite) — listed in
  marriage.md Stage C notes; migrate to meta/http + meta/json + tools.
- `puppeteer/ui/project.coffee` plugin I/O (execSync ssh/curl) is UI-layer
  (not a step) but should converge on the same devices eventually.
- `ipc/switchboard.coffee` + the sqlite `memo.coffee` store are now
  dead code behind the env flag; delete after a trust window.
