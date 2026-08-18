###
  resource_ledger.coffee — logical admission control
  =====================================================
  A dependency-free policy brain. Backends (hfchat, mlx, future
  mac-mini HTTP) consult it before starting work; it decides
  "run now" / "wait" / "reject" and calls the backend's
  `dispatch` when a slot opens up. Ignorant of Memo, of HTTP, of
  everything except pool and windowed limits.

  Estimation model
  ----------------
  A request declares `needs: {limitName: amount}` — currently
  `concurrent` (a pool of running slots) and `memory_mb` (a
  memory pool). Wall-clock latency is NOT a `needs:` entry; it
  is learned. Each `finish(id, {wallclock_seconds})` folds one
  sample into a per-(resource, owner) rolling mean (last N=20).
  A future submit that omits `wallclock_seconds` is stamped with
  the mean; before N samples exist, a per-resource seed value
  is used.

  Admission order
  ---------------
  Smallest-first. On every rescan (initial `submit` or a
  `finish`), waiters are sorted by total need (sum of `needs`
  values) and admitted in that order. Arrival time is a
  tiebreaker only. Rationale: a tiny request should not wait
  behind a huge one it can fit around. Deliberately NOT FIFO.

  Unique ids
  ----------
  Each `submit` gets its own `finish`. Ids are one-shot: a
  submit with an id that's already running or already finished
  rejects with `reject_duplicate_id` (never queues, never
  dispatches). Two pipeline steps cannot share an id.

  Duplicate finish or unknown-id finish is a no-op with a
  stderr warning.
###

