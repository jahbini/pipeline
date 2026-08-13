# Pipeline Graph Panel — SVG DAG in the framework UI

Ported from `~/writer/` on 2026-08-10. This makes the interactive
SVG pipeline-graph panel a first-class feature of the pipeline
framework UI so any pipeline consumer gets it, not just writer.

## What the feature is

A full-width panel above the two-column controls that renders the
current pipe's `experiment.yaml` as a DAG SVG. Live status
(pending / running / done / failed) on script circles, artifact
existence indicators (produced / stale / absent / source /
terminal) on artifact circles. Hover reveals labels. Click a data
circle → file-viewer modal. Click a script circle → step-detail
modal with a Restart This Step button.

## Files that own it

- `pipeline_svg.coffee` at the repo root — SVG generator.
  `renderSvg(experiment)` returns an SVG string with
  self-contained styles and `data-step` / `data-artifact` /
  `data-target` attributes so client-side JS can toggle status
  classes.
- `ui_server.coffee` — four routes:
  - `GET /api/pipeline_svg` — hot-reloads `pipeline_svg.coffee`
    on every request (edits land without server restart), reads
    `experiment.yaml`, returns rendered SVG.
  - `GET /api/step_detail?name=<step>` — returns state file
    (JSON) + params file (YAML text) for the step-detail modal.
  - `POST /api/step_restart` `{name}` — sanctioned restart via
    the runner's `restart_here` protocol; marks ONLY the target
    step (no upstream cascade — see below).
  - `GET /api/file?path=<rel>` — file viewer (was already
    present in pipeline before the port).
- `ui/index.html` — panel `<section class="panel
  pipeline-graph-panel">`, `.pipeline-graph-panel` CSS,
  `refreshPipelineGraph` / `openStepModal` / `closeStepModal` /
  `restartStep` JS handlers, step-detail modal shell, modal-freeze
  guard integrated into `refresh()`.

## Design decisions worth remembering

### Restart is target-only, no upstream cascade

`/api/step_restart` marks ONLY the target step's state file.
Upstream state, params, and control_override are left exactly
as-is. If an upstream step's declared output file is missing on
disk the runner may block waiting for it — that's the operator's
problem to resolve.

Earlier prototype cascaded: BFS through `depends_on`, marking
any ancestor whose `makes:` files were missing. Operator feedback
2026-08-10 killed that: too much regenerated silently, unclear
which prior steps a click would touch. "Restart this step,
nothing else" is worth more than the auto-fix convenience.

### Max-height cap is load-bearing

`.pipeline-graph-panel .pipeline-svg { max-height: min(65vh, 560px); }`

Without the cap, a tall+narrow viewBox (one-script recipe with
several stacked artifacts) gets scaled up by `width: 100% +
preserveAspectRatio` to fill container width, blowing every
circle up 3–5×. With the cap, tall graphs letterbox at natural
aspect. Wide graphs never hit the cap.

Don't raise the cap without testing a one-script recipe.

### Modal-freeze guard

While EITHER the file-modal or step-modal is open, `refresh()`
no-ops on its 2s heartbeat. Reader can dwell without under-modal
DOM churn. `closeFileModal` and `closeStepModal` each fire one
immediate `refresh()` to catch up.

### SVG endpoint hot-reload

`/api/pipeline_svg` deletes the require-cache entry for
`pipeline_svg.coffee` on every request and re-requires it. Edits
to the layout code land without restarting the UI server. This
is a deliberate development convenience — do not "optimize" the
cache-bust away.

## What writer keeps

`/Users/jahbini/writer/` retains its own local copies of
everything (its `pipeline_svg.coffee`, `ui_server.coffee`,
`ui/index.html`). This port doesn't force writer to switch to
consuming the pipeline package's copies — that's a separate
future decision. The two sets of files are kept in sync manually
when we iterate on the feature.

## Sizing constants of record

- `pipeline_svg.coffee` layout: `COL_W=110`, `ROW_H=60`,
  `MARGIN_X=40`, `MARGIN_Y=20`, symmetric height calc.
- Panel cap: `max-height: min(65vh, 560px)`.

## Related notes

- Details on the restart contract:
  `~/writer/GPT/ui/step_restart.md`.
- Sizing rationale and history:
  `~/writer/GPT/ui/pipeline_graph_reactivity.md`.
- Save/select "good" adapters (uses same UI panel infrastructure):
  `~/writer/GPT/ui/save_good_adapter.md`.
