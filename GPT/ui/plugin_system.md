# UI plugin system — `${CWD}/ui/project.coffee`

**Introduced**: 2026-10-08. **Status**: live on the mac-mini (puppeteer
+ writer both run under `pipeline/ui_server.coffee` + their `ui/project.coffee`).

## Why

Before the cutover, three near-duplicate `ui_server.coffee` files existed
(`pipeline/`, `puppeteer/`, `writer/`), reimplementing ~20 common routes
plus project-specific divergence. ~12k LOC total. Changes to shared
endpoints had to be made in three places; they drifted. This system
collapses the shared surface into `pipeline/ui_server.coffee` and lets
each project add its own routes via a thin plugin.

## Contract

A project ships `${project}/ui/project.coffee` exporting:

```coffee
module.exports =
  preStartup:   -> void        # optional. Runs BEFORE CWD capture, so a
                               # project can chdir based on sticky state
                               # (puppeteer uses this for its
                               # state/current_pipe.txt pointer).
  portDefault:  number         # optional. Overrides the library's 4311
                               # default when `UI_PORT` is unset.
  init: (ctx) ->               # required. Returns:
    routes:         [routes]   #   array of {method, path|pathPrefix, handler}
    augmentStatus:  async(status) -> void   # optional. Mutates /api/status
                                            #   payload in place (eager
                                            #   panels data, project flags).
```

## Plugin resolution

The library looks for the plugin by **walking up from `process.cwd()`**
until it finds `ui/project.coffee`, stopping at `$HOME` or filesystem
root. This is important: after `/api/switch_pipe` respawns with
`CWD=pipes/<name>` (which has no `ui/project.coffee`), the walk-up finds
the project-root plugin two levels up. The parent of the resolved
plugin becomes `BASE_ROOT` when the npm `node_modules/@jahbini/pipeline`
heuristic doesn't fire (direct `coffee ~/pipeline/ui_server.coffee`
launches).

## Context passed to `init`

```
{CWD, EXEC_ROOT, BASE_ROOT,
 fs, path, http, yaml, spawn,
 sendJson(res, code, payload),
 readRequestBody(req) -> Promise<string>,
 readJson(path, fallback), readText(path, fallback), writeText(path, text),
 resolveUiAsset(rel), listFiles(dir),
 describeOutputFile(rel, runStart), normalizeUiRun(run),
 UI_BIND_MODE, PORT,
 ipcStatus,                        # broker client/cache (null when ipc off)
 subscribeBroker(topic, cb) -> unsubFn,
 pipeInventory}                    # {INVENTORY_BASH, parse} or null
```

`pipeInventory` (2026-10-25) is the ONE canonical writer-pipe inventory
probe — `pipeline/ui/pipe_inventory.coffee`, exposing `INVENTORY_BASH`
(the sqlite/filesystem scan) + `parse(raw)`. Shared so the writer's
local-publish path (`sys/pipe_inventory/<host>`) and puppeteer's SSH
fallback can never drift. See `[[puppeteer_project_plugin]]` /
`[[writer_project_plugin]]`.

`ipcStatus` + `subscribeBroker` were added for **MARRIAGE Stage B**
(2026-10-25). `ipcStatus` is the UI-side `StatusSource` (may be null):
use its `memoRequest(op, args)` and its unfiltered `'memo'`
EventEmitter stream. `subscribeBroker(topic, cb)` gives an **unfiltered
cross-pipe** subscription (e.g. `runner/+/+/lifecycle`) that the
pipe-scoped `ipcStatus` handlers do not surface — reconnect-safe and a
no-op when no broker. The puppeteer plugin uses both to keep a live
peer-view cache behind the `sys/peer_via_broker` gate; see
`[[puppeteer_project_plugin]]`.

Plugins add their own helpers (SSH wrappers, SQLite handles, caches)
privately — the context stays minimal.

## Routes

Each route is `{method, path?, pathPrefix?, handler(req, res, ctx)}`:

- `path` matches the URL's pathname exactly (query strings ignored).
- `pathPrefix` matches when `pathname.startsWith(prefix)`.
- Plugin routes are tried **before** any built-in library route, so a
  plugin can shadow a library endpoint. Puppeteer's `/api/switch_pipe`
  does exactly this to add sticky-pointer semantics.

## `augmentStatus`

The library's `buildStatus()` returns a base `/api/status` payload. If
the plugin exports `augmentStatus(status)`, the library awaits it and
sends the (possibly mutated) status. Puppeteer and writer both use
this to inject `panels` + `panels_data` so panel widgets render on
first paint instead of after a follow-up `/api/panel/*` fetch.

See `[[puppeteer_project_plugin]]` and `[[writer_project_plugin]]` for
concrete role-specific plugins. See also `[[ipc]]` for the broker +
memo modules the library ships at `pipeline/ipc/`.

## File layout

```
pipeline/ui_server.coffee             library (serves all projects)
pipeline/ipc/{broker,broker_client,memo,status_source,wire}.coffee
                                      ↑ loaded by runner/UI; see ipc.md
puppeteer/ui/project.coffee            puppeteer-specific plugin
puppeteer/ui/index.html               puppeteer's static UI
writer/ui/project.coffee               writer-specific plugin
writer/ui/index.html                  writer's static UI
```

## Launch

Both projects now launch via:

```
coffee ~/pipeline/ui_server.coffee [net]
```

from the project root. The old `puppeteer/ui_server.coffee` and
`writer/ui_server.coffee` are deprecated as of 2026-10-08.

On the mac-mini, puppeteer is launchd-managed via
`~/Library/LaunchAgents/com.jahbini.puppeteer-ui.plist` with
`ProgramArguments` pointing at `/Users/theaiguy/pipeline/ui_server.coffee`
and `WorkingDirectory=/Users/theaiguy/puppeteer`. The pre-cutover plist
is preserved as `.before-cutover` for rollback.
