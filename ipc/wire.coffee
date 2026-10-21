os   = require 'os'
path = require 'path'
net  = require 'net'
{Broker}       = require './broker'
{Memo}         = require './memo'
{BrokerClient} = require './broker_client'

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

  # Probe the socket: connects → a broker (switchboard) is live → client;
  # error (ECONNREFUSED/ENOENT) → nothing listening → host. A short
  # timeout forces host mode if the probe neither connects nor errors.
  probeDone = false
  finishProbe = (isLive) ->
    return if probeDone
    probeDone = true
    try probe.destroy() catch then null
    if isLive then becomeClient() else becomeHost()
  probe = net.connect sockPath
  probe.on 'connect', -> finishProbe true
  probe.on 'error',   -> finishProbe false
  setTimeout (-> finishProbe false), 600

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
    publish "#{base}/lifecycle", {phase:'exited', pid:process.pid, host, pipe, at:new Date().toISOString()}, true
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

  state

module.exports = {wireRunner}
