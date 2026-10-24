# ── LeaseClient — MARRIAGE Stage D (fleet leases over the memo) ─────
#
# CAS-based resource leases on the IPC memo, so N pipes can run
# concurrently and serialize only where they actually contend:
#
#   sys/gpu_lease/<host>   {holder, step, since, heartbeat, evicted?}
#   sys/cpu_slots/<host>   {max, held:[{pipe, since, heartbeat}]}
#
# Crash-release is NOT deferrable (MARRIAGE): a holder that dies mid-step
# would pin the GPU forever. So every lease carries a heartbeat; the
# holder refreshes it on an interval, and a waiter CAS-evicts a holder
# whose heartbeat is older than `ttl`. Everything rides the memo's
# compare-and-swap (`cas` → {ok:false,reason:'version_mismatch'} on a
# lost race, `if_version:0` = create-if-absent), so there is exactly ONE
# writer (the broker's memo) and no new primitive.
#
# Transport-agnostic: constructed with a `memoReq(op, args) -> Promise`
# that resolves the memo op result ({value,version,...} for get;
# {ok,version|reason} for cas; {ok} for del). In the runner that fn wraps
# StatusSource.memoRequest (broker RPC, possibly over the ssh -R tunnel);
# in tests it can wrap a local Memo directly.

sleep = (ms) -> new Promise (resolve) -> setTimeout resolve, ms

class LeaseClient
  # opts: {ttl=60000, pollMs=1500, hbMs=ttl/3, who='lease'}
  constructor: (@memoReq, opts={}) ->
    @ttl    = opts.ttl    ? 60000
    @pollMs = opts.pollMs ? 1500
    @hbMs   = opts.hbMs   ? Math.max(5000, Math.floor(@ttl / 3))
    @who    = opts.who    ? 'lease'
    @_now   = opts.now    ? (-> Date.now())

  _get: (key)                 -> @memoReq 'get', {key}
  _cas: (key, value, ifVer)   -> @memoReq 'cas', {key, value, if_version: ifVer, who: @who}
  _del: (key)                 -> @memoReq 'del', {key}

  # ── GPU: one exclusive holder per host ────────────────────────────
  # Returns a handle {key, holder, release()} once acquired, or throws
  # on timeout. Starts a heartbeat that keeps the lease fresh until
  # release(). `onWait(info)` (optional) is called each poll while parked.
  acquireGpu: (key, holder, step='', {timeoutMs, onWait}={}) ->
    deadline = if timeoutMs then @_now() + timeoutMs else null
    loop
      throw new Error "gpu_lease_timeout:#{key}" if deadline and @_now() > deadline
      cur = await @_get key
      now = @_now()
      got = null
      if not cur?.value?
        r = await @_cas key, {holder, step, since: now, heartbeat: now}, 0
        got = r if r?.ok
      else
        v = cur.value
        age = now - (v.heartbeat ? v.since ? 0)
        if v.holder is holder
          r = await @_cas key, {holder, step, since: (v.since ? now), heartbeat: now}, cur.version
          got = r if r?.ok
        else if age > @ttl
          # Dead holder — evict by CAS'ing over the exact version we read.
          r = await @_cas key, {holder, step, since: now, heartbeat: now, evicted: v.holder}, cur.version
          got = r if r?.ok
        else
          onWait? {key, holder: v.holder, step: v.step, age}
      if got
        return @_makeHandle key, holder, 'gpu'
      await sleep @pollMs

  # ── CPU: up to `max` concurrent slot-holders per host ─────────────
  acquireCpuSlot: (key, pipe, max=4, {timeoutMs, onWait}={}) ->
    deadline = if timeoutMs then @_now() + timeoutMs else null
    loop
      throw new Error "cpu_slot_timeout:#{key}" if deadline and @_now() > deadline
      cur = await @_get key
      now = @_now()
      got = null
      if not cur?.value?
        r = await @_cas key, {max, held: [{pipe, since: now, heartbeat: now}]}, 0
        got = r if r?.ok
      else
        v    = cur.value
        cap  = v.max ? max
        live = (v.held ? []).filter (h) => (now - (h.heartbeat ? h.since ? 0)) <= @ttl
        mine = live.find (h) -> h.pipe is pipe
        if mine
          mine.heartbeat = now
          r = await @_cas key, {max: cap, held: live}, cur.version
          got = r if r?.ok
        else if live.length < cap
          live.push {pipe, since: now, heartbeat: now}
          r = await @_cas key, {max: cap, held: live}, cur.version
          got = r if r?.ok
        else
          onWait? {key, held: live.length, max: cap}
      if got
        return @_makeHandle key, pipe, 'cpu'
      await sleep @pollMs

  # ── handle: heartbeat loop + release ──────────────────────────────
  _makeHandle: (key, who, kind) ->
    released = false
    beat = =>
      return if released
      try
        cur = await @_get key
        return unless cur?.value?
        if kind is 'gpu'
          return unless cur.value.holder is who         # we were evicted — stop
          await @_cas key, Object.assign({}, cur.value, {heartbeat: @_now()}), cur.version
        else
          held = cur.value.held ? []
          mine = held.find (h) -> h.pipe is who
          return unless mine                             # our slot was reclaimed
          mine.heartbeat = @_now()
          await @_cas key, Object.assign({}, cur.value, {held}), cur.version
      catch then null
    timer = setInterval (-> beat()), @hbMs
    if timer.unref then timer.unref()
    release = =>
      return if released
      released = true
      clearInterval timer
      try
        cur = await @_get key
        return unless cur?.value?
        if kind is 'gpu'
          await @_del key if cur.value.holder is who     # only drop a lease we still hold
        else
          held = (cur.value.held ? []).filter (h) -> h.pipe isnt who
          await @_cas key, Object.assign({}, cur.value, {held}), cur.version
      catch then null
    {key, holder: who, kind, release}

module.exports = {LeaseClient}
