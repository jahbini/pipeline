# Pipeline Runner — Universal Starting Point

The `pipeline_runner` architecture in this repo is **the default starting
point** for any notebook conversion, batch-shaped automation, or DAG-of-
steps problem. When a new task arrives, treat this framework as the
incumbent answer; reach for something else only after a deliberate reason.

This is not just "the framework I use here." It is a **portable substrate
that has been applied to wildly different domains** and continues to fit.

---

## Evidence the framework is general

Two live, unrelated applications share the same substrate today:

| Project | Domain | Pipe example | Recipes |
|---|---|---|---|
| `writeStory/` | LLM training, inference, story generation | `pipes/Qwen_Qwen3-4B-Instruct-2507/` | `_ite` covering set (`base_ite`, `lora_ite`, `prompt_ite`, `diary_ite`, etc.) |
| `publicist/` | PR / outreach campaign automation | `pipes/spacestruts/` | single `publicist_draft_agent.yaml` (23-step DAG: read source → suggest audiences → build contact ledger → draft messages → web research → enrich → review packet) |

The runner, the UI server, the memo, the override hierarchy, the SQLite-
per-pipe pattern, the restart-by-state-file mechanism, and the
`needs:` / `makes:` / `depends_on:` step contract are identical across
both. The recipes and step bodies are the domain; everything underneath
is shared substrate.

---

## What every project gets for free

The substrate (the parts that should *not* change per project):

- **DAG scheduler.** Steps declare `needs:` (inputs) and `makes:` (outputs).
  The runner builds the topology, runs steps in dependency order, and skips
  steps whose outputs are already current.
- **The Memo.** A reactive in-memory artifact store. Steps publish via
  `L.make 'artifact_name', value`; downstream steps `await L.need 'artifact_name'`.
- **Per-step state files.** Each step writes `state/step-<name>.json`
  recording status, timing, and a summary. If a step in the middle of a
  DAG dies, `state/` plus `params/` tell the next launch where to resume.
- **Pipeline death record.** When the runner crashes, it writes
  `pipeline.json` with the reason; the UI surfaces this in a dedicated
  panel with an "Erase pipeline.json" reset button.
- **SQLite per pipe.** A `*.sqlite` file under the pipe's `runtime/`
  directory is the long-term store. Cross-run truth lives here. The
  recipe can name the file path explicitly under `run."runtime.sqlite"`.
- **Transient working directories.** `out/`, `data/`, `params/`, `state/`
  are scratch space for a single run; their contents are not part of the
  long-term contract.
- **Override hierarchy** (low → high precedence):
  - recipe YAML (`config/<recipe>.yaml`)
  - legacy `override.yaml`
  - per-user `override.<user>.yaml` (publicist uses this; writeStory does not yet)
  - recipe-scoped `override/<recipe>.yaml`
  - UI-driven `state/ui-control.json` → materialized to `control_override.yaml` at launch
- **Pipe-local UI** (`ui_server.coffee` + `ui/index.html`):
  - left column: Pipeline Death, Outputs, Diary Files, Steps, Latest Err, Latest Log
  - right column: Pipe, Run, Recipe And Overrides controls
  - recipe-discovered form fields via `UI_checkbox` / `UI_dropdown` /
    `UI_textarea` directives in the YAML
  - heartbeat polling that turns on while ANY long-running job is active
    (pipeline run or merge), off otherwise so the user can edit freely
  - collapsible panels and per-pane fullscreen expand for YAML viewers
    and recipe textareas (see `GPT/ui/ui_server.md`)
- **Worktree / pipe directory convention.** The active workspace is
  `pipes/<pipe_name>/` and the UI runs pipe-local under that `CWD`.
  Switching pipes is a UI action, not a process restart.

---

## What each project supplies

Per-project domain code (the parts that *do* change per project):

- **Recipes** (`config/<name>.yaml`). One recipe = one notebook (1:1
  conversion). Each top-level key under the recipe is a step.
