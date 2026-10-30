net  = require 'net'
fs   = require 'fs'
path = require 'path'
{EventEmitter} = require 'events'

# In-process pub/sub + RPC broker over a unix-domain socket.
# Wire format: one minified JSON object per line.
# Frames:
#   {t:'hello',    client_id, role}
#   {t:'sub',      topic}
#   {t:'unsub',    topic}
#   {t:'pub',      topic, payload, retain?, ts?, seq?, retained?}
#   {t:'req',      topic, reqid, payload}
#   {t:'res',      topic, reqid, ok, payload}
#   {t:'proxy_handle', topic}   bridge-side: install an RPC handler that forwards

matches = (filter, topic) ->
  f = filter.split '/'
  t = topic.split '/'
  for seg, i in f
    return true  if seg is '#'
    return false if i >= t.length
    continue     if seg is '+' or seg is t[i]
    return false
  f.length is t.length

class Broker extends EventEmitter
  constructor: (@sockPath) ->
    super()
    @clients  = new Set()
    @retained = new Map()
    @handlers = new Map()
    @_pendingProxy = new Map()
    @seq = 0

  listen: ->
    # NEVER blindly unlink the socket path. A plain `fs.unlinkSync` before
    # bind is the "steal the socket" footgun: if a resident controller is
    # already listening here, removing its directory entry orphans its
    # live inode — the controller keeps its open fds (looks healthy) but
    # every NEW client gets ENOENT. Instead: try to bind; only on
    # EADDRINUSE probe whether a live listener answers. Live → refuse
    # (surface the error so the caller falls back to client). Refused /
    # missing → the file is stale, so reclaim it (unlink + retry once).
    fs.mkdirSync path.dirname(@sockPath), recursive:true
    @server = net.createServer (sock) => @_accept sock
    onListening = =>
      try fs.chmodSync @sockPath, 0o600 catch
      @emit 'listening', @sockPath
    @server.on 'error', (err) =>
      unless err?.code is 'EADDRINUSE' and not @_retriedBind
        return @emit 'error', err
      probe = net.connect @sockPath
      settled = false
      finish = (fn) =>
        return if settled
        settled = true
        try probe.destroy() catch
        fn()
      probe.once 'connect', => finish => @emit 'error', err  # live listener — do not steal
      probe.once 'error', (perr) => finish =>
        if perr?.code is 'ECONNREFUSED' or perr?.code is 'ENOENT'
          @_retriedBind = true
          try fs.unlinkSync @sockPath catch
          @server.listen @sockPath, onListening             # stale file — reclaim
        else
          @emit 'error', err
    @server.listen @sockPath, onListening
    @

  close: ->
    try c.sock.end() for c from @clients
    @server?.close()
    try fs.unlinkSync @sockPath catch

  _accept: (sock) ->
    client = {sock, id:null, role:null, subs:new Set(), buf:''}
    @clients.add client
    sock.on 'data',  (chunk) => @_onData client, chunk
    sock.on 'close', => @clients.delete client
    sock.on 'error', => @clients.delete client

  _onData: (client, chunk) ->
    client.buf += chunk.toString 'utf8'
    loop
      nl = client.buf.indexOf '\n'
      break if nl < 0
      line = client.buf.slice 0, nl
      client.buf = client.buf.slice nl + 1
      continue unless line
      msg = null
      try msg = JSON.parse line
      continue unless msg
      try @_dispatch client, msg
      catch err then @emit 'dispatch_error', err, msg

  _dispatch: (client, m) ->
    switch m.t
      when 'hello'
        client.id   = m.client_id
        client.role = m.role
      when 'sub'
        return unless typeof m.topic is 'string'
        client.subs.add m.topic
        @retained.forEach (rec, topic) =>
          if matches m.topic, topic
            @_send client, {t:'pub', topic, payload:rec.payload, retained:true, ts:rec.ts, seq:rec.seq}
      when 'unsub'
        client.subs.delete m.topic
      when 'pub'
        @publish m.topic, m.payload, retain: m.retain is true
      when 'req'
        @_handleReq client, m
      when 'res'
        p = @_pendingProxy.get m.reqid
        if p
          @_pendingProxy.delete m.reqid
          if m.ok then p.resolve m.payload
          else p.reject new Error (m.payload?.error ? 'proxy_failed')
      when 'proxy_handle'
        return unless typeof m.topic is 'string'
        @handlers.set m.topic, (payload, meta) =>
          new Promise (resolve, reject) =>
            reqid = "p#{++@seq}"
            @_pendingProxy.set reqid, {resolve, reject}
            @_send client, {t:'req', topic: meta.topic, reqid, payload}
      when 'bye'
        try client.sock.end()

  publish: (topic, payload, {retain}={retain:false}) ->
    return unless typeof topic is 'string'
    ts = Date.now()
    seq = ++@seq
    frame = {t:'pub', topic, payload, ts, seq}
    if retain
      if payload is null then @retained.delete topic
      else @retained.set topic, {payload, ts, seq}
    for c from @clients
      for filter from c.subs when matches filter, topic
        @_send c, frame
        break
    @emit 'pub', topic, payload
    frame

  subscribeLocal: (filter, fn) ->
    @on 'pub', (topic, payload) ->
      fn topic, payload if matches filter, topic

  handle: (filter, fn) -> @handlers.set filter, fn

  _handleReq: (client, m) ->
    handler = null
    htopic  = null
    @handlers.forEach (fn, filter) ->
      return if handler
      if matches filter, m.topic
        handler = fn; htopic = filter
    unless handler
      return @_send client, {t:'res', topic:m.topic, reqid:m.reqid, ok:false, payload:{error:'no_handler'}}
    Promise.resolve()
      .then => handler m.payload, {topic:m.topic, filter:htopic, client_id:client.id, role:client.role}
      .then (result) => @_send client, {t:'res', topic:m.topic, reqid:m.reqid, ok:true, payload:result}
      .catch (err)   => @_send client, {t:'res', topic:m.topic, reqid:m.reqid, ok:false, payload:{error:String(err?.message ? err)}}

  _send: (client, msg) ->
    try client.sock.write JSON.stringify(msg) + '\n'
    catch then @clients.delete client

module.exports = {Broker, matches}
