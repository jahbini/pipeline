This directory is assistant-owned working memory for recipe and step contracts.

Purpose:
- keep step-local memory outside the transient conversation
- record proven contracts and costly failure modes
- help trace downstream failures back to upstream causes
- preserve current pipe/workspace assumptions so future Codex work does not drift back to older top-level-only behavior

**Read this first when starting a session on anything DAG-shaped:
[`pipeline_architecture.md`](pipeline_architecture.md)** — the framework is
the universal starting point for notebook conversion / batch automation
across multiple unrelated domains (writeStory's ML pipelines + publicist's
PR outreach). When work is ambiguous, separate "framework orbit" from
"domain orbit" before acting.

Rules:
- keep files short and factual
- update a step memory when its contract changes
- prefer one file per important step
- record inputs, outputs, invariants, and pitfalls
- if a stale machine bug is diagnosed from logs, update the affected step memory so the failure mode is explicit
- do not use this directory for general notes or speculation
- universal verifier commandment: do not repeatedly execute a proven expensive
  baseline in smoke/default verification. Record the baseline timing/result as
  metadata and re-run the old path only under an explicit full/comparison
  profile or when its math contract changed.
- universal Rusty runtime commandment: do not rerun a path that has already
  been disproved for speed or memory just to refresh a comparison. Record the
  result in `rusty/STATUS.md` and refer to it. Current examples include
  long-generation CPU attention and full preallocated `expanded_kv` for
  `max_tokens=2000`, and MLX/OMP/VECLIB/RAYON thread-count runs at 8 and 12;
  normal tests should exercise the active current path.
- repository-level runtime verification is coordinated through root
  `test.sh`. The script is committed and stable — it rebuilds the native
  addon (`npx node-gyp rebuild`) and runs the 64-token gypsy generation
  probe at `test/helpers/native_64_mlx_lazy_generation_probe.coffee`. Treat
  it as the canonical "did the build work" command. Task-specific or
  exploratory test helpers go under `test/` (which is gitignored). When a
  test step is added to `test.sh`, record every step's `.log` and `.err`
  output under `test/logs/<run_id>/` so the result is auditable. If Python
  is ever needed, the script must activate `.venv` first with
  `source .venv/bin/activate`.

Current repository assumptions worth preserving:
- the repo is pipe-centric; active workspaces live under `pipes/<organization>_<model>/`
- **the runner's `CWD` is the pipe directory, `pipes/<pipe>/`. Run-state
  and run-config files are resolved relative to `CWD`, NOT the repo
  base.** So the operative files are:
  - `pipes/<pipe>/override.yaml` and `pipes/<pipe>/override/<recipe>.yaml`
  - `pipes/<pipe>/experiment.yaml`
  - `pipes/<pipe>/control_override.yaml`
  - `pipes/<pipe>/{state,out,params,data,runtime}/`
  The same-named files in the repo BASE directory
  (`/writeStory/override.yaml`, `/writeStory/experiment.yaml`, etc.) are
  meaningless stale leftovers — do not read or write them. Only
  `config/`, the runner, `ui_server.coffee`, `scripts/`, `agents/`, and
  `GPT/` live at the repo base and are shared across pipes.
- the `_ite` recipes are the production covering set of capabilities. Recipes
  without the `_ite` suffix (e.g. `full`, `story`, `train_lora`,
  `train_markdown`, `dialog_reword`, `kag_oracle`, `story_kag_chat`, `test`)
  are earlier-capability references and are not the production targets.
- each recipe is a 1:1 conversion of one Python notebook. Each step/script
  in a recipe is the direct equivalent of one notebook step. The DAG runner
  adds dependency edges (`needs` / `makes`), reactivity (the memo), and
  restartability on top of that notebook structure.
- persistence layers (by lifetime):
  - long-term, cross-run: per-pipe SQLite (stories, paragraph groups, KAG
    entries from the emotion oracle). New steps that produce reusable
    structured data should land it in SQLite.
  - transient, single-run: `out/`, `data/`, `params/`, `state/`. These are
    scratch space for one pipeline run. Diary/story generations also live
    here and are not (currently) recorded in SQLite.
  - crash-resume: when a recipe dies mid-DAG, `state/` and `params/`
    together let the runner pick up at the dead step on next launch. That is
    why the UI prominently features the `Pipeline Death` pane and the
    `Erase pipeline.json` button.
- overrides are recipe-scoped: prefer `override/<pipeline>.yaml` for human
  overrides associated with a selected config recipe
- legacy `override.yaml` remains a fallback/bootstrap file for older pipes and
  initial pipeline/model inference; when used for a selected pipeline it should
  be materialized into `override/<pipeline>.yaml` for future runs
- `control_override.yaml` is UI-owned run control, not a replacement for
  recipe-scoped human overrides
