net = require 'net'
{EventEmitter} = require 'events'
{matches} = require './broker'

# Reusable client for the pub/sub + RPC broker in `./broker`.
# Auto-reconnect (2s backoff). Subscribe/publish/request API. A no-op
# `'error'` listener is attached at construct time so a missing socket
# (common when the runner isn't up) doesn't crash the UI server via
# EventEmitter's "unhandled error" semantics. UIs consume this via
# `./status_source`, which falls back to disk reads while disconnected.

class BrokerClient extends EventEmitter
  constructor: (@sockPath, @client_id, @role='ui') ->
    super()
    @subs    = new Map()      # filter -> Set<fn>
    @pending = new Map()      # reqid -> {resolve, reject, timer}
    @buf     = ''
    @nextReq = 0
    @connected = false
    @_closed   = false
    # Default no-op 'error' listener so a disconnected socket (common
    # when the runner isn't up) doesn't crash the UI server via
    # EventEmitter's "unhandled error" semantics. Callers can still
    # add their own listeners.
    @on 'error', ->  null

  connect: ->
    new Promise (resolve, reject) =>
      done = false
      @sock = net.createConnection @sockPath, =>
        @connected = true
        @_write {t:'hello', client_id:@client_id, role:@role}
        @subs.forEach (fns, f) => @_write {t:'sub', topic:f}
        unless done then done = true; resolve @
        @emit 'connect'
      @sock.on 'data',  (c) => @_onData c
      @sock.on 'error', (e) =>
        @emit 'error', e
        unless done then done = true; reject e
      @sock.on 'close', =>
        @connected = false
        @emit 'close'
        return if @_closed
        # Silent reconnect-forever — status_source.getRun() returns
        # null while disconnected so the UI falls back to disk reads.
        setTimeout (=> @connect().catch ->), 2000

  close: ->
    @_closed = true
    try @_write {t:'bye'}
    try @sock?.end()

  subscribe: (filter, fn) ->
    set = @subs.get(filter) ? new Set()
    first = set.size is 0
    set.add fn
    @subs.set filter, set
    @_write {t:'sub', topic:filter} if first and @connected

  unsubscribe: (filter, fn) ->
    set = @subs.get filter
    return unless set
    set.delete fn
    if set.size is 0
      @subs.delete filter
      @_write {t:'unsub', topic:filter} if @connected

  publish: (topic, payload, retain=false) ->
    @_write {t:'pub', topic, payload, retain}

  request: (topic, payload, timeoutMs=5000) ->
    reqid = "r#{++@nextReq}"
    new Promise (resolve, reject) =>
      timer = setTimeout (=>
        @pending.delete reqid
        reject new Error 'rpc_timeout'
      ), timeoutMs
      @pending.set reqid, {resolve, reject, timer}
      @_write {t:'req', topic, reqid, payload}

  _write: (m) ->
    return unless @sock
    try @sock.write JSON.stringify(m) + '\n'
    catch then null

  _onData: (chunk) ->
    @buf += chunk.toString 'utf8'
    loop
      nl = @buf.indexOf '\n'
      break if nl < 0
      line = @buf.slice 0, nl
      @buf = @buf.slice nl + 1
      continue unless line
      msg = null
      try msg = JSON.parse line
      continue unless msg
      @_handleFrame msg

  _handleFrame: (msg) ->
    switch msg.t
      when 'pub'
        @subs.forEach (fns, filter) =>
          return unless matches filter, msg.topic
          fns.forEach (fn) =>
            try fn msg.topic, msg.payload, msg
            catch err then @emit 'handler_error', err, msg
      when 'res'
        p = @pending.get msg.reqid
        return unless p
        clearTimeout p.timer
        @pending.delete msg.reqid
        if msg.ok then p.resolve msg.payload
        else p.reject new Error (msg.payload?.error ? 'rpc_failed')
      when 'req'
        @emit 'req', msg

module.exports = {BrokerClient}
