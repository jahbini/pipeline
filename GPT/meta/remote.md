# meta/remote — MCP client for remote pipeline peers

**File**: `meta/remote.coffee`
**Suffix**: `*.remote`
**Peer**: any host running `mcp/pipe_server.coffee` (see [`../mcp/pipe_server.md`](../mcp/pipe_server.md))

## Contract

A key matching `*.remote` routes to this handler. Writing a
**request struct** with a string `op:` field kicks off an MCP tool
call against the named peer's `pipe_server`; the memo entry hydrates
to the parsed tool response when the call completes.

```coffee
L.saveThis 'probe.remote',
  peer: 'mini'
  op:   'status'
status = await L.need 'probe.remote'

L.saveThis 'stories.remote',
  peer: 'mini'
  op:   'sqlite_request'
  args: { key: 'allStories.jsonl' }
rows = await L.need 'stories.remote'
```

Any tool the peer's `pipe_server` exposes — read tools always,
control tools when `PIPE_MCP_ALLOW_CONTROL=1` on the peer — is
callable by name. This handler does not maintain a whitelist; it
passes `op` and `args` through verbatim.

## Request struct

| field | required | notes |
|---|---|---|
| `peer` | ✓ | Key into `params/_global.yaml: remote_peers`. |
| `op`   | ✓ | MCP tool name on the peer (e.g. `status`, `sqlite_request`, `launch`, `write_recipe`). |
| `args` |   | Tool arguments; passed through verbatim. Defaults to `{}`. |

## Peer table (`params/_global.yaml`)

```yaml
remote_peers:
  mini:
    transport: stdio               # only stdio in v1
    command:   ssh
    args:
      - mini.local
      - "cd ~/writer && coffee node_modules/@jahbini/pipeline/mcp/pipe_server.coffee"
    env:                           # merged over process.env
      UI_HOST: "127.0.0.1"
      UI_PORT: "4311"
      PIPE_MCP_ALLOW_CONTROL: "1"  # needed for control tools
```

Add peers as new hosts come online. `command` + `args` are what
`StdioClientTransport` spawns; the child is expected to speak MCP on
its stdio (i.e. it runs `pipe_server.coffee`). SSH gives you tunnel
+ auth for free while `pipe_server` stays bound to 127.0.0.1 on the
peer.

## Client lifecycle

- One client per peer, lazy-spawned on first use, cached for the
  runner's lifetime.
- The stdio child dies when the parent exits — no explicit teardown
  in v1.
- The `@modelcontextprotocol/sdk` client modules are `require`d
  lazily so a broken sdk install doesn't fail meta loading for
  other backends.

## Response parsing

MCP tool results wrap content as `{content: [{type, text}], ...}`.
This handler:

1. Reads `result.content[0].text`.
2. If `result.isError`, throws with the text as the error message.
3. Otherwise, JSON-parses the text and returns the object. If the
   text isn't JSON, returns the raw string.

`pipe_server.coffee` always serializes response bodies as JSON in a
single text block, so this shape is stable for peer traffic.

## Failure policy

- Missing `peer:` / unknown peer / non-string `op:` → **synchronous
  throw at write time**. The step fails immediately.
- MCP transport error or tool `isError:true` → the memo entry's
  `notifier` **rejects**. Any `L.need` awaiter throws with the same
  message.
- **No retries in v1.** `pipe_server` is a thin proxy; retries
  belong at the underlying capability (`meta/hfchat` already
  retries; sqlite reads are cheap; write tools should not silently
  retry). If a peer transport becomes flaky, add `withRetriesAsync`
  here later, matching `meta/hfchat`.

## Async plumbing

Same shape as `meta/hfchat`: presence of `op:` distinguishes a
fresh request from the response's self-injected pass-through write.
Fresh writes kick off the MCP call and clear `entry.value`; the
in-flight promise re-enters `saveThis` on settlement, which hits
the pass-through branch and resolves the notifier with the parsed
response.

## Related

- `mcp/pipe_server.coffee` — the peer-side surface.
- `../mcp/pipe_server.md` — full tool catalog.
- Puppeteer's `remote_launch_ite.coffee` / `remote_wait_ite.coffee`
  — canonical dispatch + poll pattern using this handler.
