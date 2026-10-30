os   = require 'os'
path = require 'path'
net  = require 'net'
fs   = require 'fs'
{Broker}       = require './broker'
{Memo}         = require './memo'
{BrokerClient} = require './broker_client'
# (The worker_thread/parentPort UI mirror was removed 2026-10-30 with the
# legacy fuse — the fused node (pipe_ui_runner.coffee) is one process with an
# in-process memo + meta/ui, so there is no main-thread UI to mirror to.)

# Additive wiring: the runner publishes state/step/event/lifecycle
# AFTER each disk write (disk stays authoritative — publishes fire only
# once the existing fs.writeFileSync returns).
#
# Broker placement (2026-10-21): if a standalone switchboard daemon is
# already listening on the socket, the runner attaches as a CLIENT and
# publishes through it — the daemon owns the Memo + RPC handlers, so
# memo keys and retained state survive across runner restarts and the
# UI seam works at idle. If no daemon is present, the runner falls back
# to HOSTING its own in-process broker + memo (the legacy behaviour),
# so a lone runner still works. Election is by probe: connect to the
# socket — if something answers, be a client; otherwise host.

DEFAULT_SOCK = process.env.RUNNER_SOCK ? "#{process.env.HOME}/pipeline/state/runner.sock"
DEFAULT_MEMO = process.env.MEMO_DB ? "#{process.env.HOME}/pipeline/state/memo.sqlite"

derivePipe = (cwd) ->
  # Common layout: .../pipes/<pipe>/<run-dir>. Fall back to basename of CWD.
  parts = cwd.split path.sep
  i = parts.lastIndexOf 'pipes'
  return parts[i+1] if i >= 0 and parts[i+1]
  path.basename cwd

