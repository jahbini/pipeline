# Developer README — Pipeline Step Template (2025 Edition)

This document explains how to create and maintain CoffeeScript steps compatible
with the unified **Memo-aware pipeline runner**.

---

## 🧩 Step Structure

Each step lives in `scripts/` and must export an object named `@step`:

```coffee
@step =
  desc: "Human-readable description"
  action: (M, stepName) ->
    # your code here
```

The pipeline runner automatically passes:
- **M** → the global Memo instance (shared cache and reactive store)
- **stepName** → the key under which this step appears in `experiment.yaml`

---

## ⚙️ Configuration

All configuration comes from the memo entry `experiment.yaml`:

```coffee
exp = M.theLowdown('experiment.yaml').value
runCfg  = exp?.run or {}
stepCfg = exp?[stepName] or {}
```

This replaces the old `load_config()` and all `process.env` lookups.

---

## 🧠 Memo Integration

Steps use the shared Memo for all I/O coordination.

Typical keys:
- `"done:<stepName>"` → boolean, signals completion
- `"<stepName>:result"` → step result object
- `"<stepName>:output_path"` → output file path

Example:
```coffee
M.saveThis "#{stepName}:result", result
M.saveThis "done:#{stepName}", true
```

---

## 🪶 Logging

Each step should create a log file under `<output>/logs/` using:

```coffee
log = (msg) ->
  stamp = new Date().toISOString().replace('T',' ').replace(/\..+$/,'')
  fs.appendFileSync LOG_PATH, "[#{stamp}] #{msg}\n", 'utf8'
  console.log msg
```

---

## 🧪 Determinism

A valid step must be deterministic:
- No random seeds without explicit control.
- No external environment assumptions.
- No hardcoded paths or hidden dependencies.

---

## 🧱 File Layout (CWD = run directory)

```
logs/           per-step logs
data/           processed datasets
params/         serialized step parameter files
results/        model outputs
reports/        evaluation results
state/          progress checkpoints
```

---

## 🧭 Best Practices

- **Never** reference `process.env` directly.
- **Never** create your own Memo instance.
- Keep all reads/writes deterministic.
- Store step outputs into `M.saveThis` for reuse.
- Return `undefined` (the runner doesn’t inspect return values).

---

## 🧰 Example

See `scripts/999_template.coffee` for a working skeleton.
Replace the `processFile` function with your step logic.
