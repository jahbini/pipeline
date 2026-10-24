net  = require 'net'
os   = require 'os'
path = require 'path'
{spawn} = require 'child_process'
{EventEmitter} = require 'events'

# ── PuppetSupervisor — the controller side of MARRIAGE Stage B/C ────
#
# TWO responsibilities, kept strictly separate (decision 2026-10-23):
#
#  1. TRANSPORT LIVENESS (mechanical). For each REMOTE puppet it keeps a
#     long-lived `ssh -R` that reverse-forwards the controller's broker
#     onto the puppet host AND launches the puppet's ui_server as a
#     broker client over it. If that SSH/tunnel drops, the puppet is
#     simply unreachable, so we reconnect it with backoff. This is the
#     transport staying up — it is NOT "restarting the pipe's work".
#
#  2. WORK-TERMINATION → MASCOT DIAGNOSIS (judgement, NOT restart). When
#     a PIPE terminates (its runner reaches a terminal lifecycle —
#     exited / failed / disconnected), the supervisor does NOT blindly
#     relaunch it. A blind `KeepAlive`/restart loop is explicitly WRONG:
#     launchd (or a dumb loop) can't tell "finished cleanly" from
#     "crashed" from "graduated / paused / hospital / out of work", and
#     can't choose what to run next. Instead EVERY termination is sent
#     to the mascot (helper) LLM for a diagnosis + recommended action,
#     recorded to the memo, and emitted. The PUPPETEER's scheduler then
#     inspects that and decides. Restart is a scheduling decision, and
#     it belongs to the controller — never to launchd, never here.
#
# `diagnose(info) -> Promise<diagnosis>` and `memoPut(key,value) ->
# Promise` are injectable so the core is testable without the GPU; the
# default `diagnose` routes to the mascot via `./mascot_diagnose`.

