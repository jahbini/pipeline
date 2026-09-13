Step: `reset_base_environment_ite`
Recipes: `reset` (human-invoked from writer UI), `newborn` (fresh-pipe audition)

Purpose:
- Clear stale artifacts as directed by the human via checkbox params.
- Bootstrap-initialize an empty sqlite schema on newborn pipes.

Design (2026-09-13 rewrite — see [reset_recipe.md](./reset_recipe.md)
for the failure that motivated it):

- **Default run (no force flags)**: wipe only transient `out/*.json`
  files. sqlite and every `build/*` dir preserved. Safe on any pipe.
- **`force_lora_reset: true`**: wipe `build/adapter`, `build/adapter_llm`,
  `build/model_fused_llm`. Fire `loraCycleReset` (clears
  `lora_training_runs` + `lora_training_run_stories` + `lora_story_usage`
  + `lora_trained_stories`).
- **`force_oracle_reset: true`**: fire `oracleReset` (clears `kag_entries`
  + both embedding tables + `story_simplifications` + attempt/parts
  scaffolding).
- **`force_download: true`**: wipe `build/model` and `build/model4`.
  Next `download_model` / `quantize_model` will re-run in full.
- **`force_full_reset: true`**: fire `sqliteResetAll` (nukes everything
  including stories). Wipe every `build/*`. Only use when you truly want
  a fresh pipe.
- **Bootstrap fallback**: if sqlite doesn't exist or has zero stories,
  `sqliteResetAll` fires regardless of the flags — this is what
  `newborn.yaml` relies on to install the schema on a fresh pipe.

Inputs:
- step params (all default `false`): `force_lora_reset`,
  `force_oracle_reset`, `force_download`, `force_full_reset`.
- Reads `runtime.sqlite` to detect bootstrap vs. populated states.

Outputs:
- Zero, one, or two meta writes among: `sqliteResetAll.json`,
  `oracleReset.json`, `loraCycleReset.json`.
- Removes selected stale files under `build/` and `out/`.

Reset contract:
- Must reset SQLite tables THROUGH `meta/sqlite.coffee` (via
  request-key writes). Never `db.exec DELETE` directly.
- Must not unlink `runtime.sqlite`. The runner has an open handle.
- Must leave the sqlite handle valid for later steps.

Invariants:
- Adapter file on disk ↔ `lora_training_run_stories` in sqlite. Both
  present together or both absent together. `force_lora_reset` is what
  keeps that invariant when the human wants a fresh training cycle.
- Stories table survives every reset except `force_full_reset`.

Known pitfalls:
- Deleting `runtime.sqlite` directly is a critical bug — the runner has
  already opened it. Always go through the meta reset rules.
- Skipping `force_lora_reset` on a pipe whose adapter was externally
  deleted (or never written) leaves the sqlite usage table full while
  no adapter exists — this is the self-defeating loop that motivated
  the 2026-09-13 rewrite. Business-truth check catches it, but human
  must run `reset` with `force_lora_reset: true` to escape.
- If a pipe has `stories` populated but you need to re-download a
  broken model, only `force_download: true` is needed — sqlite is
  preserved automatically.
