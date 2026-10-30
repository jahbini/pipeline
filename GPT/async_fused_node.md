# Async discipline in the fused node — one event loop, no blocking

**Rule (uniform):** In the fused node (`pipe_ui_runner.coffee` + `meta/ui`), the
UI service and the DAG runner are two cooperating taskmasters sharing ONE event
loop (see `puppeteer/GPT/rules/taskmasters_cooperate_no_kill.md`). Therefore
**in-process code must never block the loop** — no synchronous `child_process`
(`execSync` / `execFileSync` / `spawnSync`) and no synchronous sleep
(`Atomics.wait`). Every subprocess call and every wait is an **awaited async
primitive**. A blocking call freezes the never-dying UI for its whole duration —
exactly what the 2026-10-30 `download_model` `git lfs pull` did (the browser saw
`/api/status` return HTTP 000; Safari rendered it as "connection lost" /
"access control checks").

## Why not a worker / why not "just spawn the step"
JavaScript cannot yield a synchronous call in-process — the only ways to keep the
single loop free while a step waits are (a) make the step's blocking calls async
and `await` them, or (b) run the step off-thread/process. (b) breaks the
in-process shared memo (worker threads don't share JS objects; a child process
loses direct memo access) — the whole point of the fuse. So the answer is (a):
**async primitives + await.**

## The reference pattern (copy this into any step that shells out)
New-style steps are location-anonymous (no path-relative requires into pipeline
internals — see `CONVENTIONS.md`), so each step defines its OWN tiny async
helpers. Canonical form, as converted in `scripts/model/download_model.coffee`:

```coffee
sleep = (ms) -> new Promise (resolve) -> setTimeout resolve, ms

run = (cmd, args, cwd = null, extraEnv = {}) ->   # was cp.execFileSync
  env = Object.assign {}, process.env, extraEnv
  new Promise (resolve, reject) ->
    child = cp.spawn cmd, args, { cwd, stdio: 'inherit', env }
    child.on 'error', reject
    child.on 'exit', (code, signal) ->
      return resolve() if code is 0
      reject new Error "#{cmd} exited #{code ? signal}"
```

Then `await run(...)` / `await sleep(...)` everywhere. The step's `@step.action`
auto-compiles to `async function` (CoffeeScript detects the `await`), and BOTH
runners already await it: legacy `pipeline_runner.coffee:1954`
`Promise.resolve(step.action(...)).then(finish)`, and the fused `runStep` the
same way. Error semantics are preserved — a rejected `run` throws into the step's
`try/catch`, and a final re-throw reaches the runner's `pp.catch → finish(false)`.

Proof it works: `~/claude_zone/test/async_run_probe.coffee` spawns a 1s
subprocess through this `run` while a 100ms timer ticks — 9 ticks fire DURING the
subprocess (old `execFileSync` = 0 ticks, fully blocked).

## Status (2026-10-30)
- ✅ `scripts/model/download_model.coffee` — converted (`run`/`runSh`/`sleep`
  async; 4 git calls + the 10-min retry backoff now `await`ed). This was the sole
  synchronous-exec offender in the `newborn` pipeline. Synced to mini (runs under
  both legacy + fused). Step scripts are read per-run — no node restart needed.
- ✅ `Memo::callMLX` in `pipe_ui_runner.coffee` — CONVERTED 2026-10-30 (jahbini
  asked for it directly). Now `async callMLX`: the hand-rolled sync busy-wait +
  lockfile is replaced by the real async `mlx/gpu_claim` `claim()`/`release()`
  (which yields the loop while waiting, and also gains stale-stealing +
  reentrance + the write-race check + a loud `GpuClaimTimeout`), and the MLX
  subprocess runs through the module-level async `execAsync` instead of
  `spawnSync`. The ledger wrapper needed no change — it already returns the memo
  call (mirrors the async `callLLM` wrapper). Still has **no live callers** (MLX
  generation goes through `callLLM` → `mlx/llm_dispatch`; `quantize_model` uses
  that), so the real python/MLX path couldn't be exercised; the GPU-mutex +
  async-exec + release PLUMBING was proven in isolation by
  `~/claude_zone/test/callmlx_plumbing_probe.coffee` (claims, runs a subprocess
  with 10 timer-ticks firing during it, releases the lock cleanly). The one
  untested bit is `res.code`/`res.stderr` handling on a real mlx_lm failure —
  behavior-identical to the old `res.status`/`res.stderr`.
- `execAsync(cmd, args, opts)` + `delay(ms)` are now module-level helpers in
  `pipe_ui_runner.coffee` — the blessed async subprocess/sleep primitives for the
  fused core. (Step scripts still define LOCAL helpers per the location-anonymous
  rule; `execAsync` resolves `{stdout, stderr, code}` and never rejects on nonzero
  exit — the caller inspects `code`.)
- NOTE: the callMLX change is loaded at node STARTUP, so it activates on the next
  node restart; because callMLX is dormant (no callers) there's no behavioral
  difference until a callMLX step exists. Synced to mini + compiles.

Fs-level sync (`fs.rmSync` in download_model's dir cleanup) is left as-is: local,
fast, not a subprocess; convert to `fs.promises.rm` only if a huge-dir removal
becomes a visible stall.