wireRunner = (S, U, opts={}) ->
  host = opts.host ? os.hostname().split('.')[0]
  pipe = opts.pipe ? derivePipe (opts.cwd ? process.cwd())
  base = "runner/#{host}/#{pipe}"
  sockPath = opts.sockPath ? DEFAULT_SOCK
  memoPath = opts.memoPath ? DEFAULT_MEMO

  state = {broker:null, memo:null, client:null, host, pipe, base, mode:'pending'}

  # Publish abstraction. Patches below call publish(); until the probe
  # decides host-vs-client the publishes queue, then flush in order.
  pubFn = null
  queue = []
  publish = (topic, payload, retain=true) ->
    if pubFn then pubFn topic, payload, retain
    else queue.push [topic, payload, retain]
  flush = ->
    pending = queue
    queue = []
    pubFn t, p, r for [t, p, r] in pending

  becomeClient = ->
    return unless state.mode is 'pending'
    state.mode = 'client'
    try
      state.client = new BrokerClient(sockPath, "runner-#{process.pid}", 'runner')
      state.client.connect().catch -> null
    catch err
      console.error "[ipc] client attach failed, hosting instead: #{err?.message ? err}"
      state.mode = 'pending'
      return becomeHost()
    pubFn = (topic, payload, retain) ->
      try state.client.publish topic, payload, retain
      catch err then console.error "[ipc] client publish #{topic} failed: #{err?.message ? err}"
    flush()
    console.log "[ipc] runner attached as broker CLIENT at #{sockPath} (switchboard present)"

  becomeHost = ->
    return unless state.mode is 'pending'
    state.mode = 'host'
    try
      state.broker = new Broker(sockPath).listen()
    catch err
      console.error "[ipc] broker failed to listen: #{err?.message ? err}"
      pubFn = -> null   # no broker; disk stays authoritative
      flush()
      return
    try
      state.memo = new Memo(memoPath, state.broker)
      state.memo.installHandlers()
      n = state.memo.rehydrate()
      console.log "[ipc] runner is broker HOST at #{sockPath}; memo rehydrated #{n} key(s) (no switchboard)"
    catch err
      console.error "[ipc] memo init failed: #{err?.message ? err}"
    pubFn = (topic, payload, retain) ->
      try state.broker.publish topic, payload, retain:retain
      catch err then console.error "[ipc] publish #{topic} failed: #{err?.message ? err}"
    flush()

  # Puppet / Stage-B mode: this runner is explicitly a CLIENT of a remote
  # controller's broker reached over an ssh -R tunnel (RUNNER_SOCK points
  # at the reverse-forwarded socket). It must NEVER host — hosting would
  # fork a local island and (with StreamLocalBindUnlink) fight the tunnel.
  # broker_client already reconnects forever (2s backoff) if the tunnel
  # isn't up yet, so skip the probe and attach as a client outright.
  clientOnly = opts.clientOnly ? (String(process.env.BROKER_CLIENT_ONLY ? '') in ['1','true','yes'])
  becomeClient() if clientOnly

  # Probe the socket for a live broker (the resident controller, normally).
  #   connect            → a broker is live → CLIENT.
  #   ECONNREFUSED/ENOENT → nothing is listening → HOST (legacy lone runner;
  #                         broker.listen() safely reclaims any stale file).
  #   neither (slow accept) → a resident controller may just be busy. Do
  #                         NOT host — that is how a transiently-stalled
  #                         controller used to get its socket stolen. Retry
  #                         with backoff; only host after MAX_PROBE misses.
  probeDone = false
  attempt   = 0
  MAX_PROBE = 5
  PROBE_MS  = 800
  finishProbe = (decision) ->          # 'client' | 'host'
    return if probeDone
    probeDone = true
    if decision is 'client' then becomeClient() else becomeHost()
  tryProbe = ->
    return if probeDone
    attempt += 1
    probe   = net.connect sockPath
    settled = false
    done = (fn) ->
      return if settled
      settled = true
      try probe.destroy() catch then null
      fn()
    again = -> if attempt >= MAX_PROBE then finishProbe 'host' else setTimeout tryProbe, 300
    probe.on 'connect', -> done -> finishProbe 'client'
    probe.on 'error', (err) ->
      code = err?.code
      done ->
        if code is 'ECONNREFUSED' or code is 'ENOENT'
          finishProbe 'host'           # definitively nothing listening
        else
          again()                      # transient — retry, never host yet
    setTimeout (-> done again), PROBE_MS
  tryProbe() unless clientOnly

  # Advertise lifecycle immediately (queued until the probe resolves).
  publish "#{base}/lifecycle", {phase:'running', pid:process.pid, host, pipe, since:new Date().toISOString()}, true

  # ── Patch StepStateStore.write / delete ──────────────────
  origWrite = S.write.bind(S)
  S.write = (n, obj) ->
    payload = origWrite n, obj
    publish "#{base}/step/#{n}", payload, true
    publish "#{base}/step/current", {step:n, status:payload.status, done:payload.done, at:payload.updated_at}, true
    payload

  origDelete = S.delete.bind(S)
  S.delete = (n) ->
    ok = origDelete n
    publish "#{base}/step/#{n}", null, true if ok
    ok

  # ── Patch ui recorder ────────────────────────────────────
  if U
    origSaveRun = U.saveRun.bind(U)
    U.saveRun = (payload) ->
      row = origSaveRun payload
      publish "#{base}/state", row, true
      row

    origEvent = U.event.bind(U)
    U.event = (payload) ->
      row = origEvent payload
      publish "#{base}/event", row, false
      row

  cleaned = false
  cleanup = ->
    return if cleaned
    cleaned = true
    # Enrich the terminal lifecycle with the OUTCOME so the mascot can
    # diagnose a real failure instead of a bare "exited". The runner
    # writes <CWD>/pipeline.json {status, by, reason} on a shutdown/fail;
    # read it (best-effort) and carry {ok, reason} on the exit frame.
    outcome = {ok: true, reason: null, by: null}
    try
      sj = path.join (opts.cwd ? process.cwd()), 'pipeline.json'
      if fs.existsSync sj
        rec = JSON.parse fs.readFileSync(sj, 'utf8')
        if rec? and (rec.status is 'shutdown' or rec.status is 'failed' or rec.failed is true)
          outcome = {ok: false, reason: String(rec.reason ? rec.by ? 'failed'), by: (rec.by ? null)}
    catch then null
    publish "#{base}/lifecycle", {phase:'exited', ok:outcome.ok, reason:outcome.reason, by:outcome.by, pid:process.pid, host, pipe, at:new Date().toISOString()}, true
    try state.memo?.close()
    try state.client?.close()
    try state.broker?.close()

  # 'beforeExit' fires while the event loop can still flush socket
  # writes, so the 'exited' publish has a chance of arriving. The 'exit'
  # hook is a last resort whose writes usually don't flush — consumers
  # must treat socket close as the real death signal (status_source),
  # never this message. (When a switchboard hosts the broker, the
  # runner's death is its client socket dropping at the daemon, not a
  # close the ui_server sees directly — runner-death republish is a
  # future switchboard refinement; see MARRIAGE.md.)
  process.on 'beforeExit', -> try cleanup()
  process.on 'exit', -> try cleanup()

  # ── octopus Stage D: memo access + fleet leases for step code ─────
  # A single memoRequest(op,args) that works in BOTH broker roles: a
  # CLIENT routes through the broker RPC (the controller's single-writer
  # memo — correct even over the ssh -R tunnel); a HOST calls its own
  # in-process memo directly. Steps MUST use this, never a direct sqlite
  # write, so version numbers + notifications stay coherent (UI_MEMO).
  # Waits out the brief election window before dispatching.
  waitReady = ->
    return Promise.resolve() unless state.mode is 'pending'
    new Promise (resolve) ->
      tries = 0
      iv = setInterval (->
        if state.mode isnt 'pending' or ++tries > 60
          clearInterval iv
          resolve()
      ), 50
  state.memoRequest = (op, args={}) ->
    await waitReady()
    who = args.who ? pipe
    if state.mode is 'client' and state.client
      state.client.request "runner/#{host}/#{pipe}/meta/sqlite/req", Object.assign({op}, args)
    else if state.memo
      m = state.memo
      switch op
        when 'get'        then m.get args.key
        when 'get_prefix' then m.getPrefix args.prefix, (args.limit ? 1000)
        when 'put'        then m.put args.key, args.value, who
        when 'cas'        then m.cas args.key, args.value, args.if_version, who
        when 'del'        then m.del args.key
        else throw new Error "unknown_op:#{op}"
    else
      throw new Error 'no_memo'
  try
    {LeaseClient} = require './lease'
    # 60s TTL + heartbeat (crash-release); CPU default 4 slots. These are
    # the fleet knobs from MARRIAGE Stage D / the 2026-10-23 decision.
    state.lease = new LeaseClient state.memoRequest, {ttl:60000, who:pipe}
    state.leaseHost = host
  catch err
    console.error "[ipc] lease client unavailable: #{err?.message ? err}"

  state

module.exports = {wireRunner}
