#!/usr/bin/env coffee
# mcp/pipe_server.coffee — MCP stdio server that proxies to ui_server.coffee.
#
# All read paths go through /api/sqlite/<request-key> (which dispatches through
# meta/sqlite.coffee), so this server has no direct DB access — consistent with
# the no-direct-db-in-steps rule.
#
# Env:
#   UI_HOST                 default 127.0.0.1
#   UI_PORT                 default 4311
#   PIPE_MCP_ALLOW_CONTROL  when '1', registers launch/kill/switch_pipe tools

{ Server }              = require '@modelcontextprotocol/sdk/server/index.js'
{ StdioServerTransport } = require '@modelcontextprotocol/sdk/server/stdio.js'
{
  ListToolsRequestSchema
  CallToolRequestSchema
  ListResourcesRequestSchema
  ReadResourceRequestSchema
} = require '@modelcontextprotocol/sdk/types.js'

UI_HOST = process.env.UI_HOST ? '127.0.0.1'
UI_PORT = Number(process.env.UI_PORT ? 4311)
ALLOW_CONTROL = process.env.PIPE_MCP_ALLOW_CONTROL is '1'
BASE = "http://#{UI_HOST}:#{UI_PORT}"

# ---------- HTTP proxy ----------

httpJson = (method, urlPath, body = null) ->
  init = { method, headers: {} }
  if body?
    init.headers['content-type'] = 'application/json'
    init.body = JSON.stringify(body)
  res = await fetch("#{BASE}#{urlPath}", init)
  text = await res.text()
  parsed = null
  try parsed = JSON.parse(text) catch then parsed = { raw: text }
  { status: res.status, body: parsed }

textResult = (obj) ->
  content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }]

errResult = (msg) ->
  isError: true
  content: [{ type: 'text', text: String(msg) }]

wrapProxy = (method, buildPath) -> (args) ->
  try
    urlPath = buildPath(args ? {})
    { status, body } = await httpJson(method, urlPath, if method is 'POST' then (args?.body ? {}) else null)
    if status >= 400
      return errResult("HTTP #{status} from #{urlPath}: #{JSON.stringify(body)}")
    textResult(body)
  catch err
    errResult("proxy failure: #{err?.message ? err}")

enc = (s) -> encodeURIComponent(String(s))

# ---------- Tool registry ----------

readTools = [
  {
    name: 'status'
    description: 'Live run/pipe/steps state for the active pipe (GET /api/status).'
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    handler: wrapProxy 'GET', -> '/api/status'
  }
  {
    name: 'manifest'
    description: 'Full API manifest exposed by the UI server (GET /api/manifest). Use this to discover request keys added since this MCP server was written.'
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    handler: wrapProxy 'GET', -> '/api/manifest'
  }
  {
    name: 'list_pipes'
    description: 'v1: returns the active pipe from /api/status. The UI server does not yet expose a multi-pipe listing endpoint.'
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
    handler: (args) ->
      try
        { status, body } = await httpJson('GET', '/api/status')
        if status >= 400
          return errResult("HTTP #{status}: #{JSON.stringify(body)}")
        textResult({ active: body })
      catch err
        errResult(String(err?.message ? err))
  }
  {
    name: 'sqlite_request'
    description: 'Dispatch a meta/sqlite request key through the active pipe (GET /api/sqlite/<key>). The `key` uses meta layer grammar, e.g. "allStories.jsonl", "storyByID{abc-123}.json", "loraTrainingRuns.jsonl". This is the primary read path — any request key the meta layer knows is reachable here.'
    inputSchema:
      type: 'object'
      properties:
        key: { type: 'string', description: 'Request key (see meta/sqlite.coffee), e.g. "allStories.jsonl" or "storyByID{abc-123}.json".' }
      required: ['key']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/sqlite/#{enc(args.key)}"
  }
  {
    name: 'sqlite_diff'
    description: 'Change-log diff since an anchor (GET /api/sqlite/diff?since=…). `since` accepts a run uuid, ISO 8601 timestamp, or integer change_id.'
    inputSchema:
      type: 'object'
      properties:
        since: { type: 'string', description: 'uuid | ISO-8601 timestamp | change_id (integer as string)' }
      required: ['since']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/sqlite/diff?since=#{enc(args.since)}"
  }
  {
    name: 'run_info'
    description: 'Composite run-evaluation for one run_id (GET /api/run/<id>): runs row + log tails + artifacts written + sqlite rows added.'
    inputSchema:
      type: 'object'
      properties:
        runId: { type: 'string' }
      required: ['runId']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/run/#{enc(args.runId)}"
  }
  {
    name: 'read_file'
    description: 'Read an artifact or log under CWD (GET /api/file?path=…). Path resolution and confinement are enforced by the UI server.'
    inputSchema:
      type: 'object'
      properties:
        path: { type: 'string', description: 'Relative path under the pipe CWD.' }
      required: ['path']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/file?path=#{enc(args.path)}"
  }
  {
    name: 'read_recipe'
    description: 'Read a recipe yaml + parsed step/artifact view (GET /api/recipe?name=…).'
    inputSchema:
      type: 'object'
      properties:
        name: { type: 'string' }
      required: ['name']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/recipe?name=#{enc(args.name)}"
  }
  {
    name: 'read_override'
    description: 'Read the per-pipe override yaml for a recipe (GET /api/override?recipe=…).'
    inputSchema:
      type: 'object'
      properties:
        recipe: { type: 'string' }
      required: ['recipe']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/override?recipe=#{enc(args.recipe)}"
  }
  {
    name: 'read_script'
    description: 'Read a step script source via three-tier resolution (GET /api/script?path=…).'
    inputSchema:
      type: 'object'
      properties:
        path: { type: 'string' }
      required: ['path']
      additionalProperties: false
    handler: wrapProxy 'GET', (args) -> "/api/script?path=#{enc(args.path)}"
  }
]

