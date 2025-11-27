# 🧠 Celarien Pipeline System

This document describes the structure, behavior, and conventions of the **Celarien Pipeline Runner** and its companion **Evaluator** system.  
It defines how all pipeline scripts communicate, execute, and persist results using a shared **Memo** runtime.

---

## ⚙️ Overview

The pipeline is a **flat dependency graph** defined by top-level YAML keys.  
Each key represents a *step* that executes when its dependencies are satisfied.  
The runner uses a reactive in-memory object called `@memo` to connect all steps and to persist their results automatically.

- All CoffeeScript steps run *inside the same Node process*.
- All data written to `.json` or `.csv` memo keys are automatically flushed to disk.
- Dependencies are declared with `depends_on`.
- Every step runs once, in topological order, but execution is reactive and asynchronous.

---

## 📁 Directory Structure

The **current working directory (CWD)** is the **run directory**.  
All step output, reports, and memo-persisted files live here.

```
CWD/
 ├── experiment.yaml          # merged recipe + defaults + override
 ├── logs/                    # stdout/stderr logs from the runner
 ├── params/                  # individual step params (optional)
 ├── data/                    # training / input / transformed data
 ├── results/                 # final model or output artifacts
 ├── reports/                 # human-readable summaries (CSV/JSON)
 ├── eval_out/                # memo-persisted files (*.json, *.csv)
 └── ...                      # any step-specific files
```

> No separate `run/` prefix is required — the runner now treats the CWD as the pipeline root.

---

## 🧩 Core Components

### 1. `pipeline_runner.coffee`

Main orchestrator that:
- Builds `experiment.yaml` (merging recipe + defaults + override).
- Creates one global `Memo` instance.
- Executes steps declared in the recipe according to their `depends_on` order.
- Provides `M.mlx_runner()` for declarative MLX subcommands.

### 2. `Memo` Class

The shared reactive kernel for all steps.

#### Key Features
- `M.saveThis(key, value)` → stores data and notifies dependents.
- `M.waitFor(keys, callback)` → triggers callback when keys are ready.
- `M.enableFilePersistence()` → auto-writes `*.json` and `*.csv` keys to disk.
- Regex listeners for automatic file writing.
- Each `@step` shares the same `M` instance (no process boundaries).

> Any memo key containing a `/` or `.` is treated as a potential file path and will be written to disk automatically.

### 3. `pipeline_evaluator.coffee`

A parallel tool for evaluation and judgement:
- Runs evaluation steps (flat-map schema only).
- Can aggregate multiple experiment directories (“Courtroom Mode”).
- Writes summaries to `judgement_summary.json|csv|md`.

---

## 🧱 Step Definition (Standard Form)

Every CoffeeScript step must use the **`@step` notation**:

```coffee
@step =
  desc: "One-line description of what this step does."
  action: (M) ->

    console.log "🚀 Running #{process.env.STEP_NAME}..."
    # Do work here
    M.saveThis 'intermediate.json', { foo: 42 }

    # Mark completion (optional but helps debugging)
    M.saveThis "done:#{process.env.STEP_NAME}", true
    return
```

### Why use `@step` notation?
- Ensures inline execution within the pipeline process.
- Shares the same memo (`M`) across all steps.
- Enables automatic persistence and dependency tracking.

---

## 🔗 Declaring Dependencies

Each step declares its prerequisites using `depends_on`.  
Steps run when all dependencies have emitted `done:*` memo signals.

Example:

```yaml
data_prep:
  run: tests/step1_setup.coffee

train_model:
  run: tests/step2_train.coffee
  depends_on: data_prep

evaluate:
  run: tests/step3_eval.coffee
  depends_on: [train_model]
```

The runner computes a **topological order** and launches root steps immediately.

---

## 🧬 Spawned Processes (inside a step)

Steps may spawn external commands while staying memo-aware:

```coffee
{ spawnSync } = require 'child_process'

@step =
  desc: "Run Python subprocess"
  action: (M) ->
    result = spawnSync('python', ['-V'], encoding: 'utf8')
    M.saveThis 'python_version.json', { version: result.stdout.trim() }
    M.saveThis 'done:step7_python', true
```

This preserves memo semantics (same process) while executing arbitrary tools.

---

## 📊 File Persistence

When file persistence is enabled:

- `M.saveThis "foo.json", {...}` → writes `CWD/foo.json`
- `M.saveThis "bar.csv", [...]` → writes `CWD/bar.csv`
- `M.saveThis "done:step", true` → *not* written (non-file key)

This happens automatically through regex listeners.

---

## 🔄 Execution Flow

1. `pipeline_runner.coffee` loads and merges configs.
2. It discovers runnable steps from the YAML.
3. It builds the DAG based on `depends_on`.
4. For each step:
   - Wait for dependencies’ `done:` keys.
   - Invoke `@step.action(M)` inline.
   - Save any memo updates to disk.
5. When all terminal steps finish, the runner exits.

---

## 🧪 Testing Pipelines

The included test steps illustrate core behaviors:

| Step | Description | Demonstrates |
|------|--------------|---------------|
| `step1_setup` | Initializes memo state | Memo basics |
| `step2_transform` | Transforms JSON input | Data chaining |
| `step3_table` | Creates a CSV table | Auto persistence |
| `step4_wait` | Waits for prior completion | Dependency control |
| `step5_finalize` | Writes summary | Final artifact |
| `step6_curl` | Runs a curl command | External spawn inside step |
| `step7_python` | Runs Python -V | Memo + subprocess pattern |

All steps are memo-aware and use the `@step` pattern.

---

## 🧰 Debug Mode

Set `DEBUG=1` in the environment to make the runner **touch outputs** instead of executing steps.  
Useful for validating pipeline wiring.

---

## 🧭 Design Principles

1. **No Defaults in Global Scope**  
   The runner never creates implicit memos. All context comes from the loaded pipeline.

2. **Inline Execution by Default**  
   CoffeeScript steps always share one runtime.  
   Spawning is reserved for non-CoffeeScript steps.

3. **File-Based Reactivity**  
   The memo automatically bridges in-memory keys to disk artifacts.

4. **Declarative Dependency Graph**  
   Pipelines use `depends_on` for clarity and reproducibility.

5. **Reproducible Environments**  
   Each run directory is fully self-contained — copy it to re-run or re-evaluate.

---

## 🧩 Future Extensions

- Memo proxy bridge for true external processes.
- Scheduler control for worker concurrency.
- Incremental caching between runs.
- Integration with RAG / emotion-state writer pipelines.

---

**Celarien Pipeline System**  
_“A unified architecture for story-aware, memo-reactive computation.”_