- **`experiment.yaml` is the materialized effective config of a run** —
  the fully-merged result of recipe + override + control_override with
  UI directives stripped, exactly what the runner consumed. When the
  human posts an `experiment.yaml`, treat it as the authoritative,
  exact source of what that run entailed. Do NOT speculate about
  recipe-vs-override provenance or "where a value came from" — the
  merged file IS the answer. It is per-run; like `out/lora_train.txt`
  it reflects the most recent run, not a whole multi-batch cycle.
- a `config/*.yaml` recipe block, an `override.yaml`, or any single
  pre-merge file is NOT the experiment.yaml. Only the merged
  `pipes/<pipe>/experiment.yaml` is authoritative for what a run did.
  Do not quote a recipe block as if it were the run's effective config.

WORKING DISCIPLINE (human directive, May 2026):
- do not build opinions or assert conclusions from partial, pre-merge,
  or possibly-stale data. If a fact depends on a file the assistant
  cannot see — anything on the mac-mini, or any pipe-local file not
  pasted into the conversation — ASK for it. Do not theorize a value
  and then carry that theory forward as established fact.
- the assistant has NO access to the training mac-mini. Every fact
  about that machine's state (its `experiment.yaml`, `override.yaml`,
  `out/lora_train.txt`, adapter files) must come from the human pasting
  it. When such a fact is needed and absent, ask — don't guess.
- when the human tries to stop or redirect, stop immediately. Do not
  keep executing on input that is being retracted or corrected.
- **`override/<recipe>.yaml` is THE single control surface for recipe
  parameters. Do not invent parallel config mechanisms** (no extra
  `--config` files, no bespoke per-tool config passers). The control
  chain is: `config/<recipe>.yaml` (baseline) → `override/<recipe>.yaml`
  (human control) → `control_override.yaml` (UI) → the step's `mlx:`
  block → `callMLX` `buildArgs` turns every key into `--key value` → the
  external tool. If a parameter cannot be expressed as a valid flag at
  the end of that chain, it is not meant to be tuned — it rides on the
  tool's default. Example: `mlx_lm lora` accepts `batch-size`, `iters`,
  `max-seq-length`, `learning-rate`, `num-layers` as flags, so those are
  override-controllable; LoRA `rank` / `scale` / `dropout` are NOT CLI
  flags, so they ride on mlx-lm defaults (`rank: 8`, `scale: 20.0`,
  `dropout: 0.0`) and the gypsy inference-side `generation_adapter_scale`
  is set to match that `20.0` default — do not "fix" it down to an
  alpha/rank-style value; mlx-lm does not use the alpha/rank convention.
- **HARD RULE (human directive, May 2026): the assistant does NOT edit
  `config/*.yaml` recipe files for tuning.** Recipes are the stable
  baseline. Every parameter change — `iters`, `max-tokens`, `temp`,
  adapter paths, anything — goes in `override.yaml` (or
  `override/<recipe>.yaml`). Creating a brand-new recipe file when the
  human explicitly asks for one is allowed; editing an existing recipe's
  values is not. If a recipe value looks wrong, express the correction
  as an override entry and tell the human — do not reach into the
  recipe. (This was added after the assistant repeatedly edited
  `config/lora_story_ite.yaml`'s `iters` value mid-session instead of
  using an override.)
- new empty pipes infer their model identity from the pipe directory name
- `base_ite` now owns base preparation through quantization, so downstream inference recipes consume prepared artifacts instead of rebuilding them
- the UI drives recipe fields through recipe-declared directives, currently `UI_dropdown`, `UI_checkbox`, and `UI_textarea`
- the UI layout is intentionally split into:
  - left column for death/output/step/log visibility
  - right column for one merged controls pane
- the UI should not poll every 2 seconds all the time; it polls continuously
  while EITHER a pipeline run OR a merge job is active, and stops otherwise
  so the user can edit fields without the UI yanking values back from disk
  (see `GPT/ui/ui_server.md` for the full polling gate rule)
- the two native generation paths live on sibling git branches:
  - `main` (this branch): `gypsy/` is populated. `rusty/` is empty.
    The production native addon is gypsy (`metal/metal_llm.node`, built
    via `binding.gyp` against system MLX). See `gypsy/STATUS.md` and
    `GPT/gypsy_strategy.md` for live status and standards.
  - `rusty` branch: `rusty/` is populated. `gypsy/` is empty. Rusty was
    the earlier teaching/correctness path for the token journey through
    the model.
- references to Rusty in `gypsy/README.md`, `gypsy/PROTOCOL_DESIGN.md`,
  `gypsy/DIRECTIVE_FAILURES.md`, and `GPT/gypsy_strategy.md` are
  cross-branch architectural lessons kept on `main` on purpose — they
  describe what Rusty taught, not where Rusty's code lives. To consult
  Rusty's actual source, `git checkout rusty`.

Suggested use:
- when a step fails, inspect its memory file first
- if the real cause is upstream, follow the listed dependency chain
- when code changes invalidate a memory file, update it in the same work
- for the `rusty/` bridge work, prefer explicit CLI Q/A probes for tensor and
  model inspection, not answers-only logging
