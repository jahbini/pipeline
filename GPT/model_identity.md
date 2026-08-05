# Model identity — where it lives

Session: 2026-08-05.

## Rule

**The model is a pipe fact, not a recipe fact.**

Recipes in `config/` do NOT set `run.model`. Every pipe declares
its own model identity in its `override.yaml`:

```yaml
run:
  model: <org>/<model-name>
```

## Rationale

The old pattern hardcoded `run.model: Qwen/Qwen3-4B-Instruct-2507`
in each recipe's `run:` block, then relied on pipe-level overrides
to swap it. That produced two failure modes:

- A fresh pipe with no `run.model` override silently inherited
  `Qwen/...` from the recipe, downloaded the wrong model, and
  gave no visible clue what happened.
- Pipes named after the model they should use (e.g.
  `pipes/Huihui-Qwen3-4B-Instruct-2507-abliterated`) had no
  enforced correspondence — the recipe still won unless the pipe
  override was explicitly present.

Naming-based inference isn't strong enough: not every pipe encodes
a model in its name, and not every model id maps cleanly to a pipe
directory name.

## What changed (2026-08-05)

Stripped `run.model` from every recipe that had it (10 files):

- chat_llm.yaml
- diary_ite.yaml
- diary_translate_ite.yaml
- eval_ite.yaml
- fuse_llm.yaml
- oracle_ite.yaml
- prompt_ite.yaml
- reset.yaml
- train_llm.yaml
- train_lora.yaml

Each now carries a comment in its `run:` block pointing here.
`download_model.yaml` never had a `run.model` (its model is a
per-invocation param) and stays as-is. `test.yaml` has no model
reference either.

`scripts/model/download_model.coffee` — the existing
`throw new Error "Missing model param"` at the top of the action
is the loud-fail behavior the rule relies on. When a pipe forgets
to declare its model, that's the error a fresh user sees.

## Provenance file (post-download record)

After a successful download, the step writes
`<targetDir>/model_provenance.json` (VISIBLE — no leading dot) and
chmods it read-only (0o444). Renamed from `.model_provenance.json`
2026-08-05.

Constraints, all satisfied:

- **Name has no leading dot** — `ls` shows it without `-a`.
- **Read-only after write** — chmod 0o444 by the download step so
  a stray `cat > model_provenance.json` cannot silently corrupt
  the provenance. `writeProvenance` chmods to 0o644 first if a
  read-only version already exists, writes, then re-chmods 0o444.
- **Content unchanged** — same JSON payload
  (`{model_id, repo_url, recorded_at}`) that
  `readProvenance()` already understands.

Downstream consumers call `provenancePathFor(targetDir)` which now
returns the visible name; the mismatch/no-provenance/skip-download
branches all Just Work.

## "Refuse to overwrite populated dir" guard (same session)

Also added to `download_model.coffee`: after the three existing
provenance branches, if the target directory has ANY files AND the
run has NOT opted in with `allow_overwrite: true`, throw a
contextual error naming the dir and telling the human to either
`rm -rf` it or set the flag explicitly.

The intra-retry `removeTargetDirectory` inside the retry loop is
unchanged — that's a robustness feature for LFS flakiness within a
single authorized run. The guard only fires at the START, before
the retry loop is entered, so it can't destroy state without an
opt-in.

Escape hatch:

```yaml
download_model:
  allow_overwrite: true
```

Remove that key once the download completes so a future killed run
can't inherit the permission.

## Rename for existing installs

If any machine has a pre-cutover `.model_provenance.json` file:

```sh
mv <targetDir>/.model_provenance.json <targetDir>/model_provenance.json
chmod 0444 <targetDir>/model_provenance.json
```

The read helper looks up ONLY the new name — a legacy dot-file
looks like "no provenance recorded" and the download step will
throw the appropriate contextual error.
