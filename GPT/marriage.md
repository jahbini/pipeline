# MARRIAGE: the puppeteer is one process — UI + memo fused — driving same-shape writer puppets over MQTT/SSH

> **Canonical home: `pipeline/GPT/marriage.md`** (moved out of
> `~/claude_zone/` 2026-10-25 so the north-star lives in the repo,
> committed + cross-machine, per `CONVENTIONS.md`). Implementation detail
> lives in `[[ipc]]`; forward work is tracked in `~/claude_zone/TODO.md`.

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
- `puppeteer/GPT/rules/{never_kill_active_ui,always_leave_pipeline_running}.md`
  — the resident-controller pattern promoted into architecture.
