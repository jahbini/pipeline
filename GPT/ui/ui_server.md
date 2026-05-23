Area: `ui_server.coffee` + `ui/index.html`

Purpose:
- provide the pipe-local UI for selecting recipes, editing overrides, launching runs, and inspecting outputs/logs

Current UI layout contract:
- left column is observability:
  - `Pipeline Death`
  - `Outputs`        (only the `out/*` files)
  - `Diary Files`    (its own panel — kept separate from `Outputs`)
  - `Logs`           (log files from `logs/`; starts collapsed by default via `data-default-collapsed="1"`)
  - `Steps`
  - `Latest Err`
  - `Latest Log`
- right column is one merged `Controls` pane containing:
  - `Pipe`
  - `Run`
  - `Recipe And Overrides`
  - recipe selector
  - launch / kill / restart controls
  - recipe UI fields

Collapsible sections:
- every `.panel` (and every `.controls-group` inside the right column) has
  its first `<h2>` or `<h3>` wired as a click toggle. The header gets a
  `▼` (open) / `▶` (collapsed) chevron prefix via `::before` on the
  `.section-toggle` class that `setupCollapsibles()` injects.
- when `.collapsed` is on the container, CSS hides every direct child
  except the header (`*:not(.section-toggle)`).
- per-section state persists in `localStorage` under
  `ui-collapse:<header-text-slug>` so the user's open/closed preferences
  survive page reloads.
- default behavior: every section opens. The user opts into collapsing.
- to make a panel start closed by default, add `data-default-collapsed="1"`
  to the `.panel` element. `setupCollapsibles()` checks that attribute as the
  fallback when no `localStorage` entry exists yet. Once the user opens or
  closes the panel, `localStorage` takes over and the attribute is ignored.
  Current panel with this attribute: `Logs`.

Per-pane fullscreen expand:
- two classes of element get a small `⤢` button in their top-right corner:
  - `.yaml-pane` (Recipe Background, Human Override, UI Control Override,
    Effective experiment.yaml — the four YAML viewers/editors)
  - `.ui-textarea-pane` (each `UI_textarea` field inside the Recipe UI
    Fields list — wrapped at render time by `renderControls()`)
- clicking the button lifts that pane to a `position: fixed` overlay
  with 24 px margins on all sides, over a semi-transparent backdrop.
  Inside the overlay, the textarea fills the available height via
  `grid-template-rows: auto 1fr`.
- exactly one pane can be expanded at a time. Clicking `⤢` on another
  pane closes the first. Backdrop-click and `Escape` also close.
- pane-expand state is hoisted to module scope (`paneCurrentlyExpanded`,
  `paneBackdrop`) so it survives across `renderControls()` re-renders
  that destroy and rebuild the `#ui-fields` subtree. The setup function
  also detects when the previously-expanded pane has been disconnected
  from the DOM (re-render) and tears the backdrop down before wiring the
  new DOM.
- `renderControls()` calls `setupPaneExpanders()` at its end so freshly-
  injected `.ui-textarea-pane` elements get their buttons. The wiring is
  idempotent (`dataset.expanderWired` guard) so it is safe to call on
  every refresh.

Current control model:
- recipe UI fields are discovered from the active recipe YAML
- supported directives are:
  - `UI_checkbox`
  - `UI_dropdown`
  - `UI_textarea`
- UI-backed values are stored in `state/ui-control.json`
- effective run control is materialized to `control_override.yaml`
- human overrides are recipe-scoped under `override/<pipeline>.yaml`
- legacy `override.yaml` is only a fallback/bootstrap source and should be
  copied forward into `override/<pipeline>.yaml` when selected

Pipe/workspace rules:
- the active UI is pipe-local under `CWD`
- if a pipe-local file exists, prefer it over the repo-top fallback
- a new empty pipe infers `run.model` from the pipe directory name and
  materializes the selected recipe override when needed

Polling contract:
- do one `refresh()` on page load
- do not run the 2-second polling loop all the time
- start the polling loop whenever any long-running job is active, stop it
  when everything is quiescent so the user can edit freely without the UI
  yanking values back from disk
