###
  gpu_claim.coffee — single-writer Metal claim
  ============================================

  Written 2026-09-25 as step 1 of the puppeteer→mini migration.

  The problem it exists to solve:
    Post-migration, both `queue_run_ite` (dispatching writer pipes to
    peer's MLX) and `helper_llm.createSession` (running the scheduling
    helper's own MLX) live on the same host. macOS Metal doesn't cleanly
    isolate multiple `nn.quantize` + `applyLoRA` mutating operations
    across concurrent processes — two overlapping `createSession` calls
    routinely produce `Received parameters not in model` crashes. See
    `~/puppeteer/scripts/helper_ab_probe.coffee` for the subprocess-per-
    probe workaround we've been using; this file lets us retire it.

  The rule:
    Any coffee code that is about to spawn an MLX subprocess (via
    session_api.createSession, `python -m mlx_lm`, or an mlex-node call)
    MUST first `claim()` the GPU. `claim()` writes a lockfile at a
    stable path with the caller's pid + tag + timestamp. If another
    caller already holds the lock AND its pid is still alive, the new
    caller waits. Stale locks (holder pid not alive) are stolen. On
    step end / process exit, the caller MUST `release()`.

  Location:
    Puppeteer scope (all pipes running under puppeteer share the same
    Metal device). Lock file lives at `<CWD>/state/gpu_claim.lock` — so
    the puppeteer itself controls the mutex, not each pipe. When the
    puppeteer runs on the laptop and pipes on the mini this file is
    still on the laptop; that's a limitation this file inherits and
    documents (see § Cross-machine caveat below).

  Cross-machine caveat:
    Until the puppeteer migration completes, the writer pipes running
    on the mini and the helper LLM running on the laptop use DIFFERENT
    Metal devices. This mutex is meaningless in that split. Once both
    are on the mini, it becomes the enforcement point. Callers should
    still `claim()` even in the split world — it's cheap and it's how
    we validate the design before flipping the topology.

  Usage:
    { claim, release, held_by } = require '@jahbini/pipeline/mlx/gpu_claim'
    ticket = await claim { tag: 'helper.schedule', timeoutMs: 30_000 }
    try
      # spawn MLX here
    finally
      release ticket

  If `timeoutMs` elapses without the lock coming free, `claim()` throws
  a `GpuClaimTimeout`. Callers decide whether to retry or escalate.
###

fs   = require 'fs'
path = require 'path'
os   = require 'os'

# Resolvable at runtime; puppeteer CWD wins when running under
# pipeline_runner, otherwise falls back to a per-user path.
LOCK_PATH = ->
  base = process.env.GPU_CLAIM_DIR ? path.join(process.env.HOME ? os.homedir(), 'puppeteer', 'state')
  path.join(base, 'gpu_claim.lock')

# Stale detection — a lock older than STALE_MS with no live pid is
# considered abandoned and gets stolen. 10 min is well beyond any
# legitimate single step; a 4B MLX inference tops out ~3 min.
STALE_MS = 10 * 60 * 1000

_readLock = ->
  p = LOCK_PATH()
  return null unless fs.existsSync(p)
  try
    JSON.parse fs.readFileSync(p, 'utf8')
  catch
    null

_writeLock = (obj) ->
  p = LOCK_PATH()
  fs.mkdirSync path.dirname(p), {recursive: true}
  fs.writeFileSync p, JSON.stringify(obj, null, 2), 'utf8'

_alive = (pid) ->
  return false unless typeof pid is 'number' and pid > 0
  try
    process.kill(pid, 0)
    true
  catch
    false

class GpuClaimTimeout extends Error
  constructor: (holder, waitedMs) ->
    super "gpu_claim timeout after #{Math.round(waitedMs/1000)}s (held by #{holder?.tag ? '?'} pid=#{holder?.pid ? '?'})"
    @name = 'GpuClaimTimeout'
    @holder = holder
    @waitedMs = waitedMs

# claim({tag, timeoutMs, pollMs}) — returns a ticket object.
#   tag       (required) short human-readable label for diagnostics.
#   timeoutMs (default 30000) how long to wait before throwing.
#   pollMs    (default 250) how often to check while waiting.
claim = ({tag, timeoutMs, pollMs} = {}) ->
  tag        ?= 'anonymous'
  timeoutMs  ?= 30000
  pollMs     ?= 250
  ticketId    = "#{Date.now()}-#{Math.floor(Math.random() * 1e9)}"
  waitStarted = Date.now()

  loop
    cur = _readLock()
    holderAlive = cur? and _alive(cur.pid)
    holderStale = cur? and not holderAlive
    holderOld   = cur? and (Date.now() - (cur.claimed_at ? 0)) > STALE_MS
    # 2026-09-25 — self-reentrance. If the current process already
    # holds the lock (from an outer runCapability / runFreeform),
    # return a non-owning "reentrant" ticket that release() ignores.
    # Prevents helper_llm → session_api → gpu_claim.claim from
    # deadlocking against its own prior claim. The outer holder's
    # release path is what actually clears the lock file.
    if cur? and cur.pid is process.pid
      return {reentrant: true, ticket_id: cur.ticket_id, tag: cur.tag}
    canTake     = (not cur?) or holderStale or holderOld

    if canTake
      claim =
        pid:        process.pid
        tag:        String(tag)
        ticket_id:  ticketId
        claimed_at: Date.now()
        host:       os.hostname()
      _writeLock claim
      # Race-check: re-read to make sure we didn't lose to a concurrent
      # claim. If the file we just wrote doesn't have our ticket_id,
      # someone else won — go back and wait.
      confirm = _readLock()
      if confirm?.ticket_id is ticketId
        return claim
      # else: lost the race, fall through to the wait

    waitedMs = Date.now() - waitStarted
    if waitedMs > timeoutMs
      throw new GpuClaimTimeout(cur, waitedMs)

    await new Promise (r) -> setTimeout r, pollMs

# release(ticket) — remove the lock if it's still ours. Safe to call
# multiple times or with a nil ticket. Reentrant tickets no-op — the
# outer holder's release is what clears the lock file.
release = (ticket) ->
  return unless ticket?.ticket_id
  return if ticket.reentrant   # 2026-09-25 — inner claim has no lock to release
  cur = _readLock()
  return unless cur?
  return unless cur.ticket_id is ticket.ticket_id
  try fs.unlinkSync LOCK_PATH() catch _ then null

# held_by() — {tag, pid, claimed_at, ...} of the current holder, or
# null if free. Diagnostic only; do NOT gate work on this — race with
# other claimers. Use claim() for gating.
held_by = -> _readLock()

module.exports = { claim, release, held_by, GpuClaimTimeout, LOCK_PATH }