sh = (s) -> "'" + String(s).replace(/'/g, "'\\''") + "'"

class PuppetSupervisor extends EventEmitter
  # opts:
  #   brokerSock, puppets:[{host,user,base,ui_port,pipeline?,coffee?,remote_sock?}]
  #   localHosts, onLog
  #   diagnose:  (info) -> Promise<diagnosis>   (default: mascot LLM)
  #   memoPut:   (key, value) -> Promise        (default: no-op)
  constructor: (@opts={}) ->
    super()
    @brokerSock = @opts.brokerSock
    @children   = new Map()      # key -> {puppet, proc, restarts, startedAt, lastExit, up}  (TRANSPORT only)
    @stopped    = false
    @_recentTerm = new Map()     # host/pipe -> ts, to de-dupe repeat lifecycle frames
    me = os.hostname().toLowerCase()
    @_local = new Set(['localhost','127.0.0.1','::1', me, me.split('.')[0]].concat(@opts.localHosts ? []).map (s) -> String(s).toLowerCase())
    @diagnose = @opts.diagnose ? @_defaultDiagnose.bind(@)
    @memoPut  = @opts.memoPut  ? (-> Promise.resolve())

  isRemote: (p) ->
    h = String(p.host ? '').toLowerCase().trim()
    return false unless h
    not @_local.has h

  _key: (p) -> "#{p.user ? os.userInfo().username}@#{p.host}:#{p.ui_port}"
  remoteSock: (p) -> p.remote_sock ? "/tmp/controller-broker-#{p.ui_port}.sock"

  launchCommand: (p) ->
    rsock    = @remoteSock p
    base     = p.base ? '~'
    pipeline = p.pipeline ? '~/pipeline'
    coffee   = p.coffee ? '/opt/homebrew/bin/coffee'
    env = ["RUNNER_SOCK=#{rsock}", "UI_ROLE=puppet", "UI_PORT=#{p.ui_port}", "UI_BIND_MODE=net", "BROKER_CLIENT_ONLY=1"].join ' '
    "cd #{base} && exec env #{env} #{coffee} #{pipeline}/ui_server.coffee net"

  sshArgs: (p) ->
    rsock = @remoteSock p
    dest  = "#{p.user ? os.userInfo().username}@#{p.host}"
    ['-tt', '-R', "#{rsock}:#{@brokerSock}", '-o','StreamLocalBindUnlink=yes', '-o','ExitOnForwardFailure=yes',
     '-o','BatchMode=yes', '-o','ServerAliveInterval=15', '-o','ServerAliveCountMax=3', dest, @launchCommand(p)]

  start: ->
    for p in (@opts.puppets ? [])
      if @isRemote p then @_spawn p
      else @_markLocal p
    @

  _markLocal: (p) -> @children.set @_key(p), {puppet:p, proc:null, local:true, up:true, restarts:0}

  # ── (1) TRANSPORT liveness: keep the SSH tunnel + puppet UI up. ─────
  # The exit handler reconnects the TUNNEL only. It never decides
  # anything about pipe WORK — that is handled by handleTermination via
  # the broker lifecycle, not by this process dying.
  _spawn: (p) ->
    return if @stopped
    key  = @_key p
    rec  = (@children.get key) ? {puppet:p, restarts:0}
    rec.proc = null; rec.up = false; rec.startedAt = Date.now()
    @children.set key, rec
    proc = spawn 'ssh', @sshArgs(p), {stdio:['ignore','pipe','pipe']}
    rec.proc = proc; rec.pid = proc.pid
    @_wireLogs key, proc
    graceTimer = setTimeout (=> rec.up = true), 2500
    proc.on 'exit', (code, sig) =>
      clearTimeout graceTimer
      rec.up = false
      rec.lastExit = {code, sig, at: Date.now()}
      return if @stopped
      # TRANSPORT reconnect only (not work-restart): the tunnel dropped,
      # so the puppet is unreachable; bring the link back with backoff.
      rec.restarts = (rec.restarts ? 0) + 1
      delay = Math.min 30000, 2000 * Math.pow(2, Math.min(rec.restarts, 4))
      @_log key, 'sys', "tunnel down code=#{code} sig=#{sig}; reconnect ##{rec.restarts} in #{delay}ms"
      rec.restartTimer = setTimeout (=> @_spawn p), delay
    proc.on 'error', (err) => @_log key, 'sys', "ssh spawn error: #{err?.message ? err}"
    @_log key, 'sys', "ssh -R up: #{@remoteSock(p)} -> #{@brokerSock}; puppet #{p.host}:#{p.ui_port}"
    rec

  # ── (2) WORK termination → mascot diagnosis (NO restart). ──────────
  # Called when a pipe's runner reaches a terminal lifecycle. Diagnoses
  # via the mascot, records `pipe/<slug>/last_termination`, emits
  # 'termination' for the scheduler — and does NOT relaunch. The
  # puppeteer's scheduler reads the recommendation and decides.
  handleTermination: (info={}) ->
    host = String(info.host ? 'local')
    pipe = String(info.pipe ? 'unknown')
    # De-dupe repeated lifecycle frames for the same death (broker may
    # replay retained + live). One diagnosis per termination within 10s.
    tag = "#{host}/#{pipe}"
    last = @_recentTerm.get tag
    now  = Date.now()
    if last and (now - last) < 10000
      return Promise.resolve null
    @_recentTerm.set tag, now
    slug = pipe.toLowerCase().replace(/[^a-z0-9_\-]/g, '-')
    key  = "pipe/#{slug}/last_termination"
    Promise.resolve(@diagnose(info)).then (diag) =>
      record = {host, pipe, phase: info.phase ? null, reason: info.reason ? null, lastStep: info.lastStep ? null, diagnosis: diag ? null, at: now}
      p = Promise.resolve(@memoPut(key, record)).catch -> null
      p.then =>
        @emit 'termination', record
        @_log tag, 'diag', "#{diag?.category ? 'n/a'} → recommend #{diag?.recommendation ? '(none)'} :: #{diag?.summary ? ''}"
        record
    .catch (err) =>
      @_log tag, 'diag', "diagnosis failed: #{err?.message ? err}"
      @emit 'termination', {host, pipe, phase: info.phase ? null, diagnosis: null, error: String(err?.message ? err), at: now}
      null

  # Subscribe to broker lifecycle terminal phases and route each to
  # handleTermination. `statusSource` is the controller's StatusSource
  # (its client carries `runner/+/+/lifecycle`). Non-terminal phases
  # (running) are ignored; the scheduler owns the restart decision.
  attachLifecycle: (statusSource) ->
    return unless statusSource?.client
    statusSource.client.subscribe 'runner/+/+/lifecycle', (topic, payload) =>
      phase = String(payload?.phase ? '')
      return unless phase in ['exited', 'failed', 'disconnected']
      parts = topic.split '/'   # runner/<host>/<pipe>/lifecycle
      @handleTermination {host: payload?.host ? parts[1], pipe: payload?.pipe ? parts[2], phase, reason: payload?.reason ? null}
    @

  # Default mascot diagnosis — lazy-require the helper LLM so the module
  # loads with no GPU/model dependency and stays unit-testable. Any
  # failure degrades to a null diagnosis (the scheduler still gets the
  # raw termination).
  _defaultDiagnose: (info) ->
    try
      mascot = require './mascot_diagnose'
      mascot.diagnose info
    catch err
      Promise.resolve {category: 'unknown', summary: "mascot unavailable: #{err?.message ? err}", recommendation: 'escalate'}

  _wireLogs: (key, proc) ->
    buf = {out:'', err:''}
    pump = (stream, name) =>
      proc[stream].on 'data', (chunk) =>
        buf[name] += chunk.toString 'utf8'
        loop
          nl = buf[name].indexOf '\n'
          break if nl < 0
          line = buf[name].slice 0, nl
          buf[name] = buf[name].slice nl + 1
          @_log key, name, line if line.trim().length
    pump 'stdout', 'out'; pump 'stderr', 'err'

  _log: (key, stream, line) ->
    try @opts.onLog? key, stream, line
    console.log "[puppet #{key}] #{stream}: #{line}"

  status: ->
    out = {}
    @children.forEach (rec, key) =>
      out[key] = {host: rec.puppet.host, ui_port: rec.puppet.ui_port, local: !!rec.local, up: !!rec.up, pid: rec.pid ? null, reconnects: rec.restarts ? 0, lastExit: rec.lastExit ? null, remote_sock: (if rec.local then null else @remoteSock(rec.puppet))}
    out

  stop: ->
    @stopped = true
    @children.forEach (rec) =>
      clearTimeout rec.restartTimer if rec.restartTimer
      try rec.proc?.kill 'SIGTERM'

module.exports = {PuppetSupervisor}