- "active" means EITHER condition:
  - pipeline `run.status` is one of: `launching`, `running`, `killing`,
    `skipped`, `cooldown`
  - merge `merge_run.status` is one of: `launching`, `running`
- terminal merge states (`exited`, `failed`) intentionally stop polling —
  the immediate `refresh()` after the state transition has already captured
  the final display values
- the decision lives in `ui/index.html`'s `refresh()` function as a single
  `runActive || mergeActive` gate; do not split it into separate per-source
  loops

Active jobs that gate polling (today):
- pipeline run via `/api/launch` → `run.status`
- adapter+SQLite merge via `/api/merge_pipe` → `merge_run.status`
- when a third long-running operation is added (e.g. a model download), it
  must show up in this list AND in the polling gate, or its completion will
  not be noticed until manual reload

Branch portability:
- the UI is dev infrastructure used on every branch (`main`, `rusty`,
  `KAG`, `artifacts`, `coffeeToTheMetal`, `sqlite`, etc.). Improvements
  and bug fixes to it should propagate to ALL branches, not just the
  branch where they were authored.
- portable (apply to every branch):
  - `ui/index.html` — polling logic, layout, form rendering, file viewer
  - `ui_server.coffee` — polling gate, route handlers, file-viewer
    sandboxing, override hierarchy, refresh API contracts
- branch-specific (do NOT propagate blindly):
  - the hardcoded `pipelines: [...]` list in `ui_server.coffee` — each
    branch has its own `_ite` covering set
  - any UI directive that references branch-specific recipe step names
  - assumptions about which artifacts exist in `out/` (rusty produces
    different artifact names than gypsy)
- when I make a UI fix on one branch, I should explicitly flag it as
  "branch-portable" in the response so the human knows to cherry-pick
  or merge it across. I should not switch branches myself — the human
  drives the cross-branch propagation.

Known pitfalls:
- do not re-merge `Outputs`, `Diary Files`, and `Logs` into a single panel —
  each has its own collapse toggle and serves a distinct file class
- the `Logs` panel lists `logs/*.log` and `logs/*.err` files sorted newest-first
  (descending by filename); Outputs and Diary are ascending. Do not normalise
  them to the same direction — newest-first is more useful for logs.
- `log_files` entries use relative paths (`logs/<name>`) so they pass
  `isAllowedFilePath` and open correctly in the file viewer modal on dblclick
- do not silently reintroduce always-on polling
- do not narrow the polling gate back to pipeline-only — that breaks
  termination notification for merges (the May 2026 fix)
- do not split `Latest Err` and `Latest Log` into one pane unless explicitly requested
- do not treat `control_override.yaml` as a substitute for
  `override/<pipeline>.yaml`
- if a new recipe needs freeform text from the UI, prefer `UI_textarea` over inventing a separate ad hoc endpoint
- the recipe selector list at `ui_server.coffee` `pipelines: [...]` is
  hardcoded to the `_ite` covering set plus `story_scan` / `lora_scan`.
  Add new `_ite` recipes there explicitly; do not enumerate `config/*.yaml`
  dynamically (non-`_ite` recipes are kept for reference only and must not
  appear in the dropdown)
- pane-expand state must stay at module scope, not closure-scope. If you
  refactor `setupPaneExpanders()` and trap `paneCurrentlyExpanded` /
  `paneBackdrop` back inside its function body, every `renderControls()`
  re-render will reset the state and leave the backdrop visible without
  any pane underneath.
- do not put the expand button (`.pane-expand-btn`) inside the
  `<textarea>` parent path in a way that lets label-click forward focus
  to the textarea. The current structure (button is a `<button>` child
  with `e.preventDefault()` + `e.stopPropagation()` on click) suppresses
  this; if you change the markup, re-test that clicking `⤢` does not
  also focus the underlying textarea.
- `.ui-textarea-pane` textareas have an explicit `min-height: 70px;
  max-height: 160px` so all `UI_textarea` fields in a recipe are visible
  at once in the compact state. Do not lift these to the global
  `.controls textarea { min-height: 260px }` rule — that would defeat
  the "all three fields visible" intent of the per-textarea expand.
