# @jahbini/pipeline-runner

A small dependency-aware step runner for shell-friendly AI experiments.
Pipelines are declared in YAML; each step declares what it `needs`, what
it `makes`, and what it `depends_on`. The runner topologically sorts the
DAG, wires artifacts between steps through a shared in-memory store
(the *Memo*), and records per-step state to disk so an interrupted run
can be resumed.

The code is annotated in the Backbone/Underscore Docco style — every
section opens with prose that explains why the code looks the way it
does. Read [`pipeline_runner.coffee`](pipeline_runner.coffee) front to
back as the canonical tour.

## Install

```sh
mkdir my-pipeline-project && cd my-pipeline-project
npm init -y
npm install @jahbini/pipeline-runner
```

That gives you the runner and its two npm dependencies
(`coffeescript`, `js-yaml`). Total `node_modules/` footprint is a few
MB.

## First run — the teaching pipeline

The shipped `test` pipeline is nine steps, each chosen to demonstrate a
different mechanism (source step, needs/makes, async work, subprocess
calls, sqlite request keys). It runs end-to-end in under a minute.

```sh
# 1. Drop the example override at the project root. This is the
#    ONE artifact a project actually needs to commit.
cp node_modules/@jahbini/pipeline-runner/override.test.yaml ./override.yaml

# 2. Create a Python virtualenv with MLX pinned to the versions
#    the runner expects. (Only required if you'll use the MLX
#    surface — the test pipeline's step7 spawns Python.)
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip setuptools wheel
./.venv/bin/pip install -r node_modules/@jahbini/pipeline-runner/requirements.txt

# 3. Run it.
npx pipeline-runner
```

You should see eight step banners, then a friendly hand-off message
from `step9_handoff` explaining what to do next. That message is the
pipeline's way of saying "now it's your opportunity."

## UI (optional)

The runner ships an HTTP UI that watches `state/ui-events.jsonl` and
`state/ui-run.json`, lets you pick a recipe, launch a run, watch
step lifecycles in real time, and inspect artifacts.

The UI is split deliberately:

- **The server** (`ui_server.coffee`) stays in the package. It's
  infrastructure; most projects won't modify it.
- **The static frontend** (`ui/index.html`) is *project-owned* —
  copied into your project root at install time so you can
  customize branding, add panels, swap libraries, whatever — without
  forking the runner. Updates to the package don't overwrite your
  edits.

```sh
# One-time: copy the shipped ui/ into your project root.
npx pipeline-runner ui:init        # use --force to overwrite later

# Start the server (default port 4311; override via UI_PORT).
npx pipeline-runner ui             # then open http://127.0.0.1:4311
```

The server resolves the static frontend project-first: `CWD/ui/`
wins, falling back to the package's `ui/` only if you haven't
run `ui:init` yet. So a fresh install works immediately, and your
edits stick once you've initialized.

## Starting-point recipes (the `_ite` family)

Beyond the teaching pipeline, the runner ships a set of *iterative*
recipes pulled from the source project as starting points. They live
in `config/*_ite.yaml` with step scripts under `scripts/*_ite/`:

| recipe                       | what it does                                          |
|------------------------------|-------------------------------------------------------|
| `diary_ite.yaml`             | walks a story library, generates diary entries with and without a trained LoRA adapter for A/B comparison |
| `diary_translate_ite.yaml`   | rewrites previously-generated diary entries through a trained adapter |
| `lora_ite.yaml`              | selects untrained stories, builds a LoRA dataset, spawns `mlx_lm.lora`, records the run |
| `oracle_ite.yaml`            | extracts KAG (keyword + headline) rows from raw stories via an oracle model, with backoff on failure |
| `prompt_ite.yaml`            | generates new story-seed prompts from an instruction template |

**These are templates, not turnkey pipelines.** Several reference
supporting scripts (`scripts/story/*.coffee`, etc.) that are NOT
shipped with the runner — those are project-specific content that
stays in the upstream `writeStory` repo. Use these recipes as
worked examples of what an iterative MLX/sqlite pipeline looks
like; copy + adapt the steps and configs into your own project.

## Make it yours

The runner looks for these directories in your project root and
**merges them with the shipped versions**:

| dir            | what it's for                                               | who wins on conflict |
|----------------|-------------------------------------------------------------|----------------------|
| `config/`      | pipeline recipes (YAML)                                     | project              |
| `override/`    | per-recipe overrides — params, swapped step lists           | project              |
| `scripts/`     | step implementations (`.coffee` with `@step =` export)      | project              |
| `meta/`        | custom meta devices (extra file formats, DB backends, …)    | project              |
| `ui/`          | static frontend (`index.html`) for the optional UI server   | project              |

**None of these are scaffolded automatically.** You `mkdir` them only
when you actually need them. A project that just wants to run the
shipped pipelines and override their params needs only `override.yaml`.

### Override a step
Drop a file at `scripts/<step_name>.coffee` exporting a `@step =` block.
The runner prefers project scripts over module-shipped ones, so you
can override or extend behavior without forking.

### Add a recipe
Drop a recipe at `config/<myname>.yaml`. Use
`include: [base_ite.yaml]` to inherit the bootstrap steps shipped by
the runner. Point your `override.yaml` at it via `pipeline: myname`.

### Add a meta device
Drop a `meta/<myname>.coffee` exporting a function that calls
`memo.addMetaRule(name, regex, handler)`. Project meta devices load
alongside the shipped ones; project wins on filename collision.
First regex match wins for any given key, so don't write a regex
broader than `meta/slash.coffee`'s catch-all.

## What the runner won't do

- **Manage your Python install.** The MLX surface (validation at
  startup, `callMLX`) is currently in the runner core. We ship a
  minimal `requirements.txt` (three packages — `mlx`, `mlx-lm`,
  `mlx-metal` — at pinned versions). Beyond that, your project owns
  its own `.venv` extensions. If you need additional Python
  packages, add them to a project-local `requirements.txt` and
  install alongside.
- **Persist state to a remote.** All state lives in `state/` and
  `runtime.sqlite` under your project root. Bring your own
  backup/replication if you need it.
- **Manage secrets.** Use the standard
  `export FOO=bar` / `.envrc` / `direnv` patterns. The runner sees
  `process.env`.

## Roadmap

The current shape works but several seams are intentionally left for
future extraction:

- **MLX as a plugin.** The `validatePythonEnvironment` and `callMLX`
  pieces should leave the core and become an opt-in
  `@jahbini/pipeline-runner-mlx` package. Non-MLX projects (data
  wrangling, web scraping, code review pipelines) shouldn't need
  Python.
- **`pipeline-runner init` subcommand.** Currently you copy
  `override.test.yaml` by hand. An `init` subcommand should write
  it for you, plus the `package.json` script entry and `.gitignore`
  additions.
- **First-run welcome.** If there's no `override.yaml` and no
  `control_override.yaml`, the runner errors. It should instead
  write a starter `override.yaml` pointing at `pipeline: test` and
  proceed, so a fresh `npm install` + `npx pipeline-runner` works
  in two commands instead of three.
- **`env/*` keys shouldn't materialize.** The runner currently
  writes `env/CWD`, `env/EXEC`, etc. into a real `env/` directory
  via the slash meta. They should be in-memory only.

## License

ISC. See [LICENSE](LICENSE).
