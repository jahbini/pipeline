###
        meta/remote.coffee  —  MCP client for remote pipeline peers
        ===========================================================

  Fourth meta backend, alongside `sqlite`, `hfchat`, and the file
  backends. Turns keys matching `*.remote` into MCP tool calls
  against a `mcp/pipe_server.coffee` running on another host (or a
  local subprocess). The peer table lives in
  `params/_global.yaml: remote_peers` — no wire details in step
  code.

  Contract
  --------
  A key `foo.remote` is a fresh request when its value is a struct
  with a string `op:` field. The handler dispatches over MCP and
  the memo entry hydrates to the parsed tool response (the object
  the tool's `content[0].text` JSON-decoded to, or the raw string
  if it wasn't JSON).

  Request struct
  --------------
      { peer:  'mini'                # key into remote_peers
        op:    'status'              # MCP tool name on pipe_server
        args:  {...}                 # tool arguments (optional) }

  Steps never see MCP:

      L.saveThis 'probe.remote', {peer: 'mini', op: 'status'}
      status = await L.need 'probe.remote'

      L.saveThis 'stories.remote',
        peer: 'mini'
        op:   'sqlite_request'
        args: {key: 'allStories.jsonl'}
      rows = await L.need 'stories.remote'

  Peer table (params/_global.yaml)
  --------------------------------
      remote_peers:
        mini:
          transport: stdio           # only stdio for v1
          command:   ssh
          args: [mini.local, "cd ~/writer && coffee \
                 node_modules/@jahbini/pipeline/mcp/pipe_server.coffee"]
          env:                       # optional; merged over process.env
            UI_PORT: "4311"
            PIPE_MCP_ALLOW_CONTROL: "1"

  Clients are lazy-spawned per peer on first use and cached for the
  lifetime of the runner process. The MCP stdio child dies when the
  parent exits — no explicit teardown in v1.

  Failure policy
  --------------
  - Missing `peer:` / unknown peer / missing `op:` → synchronous
    throw at write time.
  - MCP transport error, tool `isError:true`, or unparseable
    response → the memo entry's `notifier` rejects. Any
    `L.need` awaiter throws with the same message.
  - No retry policy in v1. `pipe_server` is a thin proxy; retries
    belong at the underlying capability (hfchat already retries;
    sqlite reads are cheap). If a peer transport is flaky we can
    add `withRetriesAsync` here later, matching hfchat.

  Async plumbing (why the handler has two branches)
  -------------------------------------------------
  Same shape as `meta/hfchat`. Presence of `op:` distinguishes a
  fresh request from the self-injected response write. On a fresh
  write we kick off the MCP call, clear `entry.value`, and let the
  in-flight promise re-enter `saveThis` when it settles. On the
  pass-through write (no `op:`) we return the value unchanged so
  it lands as `entry.value` and the notifier resolves.
###

STDIO_CLIENTS = {}   # peerName → {client, transport} (cached)
SDK           = null # lazy-loaded so a broken sdk install doesn't
                     # break meta loading for the other backends.

loadSdk = ->
  return SDK if SDK?
  { Client }               = require '@modelcontextprotocol/sdk/client/index.js'
  { StdioClientTransport } = require '@modelcontextprotocol/sdk/client/stdio.js'
  SDK = { Client, StdioClientTransport }

resolvePeer = (M, name) ->
  globalParams = M.theLowdown("params/_global.yaml")?.value ? {}
  peers = globalParams.remote_peers ? {}
  spec = peers[name]
  throw new Error "meta/remote: unknown peer '#{name}' (params/_global.yaml: remote_peers)" unless spec?
  transport = spec.transport ? 'stdio'
  throw new Error "meta/remote: peer '#{name}' transport '#{transport}' not supported (v1: stdio only)" unless transport is 'stdio'
  throw new Error "meta/remote: peer '#{name}' missing 'command'" unless typeof spec.command is 'string'
  spec

getClient = (M, peerName) ->
  cached = STDIO_CLIENTS[peerName]
  return cached.client if cached?

  { Client, StdioClientTransport } = loadSdk()
  spec = resolvePeer(M, peerName)

  env = Object.assign({}, process.env, spec.env ? {})
  transport = new StdioClientTransport
    command: spec.command
    args:    spec.args ? []
    env:     env

  client = new Client(
    { name: "pipeline-remote-client", version: "0.1.0" }
    { capabilities: {} }
  )
  await client.connect(transport)
  STDIO_CLIENTS[peerName] = { client, transport }
  client

# One MCP round-trip. Returns the parsed tool result (JSON-decoded
# from content[0].text when possible, else the raw text). Throws on
# transport error or tool `isError:true`.
callTool = (M, peerName, op, args) ->
  client = await getClient(M, peerName)
  result = await client.callTool { name: op, arguments: args ? {} }
  first  = result?.content?[0]
  text   = if first?.type is 'text' then first.text else null
  if result?.isError
    throw new Error "meta/remote: peer '#{peerName}' tool '#{op}' returned isError: #{text ? '(no message)'}"
  return null unless text?
  try
    JSON.parse(text)
  catch
    text

module.exports = (M, opts = {}) ->

  M.addMetaRule "remote",
    /\.remote$/,
    (key, value) ->
      # Read with no prior write: nothing to serve.
      if value is undefined
        return M.MM[key]?.value

      # Pass-through: response object re-entering saveThis. No `op:`
      # → not a fresh request → land as-is so entry.value = value
      # and the notifier resolves.
      unless value? and typeof value is 'object' and typeof value.op is 'string'
        return value

      peer = value.peer
      throw new Error "meta/remote: request to '#{key}' missing string 'peer'" unless typeof peer is 'string' and peer.length

      op   = value.op
      args = value.args ? {}

      # Clear cached value so a between-times `theLowdown` returns
      # undefined and `L.need` awaits the notifier rather than the
      # raw request struct.
      entry = M.MM[key]
      entry.value = undefined if entry?

      callTool(M, peer, op, args)
        .then (response) ->
          # Re-enter saveThis via the pass-through branch: resolves
          # the notifier with `response` and sets entry.value.
          M.saveThis key, response
        .catch (err) ->
          console.error "[remote] #{key} (#{peer}/#{op}) failed:", err?.message ? err
          latest = M.MM[key]
          if latest?
            rejected = Promise.reject(err)
            rejected.catch -> null
            latest.notifier = rejected

      # Return undefined so saveThis leaves entry.value cleared until
      # the response lands.
      undefined