- **Step scripts**, located wherever the recipe's `run:` path points.
  Conventions seen so far:
  - `scripts/<recipe>/<step>.coffee` — writeStory's `_ite` recipes
  - `agents/<agent>/<step>.coffee` — publicist's agent-style organization
  Pick whichever fits the domain; the runner doesn't care.
- **Artifact registry** under `artifacts:` in the recipe — maps logical
  artifact names to on-disk targets (`out/something.yaml`,
  `build/train/train.jsonl`, etc.).
- **SQLite schema** for the pipe's long-term store (e.g.
  `db/<project>/schema.sql` in publicist).
- **UI-discoverable directives** inside the recipe — strings like
  `[UI_textarea, ""]` that the UI form-renderer picks up.
- **The pipe directory** itself (`pipes/<pipe_name>/`) with whatever
  source material the recipe consumes.

---

## When the framework is the right answer

Use this framework when ANY of:

- the task is a sequence of steps with clear input/output dependencies
- some steps are slow or fragile and you want them to checkpoint and
  resume after a crash
- a human needs to inspect / approve / re-run individual steps
- the work has both long-term state (SQLite-shaped) and transient scratch
- different humans will tweak parameters and run the same recipe
- the task is being lifted from a Python notebook into production

It is not just for ML pipelines. publicist proves a non-ML, non-tensor
domain (PR outreach, web research, contact-ledger curation, human
review) fits comfortably.

## When the framework is the wrong answer

Skip it when:

- the task is a single function call with no dependencies
- there is no concept of restart-at-failed-step (e.g. a stream
  processor that runs continuously)
- the artifacts are too small or ephemeral to bother declaring
- a human will not be in the loop for review or override

---

## Defaults to assume when starting a new project

If asked to bootstrap a fresh project on this substrate, the natural
shape is:

```
new_project/
  pipeline_runner.coffee        # copy from writeStory/publicist
  ui_server.coffee              # copy
  ui/index.html                 # copy (includes today's collapsibles +
                                #  fullscreen pane expand + merge polling)
  config/<recipe>.yaml          # the new recipe(s)
  scripts/<recipe>/<step>.coffee   # or agents/<agent>/<step>.coffee
  pipes/<pipe_name>/
    out/  data/  params/  state/  runtime/
    runtime/<pipe>.sqlite       # long-term store
    source/                     # whatever raw inputs the recipe needs
  override.yaml                 # bootstrap; recipe-scoped overrides
                                #  graduate into override/<recipe>.yaml
  package.json                  # node deps (sqlite, js-yaml, etc.)
  README.md
```

A new "agent" / "_ite" recipe is added by:
1. dropping a YAML under `config/`
2. dropping its step scripts wherever the YAML's `run:` paths resolve
3. listing the recipe name in the UI's `pipelines: [...]` array in
   `ui_server.coffee` (writeStory) or the equivalent place

---

## Two orbits to keep distinct

When working on this codebase, mentally separate:

- **Framework orbit** — `pipeline_runner.coffee`, `ui_server.coffee`,
  `ui/index.html`, the memo machinery, the override resolver, the SQLite
  helpers. Changes here are 🌐 branch-portable AND project-portable;
  any improvement should be considered for both writeStory and publicist
  (and any future project using the substrate).
- **Domain orbit** — recipes, step scripts, schemas, UI directives,
  pipe-specific source material. Changes here are project-local.

GPT/ docs reflect this split:
- framework-orbit docs: `GPT/README.md` overall conventions,
  `GPT/ui/ui_server.md`, this file, future `GPT/pipeline_runner.md`
- domain-orbit docs: `GPT/lora_ite/*`, `GPT/prompt_ite/*`, `GPT/diary_ite/*`,
  `GPT/base_ite/*`, `GPT/lepa-ite/*`, `GPT/oracle_ite/*`, `GPT/gypsy_strategy.md`

When I make a change, I should ask "framework or domain?" first and put
the working-memory note in the matching place.
