# UI panels — the plugin surface

_Landed 2026-09-09. Framework-orbit. Same three-tier
(CWD ↠ BASE ↠ EXEC) resolution as steps, tools, and recipes; same
handler-registration mental model as `meta/`._

## Why this exists

Historically, every new project or every new pipeline that needed a
per-pipe view (Diary Files for writer, Peer Pipes for puppeteer,
Storacle preview for a hypothetical next project) required editing
`ui_server.coffee` **and** `ui/index.html`. Two files, two orbits,
per feature. The `ui_server.coffee` files grew past 2000–3000 lines
and diverged between writer and puppeteer.

Panels invert that: **a new UI section is a single file the ui_server
discovers at boot.** No routing edits, no HTML edits per-project.

## Contract

A panel file exports:

```coffee
exports.panel =
  # Required — user-visible section header.
  title: 'Diary Files'

  # Required — client rendering hint. The UI has a fixed vocabulary
  # of render_hint values (see below); a new one requires an html-side
  # add. Keep this small.
  render_hint: 'file_list'

  # Optional — where the panel goes in the layout.
  # 'left' (default) | 'right' | 'top' | 'hidden'
  column: 'left'

  # Required — the read handler. Called on every /api/status refresh
  # AND on-demand via /api/panel/<name>. Returns a JSON-serializable
  # value shaped for the declared render_hint. See §Shapes below.
  endpoint: (ctx) ->
    fs = ctx.fs
    for entry in ctx.helpers.listFiles(ctx.path.join(ctx.CWD, 'diary'))
      ...

  # Optional — server-side gating. Return true to include the panel
  # in this ui_server's active set; return false to skip it entirely
  # (no route registered, no /api/status entry, no HTML slot).
  # Called ONCE at loader init. Common use: check for a required
  # subdirectory or a feature flag.
  applies: (ctx) -> ctx.fs.existsSync(ctx.path.join(ctx.CWD, 'diary'))
```

`ctx` is the same shape every panel receives:

```coffee
ctx =
  CWD:  '/Users/…/writer/pipes/<pipe>'   # per-invocation
  BASE: '/Users/…/writer'                # constant per ui_server
  EXEC: '/Users/…/pipeline'              # ditto
  fs:   require 'fs'                     # convenience
  path: require 'path'
  helpers:                               # shared file/JSON utilities
    listFiles:         (dir) -> …
    readJson:          (path, fallback) -> …
    describeOutputFile: (relpath, runStart) -> …
    …
```

Panels **do not** receive `S`, `M`, the runner, or any live sockets.
Same discipline as `S.tools.*`: idempotent, no cross-call state, no
runner-injected objects. A panel is a read-only view of disk +
optional short-form JSON responses.

## Resolution — BASE ↠ EXEC (two tiers, not three)

```
BASE_TIER  = <BASE>/panels/<name>.coffee         # project-shared
EXEC_TIER  = <EXEC>/panels/<name>.coffee         # framework-shipped
```

BASE wins on conflict. No CWD (per-pipe) tier — 2026-09-09 design
decision: all pipes in a project share one UI. A pipe that truly
needs a different view is a different project. Skipping the CWD
tier keeps the mental model tight and avoids "which pipe's panels
did I resolve?" confusion at debug time.

Discovery walks the two tiers at boot and builds a `<name>` →
`<resolved_path>` map. `params/_panels.yaml` records the resolved
paths so a human can grep-audit "which tier supplied Diary Files
this session."

New shipped panel: drop `<EXEC>/panels/<name>.coffee`. New project
panel: drop `<BASE>/panels/<name>.coffee`. Promote from BASE to
EXEC when the panel makes sense across projects.

## Shapes per render_hint

| render_hint  | endpoint returns                                                   | client renders            |
|--------------|--------------------------------------------------------------------|---------------------------|
| `file_list`  | `[{path, size, mtime, fresh}, …]`                                  | Diary Files-style list    |
| `table`      | `{columns: [{key, label}], rows: [{key: value, …}, …]}`            | generic sortable table    |
| `code`       | `{language: 'json'\|'yaml'\|'log', text: '…'}`                       | monospace preview         |
| `text`       | `{text: '…'}`                                                      | plain paragraph           |
| `key_value`  | `{items: [{key, value}, …]}`                                       | 2-col definition list     |
| `custom`     | any JSON                                                           | requires a matching client hook in `ui/index.html` — panel-name-keyed |

`custom` is the escape hatch: if a panel needs a render the vocabulary
doesn't support, name it `custom` and add a client hook keyed by
panel name. Every use of `custom` is a signal that a new hint may
belong in the standard vocabulary.

## HTTP surface

- `GET /api/status.panels`: `[{name, title, render_hint, column}, …]`
  — declaration only (no data), so the client can lay out slots
  before fetching. Populated at ui_server boot from the panel-name→
  resolved-path map.
- `GET /api/panel/<name>`: full endpoint result for a single panel.
  Called on-demand by the client (poll cadence per panel — the
  registry supports a `poll_seconds` optional field, default 5s).
- `/api/status` also embeds `panels_data.<name>` with the last
  endpoint result for panels that opted into eager inclusion
  (`eager: true` in the panel export). Diary Files opts in; a heavier
  panel like Peer Pipes stays lazy.

## What the ui_server core does (and stops doing)

Before panels:
```
ui_server.coffee has: collectDiaryFiles(), collectLogFiles(),
collectExpectedOutputs(), handlePeerPipes(), route ordering for
each…
```

After panels:
```
ui_server.coffee has: panel_registry.load(dirs)
                      /api/status embeds panels_data + panels
                      /api/panel/<name> dispatches to the registry
```

Delta ≈ 200 lines out of ui_server, per-panel logic goes into
`panels/<name>.coffee`. New pipeline adds a panel file; nothing in
ui_server.coffee changes.

## Migration path

Panels land alongside the existing collectors so both surfaces
work during transition. Each collector migrates one at a time:

1. **diary_files** (writer, simplest — file listing) — 2026-09-09.
2. **log_files** (writer, mirrors diary_files).
3. **peer_pipes** (puppeteer, project-tier — talks to a remote).
4. **queue_status** (puppeteer, reads state/queue_state.json).
5. **outputs** / **steps** / **pipeline_death** (writer, framework-
   tier — these are ubiquitous across projects, ship at EXEC).

Deletion of the legacy `data.diary_files` field from `/api/status`
happens only after every consumer moved to `data.panels_data.*`.

## Non-goals

- Panels do NOT drive step execution. They're read-only views. The
  step DAG is `pipeline_runner.coffee`'s job; panels are the UI's.
- Panels do NOT edit files. All writes (recipe edits, override edits,
  pipe state changes) go through the existing `/api/*` POST endpoints.
- A panel cannot register a meta rule, cannot `L.callLLM`, cannot see
  another panel's state. If two panels need shared data, either fetch
  it twice or hoist the source into `helpers`.

## See also

- `pipeline_architecture.md` § "Two orbits" (framework vs domain).
- `recipe_lifecycle.md` — same three-tier promotion pattern applied
  here.
- `CONVENTIONS.md` § "Tools" — the discipline panels borrow (no
  module state, no runner injection).
- `meta/index.coffee` — the loader pattern this mirrors.
