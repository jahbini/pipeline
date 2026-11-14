###
        meta/http.coffee  —  HTTP requests as Memo keys
        =====================================================

  The HTTP sibling of `remote.coffee` (jahbini 2026-11-07: "the use of the
  meta to handle file, sqlite, ssh and http requests must be honored" — a
  step does NO direct http; this device is where orchestration HTTP lives).

  A key `<name>.http` is a fresh request when its value is a struct with a
  string `path:` (plus `port:`). The device performs the request and the
  memo entry hydrates to the parsed JSON response (or the raw body text if
  it wasn't JSON). Same notifier mechanics as `.remote`: between request
  and response `theLowdown` returns undefined and `L.need` awaits; a
  transport failure rejects the awaiter.

  Request struct
  --------------
      { method:     'POST'          # default 'GET'
        host:       '127.0.0.1'     # default loopback — orchestration is
                                    # same-host (octopus handles cross-host)
        port:       5528            # required
        path:       '/api/launch'   # required, must start with '/'
        body:       {...}           # optional; JSON-encoded when present
        timeout_ms: 10000 }         # optional; default 10s

  Step usage (dispatcher-shaped steps, e.g. writer_scheduler_ite):

      L.saveThis 'dispatch.http', {method: 'POST', port: port, path: '/api/launch', body: {pipeline: recipe}}
      entry = L.theLowdown 'dispatch.http'      # the pending entry
      r = if entry.value isnt undefined then entry.value else await entry.notifier
      throw new Error r.__http_error if r?.__http_error?

  NOT `L.need` — the fused ledger's need() throws for keys not declared
  in the step's needs/makes; request keys are awaited via the entry's
  notifier (saveThis → theLowdown runs synchronously, so the entry is
  guaranteed to be the pending one). On transport error the entry
  hydrates to {ok:false, __http_error} — never a hang, never a throw
  from the device itself.

  Re-saving a new struct on the same key re-dispatches (polling loops).
###
http = require 'http'

module.exports = (M, opts = {}) ->

  M.addMetaRule "http",
    /\.http$/,
    (key, value) ->
      # Read with no prior write: nothing to serve.
      if value is undefined
        return M.MM[key]?.value

      # Pass-through: a response re-entering saveThis (no request shape)
      # lands as-is so entry.value = value and the notifier resolves.
      unless value? and typeof value is 'object' and typeof value.path is 'string' and value.path.charAt(0) is '/' and value.port?
        return value

      method  = String(value.method ? 'GET').toUpperCase()
      host    = String(value.host ? '127.0.0.1')
      port    = Number(value.port)
      reqPath = String(value.path)
      body    = if value.body? then JSON.stringify(value.body) else null
      timeout = Number(value.timeout_ms ? 10000)

      # Clear cached value so a between-times theLowdown returns undefined
      # and L.need awaits the notifier rather than the raw request struct.
      entry = M.MM[key]
      entry.value = undefined if entry?

      doRequest = new Promise (resolve, reject) ->
        headers = {}
        if body?
          headers['Content-Type']   = 'application/json'
          headers['Content-Length'] = Buffer.byteLength(body)
        # agent: false — no keep-alive pooling. Orchestration calls are
        # low-rate, and an idle pooled socket whose far end closes (puppet
        # restart) emits an UNHANDLED 'error' that would crash the node
        # (observed: ECONNRESET crash in the probe under Node 24).
        req = http.request {host, port, path: reqPath, method, headers, timeout, agent: false}, (res) ->
          buf = ''
          res.on 'data', (d) -> buf += d
          res.on 'end', ->
            parsed = try JSON.parse(buf or '{}') catch then buf
            resolve parsed
        req.on 'error', reject
        req.on 'timeout', ->
          try req.destroy() catch then null
          reject new Error "meta/http: #{method} #{host}:#{port}#{reqPath} timed out after #{timeout}ms"
        req.write body if body?
        req.end()

      doRequest
        .then (response) ->
          # Re-enter saveThis via the pass-through branch: resolves the
          # notifier with `response` and sets entry.value.
          M.saveThis key, response
        .catch (err) ->
          console.error "[http] #{key} (#{method} #{host}:#{port}#{reqPath}) failed:", err?.message ? err
          # Resolve the awaiter through the sanctioned PASS-THROUGH path.
          # The .remote/.hfchat convention (replace entry.notifier with a
          # rejected promise) cannot reject a promise an awaiter already
          # holds — the awaiter would HANG forever on a transport error.
          # An error MARKER rides the normal response path instead;
          # callers check __http_error. Explicit return keeps the chain
          # from re-adopting anything.
          try M.saveThis key, {ok: false, __http_error: String(err?.message ? err)}
          return

      # Leave entry.value cleared until the response lands.
      undefined
