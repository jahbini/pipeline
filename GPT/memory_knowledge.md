# Memory knowledge — model residency, truthful telemetry, fit-gated dispatch

**Status: BUILT 2026-11-07, synced to mini, NOT yet active** (activates per
node as each fused node next restarts; no node was recycled for it — see
"Activation" below). Design approved by jahbini 2026-11-06/07:
*"idle puppet should be idle, and free the model from memory usage. IF it's
idle, it's not using, period"* + *"KEEP THE UI"*.

## The principle

A model is a GPU resource acquired for an ACTIVE run and released when the
run ends. An idle node holds NO model. The node itself never dies for
memory's sake — the UI/SSE/memo service persists at its ~50MB JS heap; the
MODEL is the thing evicted. Lifecycle is state, not SIGKILL
([[taskmasters-cooperate-no-kill]]).

## Why this exists (2026-11-06/07 incident, recorded in ~/claude_zone/BOOBOO.md)

1. A 4-day idle puppet (qwen3-8b) sat on 12.3GB of Metal memory — the
   session cache never evicts, so a loaded model lived as long as its node.
2. Fleet telemetry reported `process.memoryUsage().rss` — **blind to MLX**:
   model weights live in Metal unified memory, so a node holding 16GB shows
   ~50MB rss. Every memory panel and every `ps` diagnosis was structurally
   wrong.
3. The writer scheduler dispatched with zero memory knowledge, stacking an
   8B job on a saturated 16GB host → compression, swap, jetsam.
4. **The "embed memory leak" was a MISDIAGNOSIS.** The embed path disposes
   KV per chunk correctly. The real cause of the 16GB reembed footprint:
   `/Volumes/bigbig/models/Qwen/Qwen3-8B-Base-mlx4` holds **full-precision
   bf16 shards (15.6GB)** — the Oct 9 quantize failed (orphan `.tmp-*` dirs
   remain) and left raw-size weights under the `-mlx4` name. Lesson: **size
   a model by bytes on disk, never by its directory name.** That dir still
   needs a real re-quantize (or the pipe stays too-big-for-mini and the
   gate will keep skipping it).

## The mechanisms (all in code, grep the 2026-11-07 "memory knowledge" comments)

1. **True eviction** — `mlx/session_api.coffee` `session.destroy()` frees
   model weights + KV + Metal cache (old `dispose()` freed KV only).
   `mlx/llm_dispatch.coffee` `evictSessions()` destroys every cached
   session and empties the `sessions` Map. Registered on
   `global.__mlx_runtime` (+ `global.__mlx_mem` Metal stats) so UI code can
   report/evict without ever require'ing mlx into a model-less node.
2. **Run-end eviction** — `pipe_ui_runner.coffee`: `runRecipe` brackets
   every run; when the last active run ends, a grace timer
   (`MODEL_EVICT_GRACE_MS`, default 60s) fires `evictSessions()` if no new
   run started. Covers EVERY fused node — puppets AND the base
   writer/puppeteer nodes (the 2026-11-06 16GB landed in the BASE writer
   node because a /pipe/ deep-link ran elementary in-process there).
3. **Truthful telemetry** — `meta/ui.coffee` `/api/status` `memory` now
   carries `metal_active_mb`, `metal_peak_mb`, `model_sessions`. rss stays
   for the JS heap; Metal numbers are the model truth.
4. **Evict endpoint** — `meta/ui.coffee` `POST /api/evict_model`:
   non-destructive, keeps the node, next run reloads. Safe no-op (evicted:0)
   on nodes that never loaded a model.
5. **Reaper evicts models, never nodes** — `puppeteer/ui/project.coffee`
   `checkPuppetHealth` reads each puppet's Metal residency; idle with
   ≥256MB resident for 20 consecutive 15s probes (~5min) → POST
   /api/evict_model. The node is KEPT.
6. **Fit-gated dispatch** — `puppeteer/scripts/writer_scheduler_ite.coffee`
   calls `S.tools.model_footprint.fitsHost(pipeDir)` before each dispatch:
   sums the actual `*.safetensors` bytes of the dir that will load
   (override-layer `quantized_model_dir` → `model_dir`, first existing with
   config.json — same order the LLM steps resolve), requires
   `bytes×1.25 + 1.5GB ≤ 85% of os.totalmem()`, else skips with "TOO BIG
   FOR THIS HOST". Also asks idle puppets to shed resident models before
   dispatching (one model per host). Tool: `tools/model_footprint.coffee`
   (fs lives in the tool, not the step — CONVENTIONS fs-stinginess).
7. **GPU-lock exit fix** — `session_api`'s process-exit handler now only
   unlinks `gpu_claim.lock` if the lock's pid is its own (it used to unlink
   unconditionally, able to delete another process's claim).

## Invariants (acceptance)

- I1: an idle fused node reports `metal_active_mb` ≈ 0 and `model_sessions` 0.
- I2: ≤1 model resident per host while the scheduler drives.
- I3: the scheduler never dispatches a model that can't fit the host.
- I4: all memory decisions read Metal memory / bytes-on-disk, never rss or
  dir names.

## Activation

The code is live on disk (laptop + mini) but a fused node picks it up only
on its next restart. Nothing was restarted on 2026-11-07 — an 8b-base
reembed was mid-run in the mini's base writer node (pid 82952) and the
standing rule is no process actions without jahbini's go. To activate per
node when safe: recycle launchd jobs
(`launchctl kickstart -k gui/$(id -u)/com.jahbini.pipe-ui-{writer,puppeteer}`)
and let puppets lazy-respawn via `/api/ensure_puppet_pipe` (stop idle ones
via the puppeteer's `/api/stop_puppet`). Verify I1 afterward:
`curl :PORT/api/status | jq .memory`.