class ResourceLedger
  constructor: (@clock = -> Date.now() / 1000) ->
    @resources    = {}   # name → {limits, windowed, seed, pool, history}
    @owners       = {}   # owner → {maxRunning, running}
    @waiting      = []   # queue: {id, owner, resource, needs, dispatch, submit_t, arrival}
    @running      = {}   # id → {owner, resource, needs, submit_t}
    @finished     = {}   # id → true (for duplicate detection)
    @latencies    = {}   # "resource|owner" → [seconds, ...]
    @ledger       = []
    @arrivalSeq   = 0
    @latencyMaxN  = 20

  addResource: (name, limits = {}, windowed = {}, seed = 10) ->
    @resources[name] =
      limits:   limits
      windowed: windowed
      seed:     seed
      pool:     {}         # limitName → borrowed amount (pool limits only)
      history:  []         # [{t, limitName, amount, id}]  (windowed only)
    for own limitName of limits
      unless windowed[limitName]?
        @resources[name].pool[limitName] = 0
    return

  setOwnerLimit: (owner, maxRunning) ->
    existing = @owners[owner] ? {running: 0}
    existing.maxRunning = maxRunning
    @owners[owner] = existing
    return

  # Rolling-mean wallclock for (resource, owner); seed if empty.
  learnedLatency: (resource, owner) ->
    key = "#{resource}|#{owner}"
    samples = @latencies[key] ? []
    if samples.length is 0
      return @resources[resource]?.seed ? 10
    sum = 0
    sum += s for s in samples
    sum / samples.length

  _recordLatency: (resource, owner, seconds) ->
    return unless typeof seconds is 'number' and isFinite(seconds) and seconds >= 0
    key = "#{resource}|#{owner}"
    @latencies[key] ?= []
    @latencies[key].push seconds
    excess = @latencies[key].length - @latencyMaxN
    @latencies[key].splice(0, excess) if excess > 0
    return

  _now: -> @clock()

  _pruneWindow: (resource) ->
    r = @resources[resource]
    return unless r?
    longest = 0
    for own _, secs of (r.windowed ? {})
      longest = secs if secs > longest
    return if longest is 0
    t = @_now()
    cutoff = t - longest
    r.history = r.history.filter (rec) -> rec.t >= cutoff
    return

  _windowUsage: (resource, limitName) ->
    r = @resources[resource]
    return 0 unless r?
    secs = r.windowed?[limitName]
    return 0 unless secs?
    cutoff = @_now() - secs
    used = 0
    for rec in r.history when rec.limitName is limitName and rec.t >= cutoff
      used += rec.amount
    used

  _poolUsage: (resource, limitName) ->
    (@resources[resource]?.pool?[limitName]) ? 0

  _capacityFor: (resource, limitName) ->
    @resources[resource]?.limits?[limitName]

  _fits: (resource, needs) ->
    r = @resources[resource]
    return false unless r?
    for own limitName, amount of (needs ? {})
      capacity = @_capacityFor resource, limitName
      return false unless capacity?
      used = if r.windowed[limitName]?
        @_windowUsage resource, limitName
      else
        @_poolUsage resource, limitName
      return false if used + amount > capacity
    true

  _needsExceedCapacity: (resource, needs) ->
    r = @resources[resource]
    return true unless r?
    for own limitName, amount of (needs ? {})
      capacity = @_capacityFor resource, limitName
      return true unless capacity?
      return true if amount > capacity
    false

  _borrow: (resource, needs) ->
    r = @resources[resource]
    t = @_now()
    for own limitName, amount of (needs ? {})
      if r.windowed[limitName]?
        r.history.push {t, limitName, amount, id: null}   # id filled by caller
      else
        r.pool[limitName] = (r.pool[limitName] ? 0) + amount
    return

  _release: (resource, running) ->
    r = @resources[resource]
    return unless r?
    for own limitName, amount of (running.needs ? {})
      unless r.windowed[limitName]?
        r.pool[limitName] = Math.max(0, (r.pool[limitName] ? 0) - amount)
    return

  _replaceWindowRecord: (resource, id, limitName, amount) ->
    r = @resources[resource]
    return unless r?
    for rec in r.history when rec.id is id and rec.limitName is limitName
      rec.amount = amount
    return

  _logEvent: (event, id, owner, resource, extras = {}) ->
    entry = {t: @_now(), event, id, owner, resource}
    for own k, v of extras
      entry[k] = v
    @ledger.push entry
    return

  _dispatch: (waiter) ->
    @running[waiter.id] =
      owner: waiter.owner
      resource: waiter.resource
      needs: waiter.needs
      submit_t: waiter.submit_t
    @owners[waiter.owner].running += 1
    @_borrow waiter.resource, waiter.needs
    # Stamp borrowed history records with the id (for later replace).
    r = @resources[waiter.resource]
    for rec in r.history when rec.id is null
      rec.id = waiter.id
    @_logEvent "start", waiter.id, waiter.owner, waiter.resource, needs: waiter.needs
    try waiter.dispatch() catch err
      console.error "[resource_ledger] dispatch threw for #{waiter.id}: #{err?.message ? err}"
    return

  _rescan: ->
    return if @waiting.length is 0
    totalNeed = (w) ->
      s = 0
      for own _, v of (w.needs ? {})
        s += v
      s
    # Sort by total-need asc, arrival asc.
    @waiting.sort (a, b) ->
      da = totalNeed(a); db = totalNeed(b)
      return da - db if da isnt db
      a.arrival - b.arrival
    # Iterate a copy of the ordering; admit whatever fits under owner quota.
    keep = []
    for waiter in @waiting
      ownerState = @owners[waiter.owner]
      canOwner   = ownerState.running < ownerState.maxRunning
      if canOwner and @_fits(waiter.resource, waiter.needs)
        @_dispatch waiter
      else
        keep.push waiter
    @waiting = keep
    return

  submit: (request) ->
    {id, owner, resource, needs, dispatch} = request
    if @running[id]? or @finished[id]?
      @_logEvent "reject_duplicate_id", id, owner, resource, needs: needs
      return "rejected"
    unless @resources[resource]?
      @_logEvent "reject_unknown_resource", id, owner, resource, needs: needs
      return "rejected"
    unless @owners[owner]?
      @_logEvent "reject_unknown_owner", id, owner, resource, needs: needs
      return "rejected"
    if @_needsExceedCapacity resource, needs
      @_logEvent "reject_impossible_needs", id, owner, resource, needs: needs
      return "rejected"

    submit_t = @_now()
    ownerState = @owners[owner]

    if ownerState.running < ownerState.maxRunning and @_fits(resource, needs) and @waiting.length is 0
      @_dispatch {id, owner, resource, needs, dispatch, submit_t, arrival: @arrivalSeq++}
      return "running"

    @waiting.push {id, owner, resource, needs, dispatch, submit_t, arrival: @arrivalSeq++}
    @_logEvent "queued", id, owner, resource, needs: needs
    @_rescan()
    if @running[id]? then "running" else "waiting"

  finish: (id, actuals = {}) ->
    running = @running[id]
    unless running?
      if @finished[id]?
        console.error "[resource_ledger] finish(#{id}) called twice — ignoring"
      else
        console.error "[resource_ledger] finish(#{id}) for unknown id — ignoring"
      return
    delete @running[id]
    @finished[id] = true
    @owners[running.owner].running -= 1

    if actuals.memory_mb?
      # Replace estimate in pool accounting (if pool) or window history.
      if @resources[running.resource]?.windowed?['memory_mb']?
        @_replaceWindowRecord running.resource, id, 'memory_mb', actuals.memory_mb
      else if running.needs?.memory_mb?
        r = @resources[running.resource]
        diff = actuals.memory_mb - running.needs.memory_mb
        r.pool.memory_mb = Math.max(0, (r.pool.memory_mb ? 0) + diff)
        running.needs = Object.assign({}, running.needs, memory_mb: actuals.memory_mb)

    @_release running.resource, running
    @_pruneWindow running.resource
    @_recordLatency running.resource, running.owner, actuals.wallclock_seconds

    @_logEvent "finish", id, running.owner, running.resource, actuals: actuals

    @_rescan()
    return

  report: ->
    out = {resources: {}, running: Object.keys(@running).length, waiting: @waiting.length}
    for own name, r of @resources
      @_pruneWindow name
      byLimit = {}
      for own limitName, capacity of (r.limits ? {})
        used = if r.windowed[limitName]?
          @_windowUsage name, limitName
        else
          @_poolUsage name, limitName
        byLimit[limitName] = {used, capacity}
      out.resources[name] = byLimit
    out

module.exports = ResourceLedger