controlTools = [
  {
    name: 'launch'
    description: 'Launch the active pipe (POST /api/launch). Idempotent via ensureSingleInstance on the UI side.'
    inputSchema: { type: 'object', properties: { body: { type: 'object' } }, additionalProperties: false }
    handler: wrapProxy 'POST', -> '/api/launch'
  }
  {
    name: 'kill'
    description: 'SIGTERM the active pipeline run (POST /api/kill).'
    inputSchema: { type: 'object', properties: { body: { type: 'object' } }, additionalProperties: false }
    handler: wrapProxy 'POST', -> '/api/kill'
  }
  {
    name: 'switch_pipe'
    description: 'Switch the UI to a different pipe or restart in place (POST /api/switch_pipe). Body is passed through verbatim.'
    inputSchema:
      type: 'object'
      properties:
        body: { type: 'object', description: 'Payload for /api/switch_pipe.' }
      additionalProperties: false
    handler: wrapProxy 'POST', -> '/api/switch_pipe'
  }
]

TOOLS = readTools.concat(if ALLOW_CONTROL then controlTools else [])
TOOL_BY_NAME = {}
TOOL_BY_NAME[t.name] = t for t in TOOLS

# ---------- Resources ----------

STATIC_RESOURCES = [
  { uri: 'pipe://active/status',   name: 'active pipe status',   mimeType: 'application/json' }
  { uri: 'pipe://active/manifest', name: 'ui api manifest',      mimeType: 'application/json' }
]

parseResourceUri = (uri) ->
  # pipe://active/sqlite/<key>  or  pipe://active/file/<relpath>  or the two static ones
  m = /^pipe:\/\/active\/(sqlite|file|status|manifest)(?:\/(.*))?$/.exec(uri)
  return null unless m
  { kind: m[1], tail: m[2] ? '' }

# ---------- Server ----------

server = new Server(
  { name: 'pipeline-mcp', version: '0.1.0' },
  { capabilities: { tools: {}, resources: {} } }
)

server.setRequestHandler ListToolsRequestSchema, ->
  tools: ({ name: t.name, description: t.description, inputSchema: t.inputSchema } for t in TOOLS)

server.setRequestHandler CallToolRequestSchema, (req) ->
  name = req.params?.name
  args = req.params?.arguments ? {}
  tool = TOOL_BY_NAME[name]
  return errResult("unknown tool: #{name}") unless tool?
  await tool.handler(args)

server.setRequestHandler ListResourcesRequestSchema, ->
  resources: STATIC_RESOURCES

server.setRequestHandler ReadResourceRequestSchema, (req) ->
  uri = req.params?.uri ? ''
  parsed = parseResourceUri(uri)
  unless parsed?
    throw new Error("unrecognized resource uri: #{uri}")
  urlPath = switch parsed.kind
    when 'status'   then '/api/status'
    when 'manifest' then '/api/manifest'
    when 'sqlite'   then "/api/sqlite/#{enc(parsed.tail)}"
    when 'file'     then "/api/file?path=#{enc(parsed.tail)}"
  { status, body } = await httpJson('GET', urlPath)
  if status >= 400
    throw new Error("HTTP #{status} from #{urlPath}")
  contents: [{ uri, mimeType: 'application/json', text: JSON.stringify(body) }]

main = ->
  transport = new StdioServerTransport()
  await server.connect(transport)
  process.stderr.write("pipeline-mcp listening on stdio (proxy -> #{BASE}, control=#{ALLOW_CONTROL})\n")

main().catch (err) ->
  process.stderr.write("pipeline-mcp fatal: #{err?.stack ? err}\n")
  process.exit(1)
