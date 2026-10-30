# MARRIAGE: one class = UI + pipeline_runner, fused, one instance per active pipe — recursive puppets/puppeteers

> **Canonical home: `pipeline/GPT/marriage.md`** (moved out of
> `~/claude_zone/` 2026-10-25 so the north-star lives in the repo,
> committed + cross-machine, per `CONVENTIONS.md`). Implementation detail
> lives in `[[ipc]]`; forward work is tracked in `~/claude_zone/TODO.md`.

## ★ THE CANONICAL GOAL (jahbini-confirmed 2026-10-28) — read this; work in this order

**The merge.** Fuse `ui_server.coffee` and `pipeline_runner.coffee` into ONE
CoffeeScript class — the *recipe runner* — one instance per active pipe.
`pipeline_runner` already owns the three things that matter: the **memo
(IN-PROCESS)**, the **DAG**, and **running local recipe scripts**. The UI folds into
that same process as a **`meta/ui` I/O device**, loaded by `metaLoader` exactly like
`meta/sqlite`/`meta/yaml`, driven by the in-process memo — HTTP / SSE / asset serving
included. Steps address the UI only through meta request-keys, never a separate server.

Every node is this identical class. A **puppeteer** has subordinate puppets; a
**puppet** is the same node without. Nodes speak **octopus** to each other (up to a
puppeteer, down to subordinates). Recipe scheduling is a **petri net**.

**THE MEMO IS THE RUNNER'S IN-PROCESS MEMO — never `state/memo.sqlite`, never a broker
RPC** (jahbini, 2026-10-28). No separate `ui_server` process, no spawned
`pipeline_runner`, no broker / sqlite-memo / switchboard / leases. That whole `ipc/`
substrate is the wrong cut ([[ipc]], banner-marked obsolete) and the tar pit that
derails every session — do not reintroduce it.

## ★ STATUS 2026-10-30 — THE FUSE IS BUILT, RUNNING, AND VALIDATED (supersedes the worker-era notes below)

The merge is no longer aspirational. The fused node is **`pipeline/pipe_ui_runner.coffee`**
— ONE CoffeeScript class: the `Memo` (in-process) + the full DAG machinery + `runRecipe`
(runs a recipe in-process, never `process.exit`) + `bootFusedNode`. The UI is the
`meta/ui` device (`pipeline/meta/ui.coffee`), which owns ALL serving (static page, project
plugin routes, every `/api/*`, SSE). **No worker_thread, no `run_worker.js` shim, no
spawned `pipeline_runner`, no broker/sqlite memo.** The old worker/.js-shim fuse (described
in the sections below, and still in the LEGACY `ui_server.coffee`) was the wrong shape and
is retired from the fused path.

**Running now — THE FUSE IS THE SOLE SERVICE (legacy retired 2026-10-30).** The mini runs the
pair **launchd-resident** (`com.jahbini.pipe-ui-puppeteer` → 5400, `com.jahbini.pipe-ui-writer`
→ 5411; `RunAtLoad`+`KeepAlive`, `WorkingDirectory` = ~/puppeteer / ~/writer, shared
`GPU_CLAIM_DIR=~/puppeteer/state` so one Metal mutex, peered to each other). KeepAlive-respawn
verified. The legacy `com.jahbini.puppeteer-ui` launchd job is unloaded + its plist retired
(`.retired-20261030`); the manual writer on 4311 is stopped; **4300/4311 are gone.** The laptop
runs the same pair for dev. `pipeline_runner.coffee`, `ui_server.coffee`, `run_worker.js` are
deleted from the repo (kept as `.deprecated-20261030` on the mini for a short rollback window).
package.json bins/scripts (pipeline + puppeteer + writer) now point at `pipe_ui_runner.coffee`.

