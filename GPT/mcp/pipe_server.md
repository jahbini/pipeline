# mcp/pipe_server — MCP stdio bridge for the UI server

**File**: `mcp/pipe_server.coffee`
**Transport**: MCP over stdio (`@modelcontextprotocol/sdk`)
**Backend**: HTTP proxy to a running `ui_server.coffee`

## Purpose

Exposes the pipeline UI's HTTP surface as MCP tools + resources so a
remote agent (typically `puppeteer` via `meta/remote.coffee`) can
drive a peer host without any UI-specific client code. Every tool
here is a thin wrapper around a `ui_server.coffee` route; no state
lives in this file.

## Environment

| var | default | meaning |
|---|---|---|
| `UI_HOST` | `127.0.0.1` | Host to proxy HTTP to. |
| `UI_PORT` | `4311` | Port `ui_server` is bound on. |
| `PIPE_MCP_ALLOW_CONTROL` | unset | When `1`, the control tools below are registered. Read tools are always registered. |

## Read tools (always on)

| tool | maps to | notes |
|---|---|---|
| `status` | `GET /api/status` | Live run/pipe/steps state for the active pipe. |
| `manifest` | `GET /api/manifest` | Full API manifest of the UI server. Use to discover routes added since this MCP was written. |
| `list_pipes` | derived from `status` | v1 stopgap — UI has no multi-pipe listing route yet. |
| `sqlite_request` | `GET /api/sqlite/<key>` | Dispatches a `meta/sqlite` request key. `key` uses meta-layer grammar (`allStories.jsonl`, `storyByID{abc-123}.json`, …). Primary read path. |
| `sqlite_diff` | `GET /api/sqlite/diff?since=…` | Change-log diff since an anchor: uuid, ISO-8601 timestamp, or integer change_id (as string). |
| `run_info` | `GET /api/run/<id>` | Composite run-evaluation: runs row + log tails + artifacts written + sqlite rows added. |
| `read_file` | `GET /api/file?path=…` | Read an artifact or log under CWD. Confinement enforced by UI. |
| `read_recipe` | `GET /api/recipe?name=…` | Recipe yaml + parsed step/artifact view. |
| `read_override` | `GET /api/override?recipe=…` | Per-pipe override yaml. |
| `read_script` | `GET /api/script?path=…` | Step script source via three-tier resolution. |

## Control tools (require `PIPE_MCP_ALLOW_CONTROL=1`)

### Lifecycle

| tool | maps to | notes |
|---|---|---|
| `launch` | `POST /api/launch` | Launch the active pipe. Idempotent via `ensureSingleInstance` in ui_server. |
| `kill` | `POST /api/kill` | SIGTERM the active run. |
| `switch_pipe` | `POST /api/switch_pipe` | Switch to a different pipe or restart in place. Body passed through verbatim; typical payload `{name: <pipe>}`. |

### File writes

Together these let a caller **provision a new pipe on the peer from
scratch**: `write_recipe` → `write_override` → `write_script` (as
many as needed) → `switch_pipe` → `launch`.

| tool | maps to | args | notes |
|---|---|---|---|
| `write_recipe` | `PUT /api/recipe?name=…` | `{name, content}` | Writes `CWD/config/<name>.yaml`. Response includes merged experiment + warnings. |
| `write_override` | `PUT /api/override?recipe=…` | `{recipe, content}` | Writes the per-pipe override. **Authoritative when no config recipe of that name exists**; otherwise layers over it. Response includes merged experiment + toposort check. |
| `write_script` | `PUT /api/script?path=…` | `{path, content}` | Writes `CWD/scripts/<path>`. `.coffee` bodies are compile-checked; failure returns HTTP 4xx with the error. |
| `human_override` | `POST /api/human_override` | `{body: {...}}` | Writes the human override YAML for the **active** recipe. Distinct from `write_override` in that no `recipe` arg is needed. |

### Housekeeping

| tool | maps to | notes |
|---|---|---|
| `clear_pipeline_state` | `POST /api/clear_pipeline_state` | Erases `pipeline.json` (the death record). Common pre-launch reset. |
| `clear_logs` | `POST /api/clear_logs` | Deletes the active pipe's `logs/pipe_HH_MM.(log|err)` files. |
| `clear_output` | `POST /api/clear_output` | Deletes contents of the active pipe's `out/` directory. |

### Cross-machine

| tool | maps to | notes |
|---|---|---|
| `merge_pipe` | `POST /api/merge_pipe` | Merge sqlite + adapter from another machine. Project-specific semantics; body pass-through. |
| `shutdown_ui` | `POST /api/shutdown_ui` | Stops the UI server. After it returns, further tool calls to this peer fail until the UI is restarted out-of-band. |

## Resources

Static:
- `pipe://active/status` — `/api/status`
- `pipe://active/manifest` — `/api/manifest`

Dynamic:
- `pipe://active/sqlite/<key>` — `/api/sqlite/<key>`
- `pipe://active/file/<relpath>` — `/api/file?path=<relpath>`

## `wrapProxy` contract

`wrapProxy(method, buildPath)` builds a handler that:

1. Computes the URL path from `args`.
2. For non-GET methods, sends `args.body ?? {}` as the JSON body.
3. On HTTP ≥400, returns `isError: true` with the status + body.
4. On success, returns the parsed response as a single text
   content block (JSON-serialized).

The "body lives on `args.body`" convention means write tools that
need query params AND a body wrap `wrapProxy` in a small adapter
(see `write_recipe`/`write_override`/`write_script`), splitting the
caller's flat args into `{path-arg}` and `{body}`.

## Failure semantics

- MCP transport errors surface to the client's `callTool` promise
  as rejections.
- HTTP ≥400 returns an MCP tool result with `isError: true` and the
  status/body in the text block. The client's `callTool` promise
  resolves — the caller must check `isError`.
- `meta/remote.coffee` in this repo already checks `isError` and
  throws, so callers going through that path get the natural
  exception path.

## Extending

Add read routes to `readTools`, write/control routes to
`controlTools`. Every new tool should:

- Match the UI's route shape one-to-one (no server-side logic in
  this file).
- Update the manifest comment above.
- Get a one-line entry in this doc.

If a new route needs query params AND a body, follow the
`write_recipe` pattern: a small wrapper that reshapes `args` into
`{name-arg, body}` before delegating to `wrapProxy`.