**Two cooperating taskmasters, one event loop, no 'kill':** the UI service and the DAG
runner share the one in-process memo + meta and cooperate by STATE, never by process
termination ([[taskmasters-cooperate-no-kill]], which retired the old split-process "never
kill a runner, only the UI" rule). Because they share one event loop, in-process code must
never block it — **`callMLX` and `callLLM` are both async now**, and step scripts shell out
via awaited async spawn (reference pattern + rule: `pipeline/GPT/async_fused_node.md`). This
closed the last freeze (the 2026-10-30 `download_model` git-lfs case, where a synchronous
`git lfs pull` in the fused loop made the UI stop answering).

**What the fused node serves today** (parity pass vs live legacy, 2026-10-29/30): the full
`index.html` + plugin routes + `/api/{launch,kill,status,control,human_override,file,
pipeline_svg,step_detail,step_restart,adapters,save_good_adapter,memo,ui,events,
recipe_flowchart,sqlite/*,manifest}`, with the status aggregate at structural parity
against live 4311 (every field the page consumes).

**Cutover DONE 2026-10-30** (launchd residency + legacy retirement + package.json + file
deletion — all above). Remaining tidy-ups, none load-bearing: the inert `parentPort`/`postParent`
worker-era mirror still sits in `ipc/wire.coffee` (harmless — `parentPort` is null outside a
worker; `wire.coffee` itself stays, the fused node requires `wireRunner`); a few cosmetic
`pipeline_runner`/`ui_server` mentions remain in docstrings + one `mcp/pipe_server` tool
description; and the `.deprecated-20261030` rollback copies on the mini can be removed once
trusted. Day-to-day handoff lives in `~/claude_zone/FAILURE.md` (steering only, not committed).

**The work, in order:**
0. **Establish / complete the single-process fuse.** Confirm `/api/launch` →
   `ui_server.startRunner` → `worker_thread` (`run_worker.js` → `pipeline_runner.main()`)
   is the live, SOLE launch path, and the detached child-process spawn is gone.
   (Investigation first — not building.)
1. **UI as `meta/ui`.** `pipeline/meta/ui.coffee` loaded by `metaLoader`, owning UI I/O
   end-to-end over the in-process memo; the top-level `ui_server` shrinks to a thin
   bootstrap.
   - ⏳ STARTED 2026-10-28 (proven live on the mini, additive beside the broker path):
     `meta/ui.coffee` gives `ui/*` keys in-process memo semantics + `M.ui`
     (get/set/snapshot/subscribe), ordered to beat `slash`. `ui_server` holds a
     long-lived server-level `uiMemo`; `POST /api/ui/<key>` writes land in it and
     `/api/events` pushes `ui/*` (initial snapshot + live `subscribe`) as `memo` frames
     the browser already renders. `/api/memo` (broker) and `ipcStatus` events untouched.
     Probe: `~/claude_zone/test/meta_ui_probe.coffee` (6/6).
   - ✓ FIRST REAL STATE MIGRATED 2026-10-28: the peer-pipes ward filter
     (`ui/filter/peer_pipes`) now rides the in-process `uiMemo`. `window.ui_memo`
     (`puppeteer/ui/panels/panels.js`) routes `ui/*` → `/api/ui`, everything else
     (`sys/*`) → broker `/api/memo`; `.on()`/SSE unchanged (the `memo` frame carries
     both). Server-side write/read/SSE round-trip proven; a browser hard-reload loads
     the new panels.js. **Cross-tab sync HUMAN-CONFIRMED by jahbini 2026-10-28** — a
     second mac-mini:4300 tab shows the ward filter identically, which can only come
     from `uiMemo` pushing over SSE to the other tab's `subscribe`. The merge path
     carries live operator state, in-process, end to end.
     NEXT (scouted): the remaining `ui/*` *operator* keys are actually `sys/*` (Freeze,
     Fleet mode, Peer-source) — cross-process, correctly staying on the broker for now.
     The real next piece is SERVER-PUSHED run status (run/step/event/lifecycle): today
     it round-trips the broker socket even within the one process (worker publishes via
     `wire` → `runner.sock` → main-thread `ipcStatus` → SSE). Target: carry it
     worker→main over the `worker_threads` MessagePort into `uiMemo`, dropping the broker
     from the local status path.
   - ✓ FIRST STATUS FIELD DONE 2026-10-28: `ui/run` now flows worker→main over
     **`parentPort`** — `run_worker.js` `postUi()` posts `{type:'ui',key,value}`;
     `startRunner`'s `worker.on('message')` writes it into `uiMemo`; the terminal is
     written from the worker `exit`/`error` handlers (the worker can't post across its
     own `process.exit`). Proven: SSE shows `ui/run:running` (parentPort) then `:failed`
     (exit) on a launch+kill; `/api/ui/run` round-trips. NO broker in this path. The
     `worker.on('message')` handler is generic (`type:'ui'` → `uiMemo`), so widening is
     just more `postUi` calls.
   - ✓ STEP/EVENT/LIFECYCLE DONE 2026-10-28: `wire.coffee`'s `publish()` now ALSO posts
     every base-prefixed topic to `parentPort` as `ui/<suffix>` (gated on `parentPort`,
     so the standalone CLI runner is broker-only, unchanged). A real `celarien_prep` run
     landed `ui/state`, `ui/lifecycle`, `ui/event`, `ui/step/current`, and per-step
     `ui/step/<name>` into `uiMemo` (proven via `/api/ui` snapshot), broker path intact.
     The mirror fired on EVERY publish incl. the `ui/event` firehose, broadcasting each
     to every tab — a full run ran noticeably slow.
   - ✓ COALESCE DONE 2026-10-28: `meta/ui.coffee` now batches the change→SSE emit —
     `store` updates IMMEDIATELY (get/snapshot/theLowdown always current), but the emit
     collects dirty keys and flushes the LATEST value per key on a ~40ms timer, so a
     burst collapses to ~one push/key/window. Probe (6/6) asserts: emit deferred, a
     3-write same-key burst → 1 emit carrying the latest value, unsubscribe stops it.
     Live-verified on the mini: SSE delivered a `ui/filter/peer_pipes` write through the
     coalesced path. Status-over-memo is now load-bounded + safe to rely on.
     NEXT (the payoff): point the browser at `ui/*` for status rendering (drop the
     re-fetch-on-every-push), then retire the LOCAL broker-fed SSE path — broker stays
     for cross-host/octopus only.
   - ⚠ SCOUTED 2026-10-28 — the browser status panel is BIGGER than a swap. It renders a
     server-computed aggregate from `/api/puppeteer_status` (`handlePuppeteerStatus`,
     `puppeteer/ui/project.coffee:240`): queue counts + peer-active + next-up. That
     handler is request-shaped `(req,res)`, does DIRECT I/O on the OBSOLETE substrate
     (`execSync pgrep`, `SshDispatcher.pgrepPeerRunner()` over SSH, `fs` reads of
     `queue_state.json`), and lives in the PLUGIN while `uiMemo` lives in CORE (ctx
     exposes `subscribeBroker`/`ipcStatus`, NOT a `ui/*` write). So the slice =
     (a) refactor the aggregate to a pure `buildPuppeteerStatus()`; (b) expose a `ui/*`
     write to the plugin via ctx; (c) push `ui/puppeteer_status` on coarse run/lifecycle
     events (coalesced); (d) browser renders from `ui_memo.on('ui/puppeteer_status')` +
     snapshot, dropping the per-push fetch. Done RIGHT it should rebuild the aggregate
     from the in-process `ui/*` run/step frames + memo-driven pipe/queue state rather
     than re-pushing the pgrep/ssh computation — a rethink entangled with the obsolete
     substrate. Verify at the browser. This is the next focused piece; the `ui/run` +
     step/event/lifecycle frames it needs are already in `uiMemo`.
   - ✓ SMALLER BROWSER SLICE DONE 2026-10-28: `panels.js` no longer re-fetches
     `/api/puppeteer_status` on every `step` push — coarse `run`/`lifecycle` refresh
     immediately, `step` bursts throttle to ≤1 re-fetch/1.5s (`onPushThrottled`). Cuts
     the N-tabs×per-step pgrep+ssh+fs re-fetch. Browser hard-reload to load it. The full
     memo-driven aggregate (push `ui/puppeteer_status`, render from it) is still the
     bigger piece scouted above.
2. **Steps reach the UI only via meta request-keys** (symmetric with `meta/sqlite`).
3. **One recursive class** — the same fused class as puppet or puppeteer by config;
   octopus between instances; petri-net scheduling.

> **⚠ SUPERSEDED (see the 2026-10-30 STATUS block above).** This step-0 note and the
> "CORE REQUIREMENT DELIVERED (2026-10-26)" section below describe the OLD worker_thread +
> `run_worker.js` fuse. That shape was rejected (not one CoffeeScript class; a separate
> `.js` program) and replaced by `pipe_ui_runner.coffee` (one class, in-process, no worker/
> shim), now running as the octopus. Steps 1-3 (UI as `meta/ui`, steps-address-UI-via-meta-
> key, one recursive class) are all DONE there. The prose below is kept only as the record
> of how the worker-era fuse was built — the LEGACY `ui_server.coffee` still uses it until
> cutover.
>
> **Step 0 — VERIFIED 2026-10-28 (worker-era, historical).** The worker_thread fuse was the
> live LOCAL launch path: `/api/launch` → `startRunner` → `new Worker(run_worker.js)` →
> `pipeline_runner.main()`, one PID.

## ✅ THE CORE REQUIREMENT IS DELIVERED (2026-10-26) — one process = UI + pipeline

> jahbini's actual MARRIAGE requirement was a **single process that is
> both the UI and the pipeline**, not the UI↔broker↔memo fusion the body
> of this doc originally described. That is now built and proven. The
> earlier framing (UI+broker+memo as the "controller", writers as
> *separate spawned processes*) was the wrong cut; the `ui_server`
> `spawn('coffee', ['pipeline_runner.coffee'])` was exactly the thing
> that had to go.
>
> **The memo is `pipeline_runner`'s in-process memo — NOT `state/memo.sqlite`, NOT a
> broker RPC** (jahbini, 2026-10-28: *"the memo is not the sqlite DB"*). The entire
> `ipc/` broker + sqlite-memo + switchboard + leases substrate ([[ipc]], now banner-
> marked OBSOLETE) is background from the wrong cut; it is the tar pit that re-derails
> every session. The merged runner owns the memo/DAG/recipe-execution; **octopus**
> inter-node comms stay as a concept, the sqlite-memo substrate does not. Do not extend
> it, and do not build completion/coordination detection on it.

**How it works now.** `ui_server.startRunner` no longer spawns a child
process. It launches the run **in a `worker_thread` inside the ui_server
process** (`pipeline/run_worker.js` → `pipeline_runner.main()`), so **one
OS process (one PID) serves the UI and runs the pipeline**.

- The runner code is **unchanged** except two backward-compatible edits:
  `pipeline_runner.coffee` now exports `main`, and resolves `CWD` from
  `env.CWD ?? process.cwd()` (a worker can't `chdir`; the spawn already
  set `env.CWD`, the bare CLI still falls back to `process.cwd()`).
- A worker's `process.exit(code)` **stops only the worker**, not the UI
  process, and surfaces as the Worker `'exit'` code — which maps straight
  onto the old `child.on('exit')` → `markUiRunExited` logic.
- **The blocking-compute worry is resolved by construction:** heavy MLX
  work runs on the worker thread, so the UI event loop stays live.
  `@frost-beta/mlx` loads + runs in a worker (probed), and the proof run
  kept the host loop ticking throughout.
- Single-run liveness is now the tracked `activeRunWorker` handle (the
  run's pid is the ui_server pid, so pid-grep can't tell); `/api/kill`
  does `worker.terminate()`; `findActiveWorkspaceRun` is worker-aware.

**Proven (laptop, 2026-10-26):** (1) a real recipe ran in-process via a
harness driving the exact worker path — host survived the worker's
`process.exit(0)`, event loop ticked 32× during the run, `ui-run.json`
pid == host pid; (2) end-to-end through the **real `ui_server`** —
`POST /api/launch` → `status:done` with pid == server pid, server alive
afterward. Harnesses: `~/claude_zone/test/compress_harness.js` +
`compress_pipe/`.

**Proven in production (2026-10-26):** synced to the mini and a real run
(real MLX generation) executed in the fused worker — jahbini confirmed it
"works perfectly." So the single-process model is live on the mini, not
just the laptop proof.

**NOT yet done (honest):**
- The **UI is an I/O device HANDLED BY the meta system** (jahbini's exact
  words: *"the UI is treated as an I/O device and is handled by the meta
  system of the pipeline's memo"*). The literal design: a `meta/ui`
  handler loaded by `metaLoader(M, …)` like `meta/sqlite`/`meta/yaml`,
  owning the UI I/O **end-to-end — serving included** — with `ipc/broker`
  + the memo as its underlying wire (not a reason to split the serving
  off into `ipc/`). NOT a carved device + separate transport.
- The **deeper "UI as a `meta/ui` device"** form (steps touch the UI
  through a meta request-key like `meta/sqlite`) is the fuller
  expression; the single-process requirement is met, the meta-device
  refactor is the next layer, not a blocker.

The rest of this doc (cross-host puppet/controller, leases, Stage B peer
read) is the MULTI-HOST layer and still stands — the fusion is **per
node**: each node's UI + its runner are now one process; a controller may
still drive remote nodes over the broker/SSH.

Rewritten 2026-10-22 on branch **`octopus`**. This **supersedes** the
2026-10-21 fable brainstorm, which inverted the intended design: it
pulled the broker/memo *out* into a standalone `switchboard` daemon and
kept the UI as a separate client, and argued *against* the UI hosting
the broker. That was wrong. The actual instruction — and what `octopus`
builds — is the opposite:

> **The puppeteer is a single long-lived process that fuses the UI and
> the memo/broker into one body, and drives writer pipelines — which are
> the exact same code, running their own UI — as puppets, passing the
> MQTT broker protocol between them over SSH.**

The standalone switchboard is **folded into the puppeteer**. "Being the
broker/memo host" is not a separate daemon; it is the **controller
role**, and it is **recursive** — any puppet that controls other
puppets takes that role for its own sub-flock.

## The vow

**One process is the puppeteer: it serves the UI, and it IS the broker
and the memo. Writers are the same program in the worker role; they
reach the puppeteer's broker as MQTT clients over SSH.** Everything
below falls out of taking that sentence seriously.

## Status at a glance (2026-10-25)

All `octopus`, **uncommitted** (never committed on these repos).

> **Session 2026-10-25 — Stage B peer-READ half is DONE + live on the
> mini (gated, default off).** Three pieces shipped and verified: (1) the
> hot peer probes (`probePeerStatus`/`pgrepPeerRunner` + the
> `handlePuppeteerStatus` strays) read a broker cache; (2) the writer
> puppet publishes `sys/pipe_inventory/<host>` and puppeteer reads it
> (the cross-host SSH sqlite scan is gone when fresh); (3) a Fleet
> toggle flips the `sys/peer_via_broker` gate. All built on the
> reactive-UI substrate with additive `ctx` (`ipcStatus`/
> `subscribeBroker`/`pipeInventory`), SSH kept as fallback throughout.
> Verified headlessly + synced to the mini. **This closes the peer-READ
> latency story. It does NOT finish Stage B** — the production cutover
> (writer launched as a supervised `ssh -R` puppet, not a standalone
> same-host process) and `peer_sessions` history still remain, and
> Stages C/D (concurrent fan-out, scheduler auto-fan-out) + flipping
> `mascot_schedule` are untouched. So: this slice ✅, the whole MARRIAGE
> ⏳.
>
> **Also verified live 2026-10-25 — laptop→mini still works, and SPAWNS.**
> A laptop puppeteer in SSH-poll mode (`UI_ROLE=puppet` to suppress the
> new supervisor, `PEER_LOCAL=0`, gate off) listed all 35 mini pipes and
> probed peer status over SSH, AND **spawned a pipe run on the mac-mini**
> — the pre-optimization laptop→mini workflow is intact (the peer-read
> changes stay inert with the gate off). Known gotcha (minor, not urgent):
> the **pipeline-graph pop-up needs a second recipe run to render right**
> the first time.

- **Stage A (fuse / controller)** — ✅ DONE + live on the mini. The
  puppeteer-ui IS the sole broker/memo host; standalone switchboard
  retired. Steal-the-socket bug fixed 2026-10-23.
- **Stage B (SSH-launch + MQTT/SSH)** — ✅ core done, smoke-tested
  laptop→mini. ✅ peer-probe migration done 2026-10-25 (gated on
  `sys/peer_via_broker`): `probePeerStatus`/`pgrepPeerRunner` + the hot
  `handlePuppeteerStatus` probes read a broker cache (presence +
  `runner/+/+/{state,lifecycle}`) with SSH fallback. ✅ **inventory
  publisher done 2026-10-25**: the writer puppet publishes
  `sys/pipe_inventory/<host>` (30 s local scan, shared
  `pipeline/ui/pipe_inventory.coffee`); puppeteer `peer_pipes` reads the
  snapshot, SSH fallback kept — the cross-host sqlite scan is gone when
  fresh. ✅ **operator gate toggle done 2026-10-25** (Fleet-controls
  "Peer: SSH ⇄ 📡 broker" button in `panels.js`, cross-tab synced).
  ⏳ production cutover (mini controller SUPERVISES the writer via
  `ssh -R` rather than standalone same-host) + `peer_sessions` history
  publisher pending.
- **Stage C (concurrent fan-out)** — ✅ visible toggle `sys/fleet_mode`,
  default serial; concurrent mode STAGES run-intents. ⏳ puppet-side
  launch + recursion proper pending.
- **Stage D (leases/fleet)** — ✅ lease substrate + runner GPU auto-hold
  proven live (2 runners); GPU arbiter unified on `mlx/gpu_claim`.
  ⏳ scheduler auto-fan-out pending.
- **Puppeteer decides restart (mascot)** — ✅ built + proven (diagnosis,
  no blind restart); scheduler consumption built but **gated off**
  (`mascot_schedule` default false). See the section below.

## The cast

### Puppeteer — one process: UI + broker + memo (the controller)

Today "puppeteer" is `pipeline/ui_server.coffee` + `puppeteer/ui/
project.coffee`, and the broker/memo is a *separate* `switchboard`
daemon (built 2026-10-21). `octopus` **fuses them**: the puppeteer
process hosts, in-process:

- the **UI** — HTTP, the `/api/events` SSE multiplex, `/api/memo/*`,
  the panels/plugin surface (unchanged in shape),
- the **Broker** — topic pub/sub, retained messages, RPC routing
  (`pipeline/ipc/broker.coffee`),
- the **Memo** — the sqlite kv store, single writer (CAS, history,
  notifications) (`pipeline/ipc/memo.coffee`).

Because the puppeteer is long-lived (launchd), the memo and retained
state are **always up** — the "memo at idle" goal the switchboard was
invented for is satisfied by the UI process itself being the host. The
old "two ui_servers would fight over the broker" worry is moot: only a
**controller** hosts a broker; writers are clients, not co-hosts.

### Writer puppet — the SAME code, its own UI, in the worker role

A writer pipe **looks exactly as it does today**: the same
`@jahbini/pipeline` stack, its own `ui/project.coffee` + `ui_server`,
its own runner, its own `state/`. Nothing about the writer changes
shape. What's new is only how it's *reached*: the writer's runner
attaches as a **broker client of its controlling puppeteer**, over an
SSH-tunneled MQTT connection, to:

- publish `runner/<host>/<pipe>/{state,step/*,event,lifecycle}`,
- serve step-side RPC (`L.memo.get/put`, progress keys, lease ops),
- `waitFor` its wake key (`ui/intent/<pipe>/next_recipe`).

The writer still owns its disk as the source of truth; the broker
connection is the additive pub/sub + RPC layer, exactly as today.

### The controller role is recursive (where the switchboard went)

There is no standalone switchboard. **Hosting a broker+memo is the
controller role**, and "puppeteer" is just the node currently playing
it at the top. A writer puppet may, in another context, control *other*
puppets — and when it does, it hosts its own broker+memo for that
sub-flock, becoming a puppeteer to them. So the topology is a **tree of
controllers**: each controller is one fused process (UI + broker + memo)
with puppets beneath it reached over MQTT/SSH; a puppet can be a leaf or
itself a controller one level down. Same code at every node; the role
is configuration, not a different program.

## Transport: MQTT frames, over SSH between hosts

The broker speaks the existing newline-JSON MQTT-style frame vocabulary
(`hello/sub/unsub/pub/req/res`, `+`/`#` topic wildcards, retained
messages). Transport:

- **Within a host** — the loopback unix socket (`state/runner.sock`),
  as now.
- **Across hosts** — the controller's broker socket is reached by a
  puppet over **SSH** (`ssh -L` forwarding the unix socket / loopback
  port, or an `ssh`-piped stream carrying the frames). SSH gives auth +
  encryption for free; the trust boundary stays loopback. This is the
  MQTT-over-SSH the instruction calls for, and it **replaces** both the
  unbuilt `proxy_handle` bridge and the puppeteer's current
  `execSync('ssh …')` poll (the 2–5 s event-loop stalls collapse into
  one persistent tunneled broker connection).

Memo keys stay host-local to each controller; a parent host-qualifies
on its own side (which tunnel the frame went down IS the namespace). No
cross-host key federation.

## What this corrects vs the 2026-10-21 brainstorm

| 2026-10-21 (wrong) | octopus (intended) |
|---|---|
| broker/memo = standalone `switchboard` daemon | broker/memo **folded into the puppeteer process** |
| `ui_server` = a broker *client* | the puppeteer **IS** the broker host |
| "UI hosting the broker is the worst option" | the UI process hosting the broker is **the point** (it's always up) |
| one resident runner **per pipe**, launchd ×N | writers **unchanged** — same code, own UI, reached over MQTT/SSH |
| switchboard is a distinct thing | switchboard = the **controller role**, recursive |

The 2026-10-21 `switchboard.coffee` daemon + `wire.coffee` client/host
election were a stepping stone. `octopus` reuses `broker.coffee` /
`memo.coffee` unchanged but **hosts them inside the puppeteer** rather
than a separate process, and retires the standalone daemon (its code
becomes the puppeteer's in-process controller module).

## What stays true (invariants carried forward)

- **Disk is authoritative.** Every node writes `state/` first; broker
  publishes fire after `fs.writeFileSync` returns. The broker is a view.
- **Runner liveness = socket state.** A puppet's death is its broker
  connection dropping at its controller, which republishes its lifecycle
  as `disconnected`; `exited` messages are best-effort.
- **The UI never speaks broker in the browser.** The puppeteer
  multiplexes to SSE; browser writes go over POST `/api/memo`.
- **Never kill a puppet mid-run.** Recycling is `restart_when_idle`.
- **Steps read operator keys at step boundaries only** — no mid-step
  preemption.

## Fleet mode + leases (unchanged goal, now hosted in the puppeteer)

Fleet mode still falls out: the puppeteer's memo holds
`sys/gpu_lease/<host>` and `sys/cpu_slots/<host>`; writer puppets
contend via CAS over their MQTT/SSH connection; one generates while the
rest park at a step boundary; CPU-side work overlaps. Leases carry a
heartbeat/TTL (holder refreshes `since`; waiters evict stale holders) —
crash-release is a prerequisite. The puppeteer page binds the retained
topics and is the fleet dashboard. `sys/freeze` +
`pipe/<pipe>/schedule/mem_ceiling` (UI_MEMO step 9) compose naturally;
`sys/freeze` is already enforced by `queue_run_ite`.

## Puppeteer decides restart — the mascot (added 2026-10-23)

Restart is a **scheduling decision owned by the controller**, not a
launchd `KeepAlive`: KeepAlive can't tell clean-finish from crash from
graduated/paused/out-of-work, and can't pick the next work. So the
puppeteer inspects WHY a puppet terminated and decides.

- `pipeline/ipc/puppet_supervisor.coffee` splits into (1) **transport
  liveness** (reconnect the `ssh -R` tunnel with backoff — NOT
  work-restart) and (2) **`attachLifecycle`** → on a terminal
  `runner/+/+/lifecycle` (exited/failed/disconnected) it de-dupes,
  **diagnoses**, records `pipe/<slug>/last_termination` in the memo,
  emits a `termination` event, and **never restarts**.
- `pipeline/ipc/mascot_diagnose.coffee` is the diagnosis: a **clean exit
  → `{done, wait}`** with no LLM; otherwise it routes to the **mascot =
  the helper LLM** (`HELPER_LLM_MODEL_DIR`) for `classify_failure` +
  `summarize_log` + `schedule` (→ a SCHEDULE_ACTION). Calls are
  **sequential** (never `Promise.all` — concurrent node-mlx gens hang).
- **One GPU arbiter.** The runner's GPU auto-hold and the mascot's
  `helper_llm.runCapability` both take the host-local **`mlx/gpu_claim`**
  file lock → generation and the mascot are mutually exclusive on the one
  GPU. The memo `sys/gpu_lease/<host>` is an **advisory write-through**
  (`via:gpu_claim`) for the dashboard only.
- **Reason enrichment.** `wire.coffee` reads `<CWD>/pipeline.json`
  `{status, by, reason}` at cleanup and attaches `{ok, reason}` to the
  exit lifecycle, so the mascot classifies real failures (proven:
  injected OOM → classify=oom 0.95, schedule=hospitalize).
- **Scheduler side — BUILT, GATED OFF.** `queue_run_ite` consumes the
  mascot recommendation on terminal failure (instead of always-hospital),
  gated by **`mascot_schedule` (default false)**. `applyMascotDecision`
  maps SCHEDULE_ACTION: `wait`→leave; `raise_ceiling`→stamp + re-queue
  ONCE; **`graduate`/`reject` NEVER auto-applied** → hospital + "human
  confirm"; else → hospital with intent in `needs_attention.hint`.
  Decision table unit-tested 7/7. **OPEN:** flip `mascot_schedule:true`
  in prod after watching real failures.

Rule: `puppeteer/GPT/rules/puppeteer_decides_restart.md`; detail in
`pipeline/GPT/ipc.md` "Stage D".

## Config: the `puppeteer` override → recorded in `experiment.yaml`

> ✅ Implemented in Stage A: `<CWD>/override/puppeteer.yaml` is in
> `resolveOverrideLayers`, and `ui_server` reads `role` + `ui_port` from
> the recorded `experiment.yaml` (defaulting to `puppet`/existing port
> when absent). The design below is the live contract, not a proposal.

Role and ports are **not** hardcoded (today they're the arbitrary 4300 /
4311 in each `project.coffee`'s `portDefault`). They come from a new
**`puppeteer` override layer**, which the runner already records into
`experiment.yaml` for free:

- `experiment.yaml` is the runner's **generated record** of the fully
  resolved config — `createExperimentObject` deep-merges
  `recipe + resolveOverrideLayers() + control_override`
  (`pipeline_runner.coffee`). Add `<CWD>/override/puppeteer.yaml` to the
  layer list and its block lands in `experiment.yaml` automatically.
- The override carries a top-level **`puppeteer:`** block — a node's
  role, its UI port, and (for a controller) the roster of puppets it
  starts over SSH with their assigned ports:

```yaml
# <project>/override/puppeteer.yaml
puppeteer:
  role: controller          # 'controller' (= puppeteer, hosts broker+memo+UI) | 'puppet'
  ui_port: 4300             # this node's HTTP/SSE UI port
  puppets:                  # controllers only: who to bring up over SSH
    - { host: mac-mini.local, user: theaiguy, base: ~/writer,  ui_port: 4311 }
    - { host: mac-mini.local, user: theaiguy, base: ~/notebookie, ui_port: 4312 }
```

Flow:
1. The pipeline_runner, restarting in a dir, merges this and writes it
   into `experiment.yaml` — the record of what this node is.
2. A **controller** reads `puppeteer.ui_port` (binds its UI there),
   hosts the in-process broker+memo, then for each `puppets[]` entry
   **SSH-launches that puppet** telling it which `ui_port` to use.
3. A **puppet** reads its `role: puppet` + `ui_port` (from the override
   the controller handed it) and comes up as a broker client over the
   SSH/MQTT link — otherwise it is the same writer UI as today.

So "which port" is never arbitrary: the controller's `puppeteer`
override is the single source of truth, propagated to each puppet at
SSH-launch. Recursion falls out — a puppet whose own `puppeteer`
override has `role: controller` + a `puppets:` roster becomes a
controller for its sub-flock.

## Migration order (each stage shippable alone)

> Numbering note: items 1–2 are **preludes** (the reactive wedge and the
> now-retired switchboard); the lettered **Stages A–D** are items 3–6
> respectively. Cross-references use the letters.

1. ✅ DONE 2026-10-21 (prelude). UI_MEMO/REFACTOR_MEMO wedge — memo endpoints, SSE,
   `/api/memo`, the first memo-backed panel, steps 7–9.
2. ✅ RETIRED 2026-10-23. The standalone `switchboard` daemon (2026-10-21)
   was a stepping stone; `octopus` folded it into the puppeteer. Now that
   Stage A is live, the standalone daemon is **gone** — the puppeteer-ui
   process is the sole broker/memo host on the mini.
3. ✅ DONE 2026-10-22 (branch `octopus`, live on the mini). **Stage A —
   config + fuse (the octopus core).**
   (a) **Config:** add `<CWD>/override/puppeteer.yaml` to
   `resolveOverrideLayers` so the `puppeteer:` block is recorded into
   `experiment.yaml`; `ui_server` reads `role` + `ui_port` from it at
   boot (replacing the hardcoded `portDefault`), defaulting to
   `puppet`/existing port when absent.
   (b) **Fuse:** when `role: controller`, the puppeteer process hosts
   the Broker + Memo in-process (reuse `broker.coffee` / `memo.coffee`;
   lift `switchboard.coffee`'s wiring into a controller module the
   `ui_server` starts). StatusSource + `/api/memo/*` talk to the
   in-process broker. Retire the standalone launchd `switchboard` job;
   the puppeteer-ui process becomes the sole broker host.
   - ✅ **Steal-the-socket bug fixed 2026-10-23.** A runner's
     `wire.coffee` election used to host on a 600ms probe timeout and
     `broker.coffee::listen()` unconditionally `unlinkSync`ed before bind
     — stealing `runner.sock` from under the live controller and killing
     the writer puppet's reactive UI. Fixed: `listen()` never steals a
     live socket (binds first, probes on EADDRINUSE, reclaims only a
     confirmed-stale file); `wire.coffee` retries a stalled probe and
     hosts only on definitive ECONNREFUSED/ENOENT. Recovery = `launchctl
     kickstart -k gui/<uid>/com.jahbini.puppeteer-ui` (puppets
     auto-reconnect). Detail: `pipeline/GPT/ipc.md` "Steal-the-socket".
4. **Stage B — SSH-launch + MQTT over SSH.** The controller reads its
   `puppets:` roster and **SSH-launches each puppet** with its assigned
   `ui_port`; the puppet's `wire.coffee` connects back as a broker
   client over the SSH tunnel. The puppeteer's `SshDispatcher` polls are
   replaced by broker RPC/subscriptions. Writers otherwise unchanged.
   - ✅ **CORE DONE 2026-10-23 (octopus), smoke-tested laptop→mini.**
     Built: `pipeline/ipc/puppet_supervisor.coffee` (controller keeps one
     supervised `ssh -R <remoteSock>:<brokerSock> … exec env … ui_server`
     per REMOTE puppet; reverse-forwards the broker onto the puppet host
     AND launches the puppet as a client over it; restart-on-exit with
     backoff; `status()`), `BROKER_CLIENT_ONLY` in `wire.coffee` (a puppet
     NEVER hosts — goes straight to client, infinite reconnect), ui_server
     wiring (controller starts the supervisor once the broker is
     listening; puppet heartbeats a retained `sys/presence/<host>` memo
     key; new `GET /api/puppets`). Smoke test (laptop Broker+Memo+supervisor
     → mini writer puppet on 4321): puppet `/api/ipc_health` returned
     `broker_connected:true` (StatusSource reached the laptop broker over
     the tunnel), `sys/presence/mac-mini` landed in the laptop memo, and
     `sup.stop()` killed the tunnel → puppet died (lifecycle coupling).
     Transport proven bidirectionally with `ssh -R` unix-socket forwarding
     (OpenSSH 10.x both hosts, `StreamLocalBindUnlink=yes`).
   - ✅ **Peer-probe migration DONE 2026-10-25 (gated, SSH fallback).**
     Added `ipcStatus` + `subscribeBroker(topic,cb)` to the plugin ctx
     (`pipeline/ui_server.coffee`, additive/behavior-neutral). The
     puppeteer plugin keeps a live `peerVia` cache — gate from
     `sys/peer_via_broker`, presence from `sys/presence/<host>`, runs from
     `subscribeBroker 'runner/+/+/{state,lifecycle}'` — and
     `SshDispatcher.{probePeerStatus,pgrepPeerRunner}` (plus the two stray
     `execSync` probes in `handlePuppeteerStatus`, now routed through the
     seam) read it when the gate is ON and a presence beat is < 90 s old,
     else fall back to SSH/curl. `peer_pipes` live-activity overlay is
     broker-backed for free (it reads probePeerStatus). Gate default OFF
     ⇒ byte-identical to before. Verified 3 scenarios in
     `~/claude_zone/test/stage_b_peer_via_broker.coffee`. Uncommitted;
     needs sync to mini. **The freshness check IS the local/remote gate:**
     on the mini the standalone writer is already a same-host broker
     client (shared `runner.sock`) so the cache fills NOW; on the laptop
     (no ssh -R tunnel yet) the cache stays empty → SSH fallback.
   - ⏳ **REMAINING for B:** (1) the **production cutover** — make the
     mini's resident puppeteer (role: controller) actually launch the
     writer as a supervised puppet (today it's a standalone same-host
     process on the local socket); (2) **the inventory half** —
     `peer_pipes`/`peer_sessions` filesystem+sqlite inventory
     (model/quant/kag/remaining, run history) still rides
     `SshDispatcher.bash`; the broker carries no such data, so replacing
     it needs a **puppet-side inventory publisher** writing memo snapshots
     (overlaps Stage C/D, resident-puppet); (3) a `panels.js` **toggle
     button** for `sys/peer_via_broker` (today: POST /api/memo/<key>).
5. **Stage C — recursion / concurrent fan-out.** Generalize "controller"
   so any node can host a broker+memo for sub-puppets; config decides a
   node's role(s).
   - ✅ **Concurrent fan-out DONE 2026-10-23 (octopus) — a VISIBLE TOGGLE,
     default = current serial behaviour.** Operator key `sys/fleet_mode`
     ('serial' | 'concurrent'); a Fleet-panel button (`panels.js`:
     serial ⇄ ⚡concurrent, cross-tab synced via the memo). `queue_run_ite`
     reads it at its dispatch boundary (`fleetMode()`, read-only peek,
     defaults serial on any error). 'serial' → the untouched single-pipe
     daemon. 'concurrent' → `dispatchConcurrent`. **Revised 2026-10-23 to
     obey "steps do no direct I/O" (jahbini caught the violation):** the
     first cut launched runners with raw `execSync ssh`; it now instead
     writes each eligible pipe's `ui/intent/<pipe>/next_recipe` memo key
     via `L.memoRequest` (broker/meta) — no ssh/fs/sqlite in the step. So
     concurrent mode **stages run-intents** (honors `sys/freeze` via meta;
     eligibility via the legacy `pipe_states` read); the **puppet side
     launches** them, parks on the GPU lease, and its termination flows
     back through the mascot path. `fleetMode` reads via meta. The
     puppet-side pickup — resident puppets on their wake key, or a
     `meta/remote` `launch_bg` tool on `pipe_server` (which today only has
     a single-pipe `launch`) — is the follow-on; until it lands,
     concurrent STAGES without launching. Verified: toggle memo round-trip,
     orchestration unit 7/7 (pre-revision), 2-runner GPU handoff live
     earlier (the eventual puppet mechanism). Left at default serial.
   - **Still-legacy direct-I/O in `queue_run_ite`** (pre-existing, NOT the
     octopus additions — the serial-scheduler migration follow-on, == Phase 0
     broker-lifecycle work): `isFleetFrozen`/`_readMemoValue` (direct sqlite
     peek of the memo), `readPipeStates`/`writePipeStates` (`pipe_states.json`
     direct fs — the whole serial path + `escalatePipeForHelp`/
     `applyMascotDecision`), `runEntry`'s `callPeer` (fetch) + `execSync`
     pgrep, `spawn_log` (sqlite). Migration = move `pipe_states` into the memo
     and route peer I/O + completion through `meta/remote` / the broker
     lifecycle. (The DONE octopus-side conformance — `fleetSshExec`/`fleetLaunch`/
     `recentSessionsFor` deleted, `fleetMode`/`dispatchConcurrent` via
     `L.memoRequest` — is the revision noted just above.)
   - ⏳ Recursion proper (a writer hosting a sub-flock) still future.
6. **Stage D — leases/fleet.** `L.lease`/`L.release` vocabulary + the
   GPU/CPU keys; fan-out dispatch becomes safe and concurrent.
   - ✅ **SUBSTRATE DONE 2026-10-23 (octopus).** `pipeline/ipc/lease.coffee`
     (`LeaseClient`: `acquireGpu`/`acquireCpuSlot` → self-heartbeating
     handle; CAS over the memo; **crash-release via 60s heartbeat TTL**;
     **CPU max 4** — the 2026-10-23 decision). `wire.coffee` exposes
     `ipc.memoRequest` (client→broker RPC / host→in-process, role-correct
     even over the ssh -R tunnel) + `ipc.lease` + `ipc.leaseHost`.
     Verified: lease logic 10/10 (direct memo), PASS over broker RPC,
     PASS from the `wireRunner` surface. Keys `sys/gpu_lease/<host>` +
     `sys/cpu_slots/<host>` (both already in memo `NOTIFIED`).
   - ✅ **GPU auto-lease WIRED + PROVEN LIVE with 2 concurrent runners
     2026-10-23.** The runner wraps `L.callLLM`: the first callLLM in a
     step lazily takes `sys/gpu_lease/<host>` and holds it to step end
     (released in `finish()`), so a pipe owns the GPU across its generate
     step and frees it before CPU steps. Zero recipe edits; no-broker →
     direct. Proof: 2 real runners on the mini (chat_llm, instance-guard
     skipped) — one held + generated while the other logged
     `waiting_gpu … waited_ms 6028→15050` (parked, no model load), then
     took the GPU on release. Exactly one holder, clean handoff.
   - ✅ **GPU arbiter UNIFIED on `mlx/gpu_claim` 2026-10-23.** The runner's
     auto-hold now takes the **same host-local `gpu_claim` file lock** the
     mascot's `helper_llm.runCapability` uses → generation and the mascot
     LLM are mutually exclusive on the one GPU. The memo
     `sys/gpu_lease/<host>` became an **advisory write-through**
     (`via:gpu_claim`) for the dashboard; `lease.coffee` still owns the CPU
     slots. (See the mascot section above.)
   - ⏳ **REMAINING for D — the scheduler auto-fan-out:** `queue_run_ite`
     is serial (PRE-ENTRY IDLE WAIT) AND the peer `/api/launch` does
     `switch_pipe` which KILLS the active runner — so concurrent fan-out
     is NOT a queue flag; it needs the peer to run N concurrent runners
     (the resident-puppet model — this overlaps Stage C). The lease
     capability is proven; the scheduler wiring is the open work.

## Risks, named

- **UI restart = broker restart.** Fusing means recycling the puppeteer
  drops the broker (and every puppet's connection). Mitigate: memo
  `rehydrate()` on boot (already exists); puppets auto-reconnect (2 s
  backoff already in `broker_client`); disk stays authoritative so a
  gap is a view-staleness, not data loss. Recycle only `restart_when_idle`.
- **SSH tunnel liveness.** A dropped tunnel = puppet goes dark; the
  controller must republish its lifecycle as `disconnected` on socket
  close and the puppet must re-establish the tunnel. `ServerAliveInterval`
  on the ssh side; broker_client backoff on reconnect.
- **Recursion depth / loops.** A controller tree must not cycle; a node
  is a puppet of at most one parent. Keep host-qualification one level.
- **Memory discipline + wake storms + launchd sprawl** — as before,
  but there is now no per-pipe launchd puppet to sprawl; writers are
  their existing jobs.

## Related

- `~/claude_zone/UI_MEMO.md` — the reactive-UI wedge (all nine steps
  done); its "Broker placement" question is answered here: the broker
  lives in the puppeteer process (the controller).
- `pipeline/GPT/ipc.md` — frame protocol, topic schema, memo semantics;
  `broker.coffee`/`memo.coffee` are reused unchanged, re-hosted.
- `pipeline/ipc/switchboard.coffee` — the superseded daemon; its wiring
  WAS lifted into the puppeteer's in-process controller module (Stage A,
  done) and the standalone job retired 2026-10-23.
- `puppeteer/GPT/rules/puppeteer_decides_restart.md` — restart is a
  controller decision; the mascot diagnoses every termination.
- `puppeteer/GPT/rules/{taskmasters_cooperate_no_kill,always_leave_pipeline_running}.md`
  — the resident-controller pattern promoted into architecture. In the fuse the
  UI service + DAG runner are cooperating taskmasters sharing memo + meta; there
  is no 'kill', lifecycle is STATE (the old "never kill a runner, only the UI"
  split-process rule was retired 2026-10-30).
