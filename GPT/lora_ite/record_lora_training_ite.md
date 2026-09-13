Step: `record_lora_training_ite`
Recipe: `train_lora` (also runs inside composite `elementary`)

Purpose:
- persist LoRA run metadata into SQLite and materialize trained story ids

Inputs:
- artifact `lora_run_record`

Outputs:
- meta write `loraTrainingRun{run_id}.json`
- artifact `trained_story_ids`

SQLite effect:
- `meta/sqlite.coffee` expands `loraTrainingRun{run_id}.json` into:
  - `lora_training_runs`
  - `lora_training_run_stories`
  - `lora_story_usage`

Invariants:
- DB bookkeeping belongs here, not hidden inside MLX execution
- if bookkeeping fails, it should fail visibly here
- **Adapter-file existence is verified before story usage advances**
  (2026-09-13). If `lora_run_record.adapter_path` has no checkpoint
  or `adapters.safetensors` on disk, the run row is still written to
  `lora_training_runs` — but with `status='no-adapter'` and empty
  `story_ids`, so `lora_training_run_stories` stays empty for this
  run. `select_lora_stories_ite` will re-pick those stories on the
  next elementary launch. This is belt-and-suspenders behind the
  same check in `run_lora_train_ite`, so a regression at either
  layer can't silently mark 169 stories "trained" with no adapter
  to show for it. Fingerprint of the pre-fix bug:
  `sqlite3 runtime.sqlite 'SELECT status FROM lora_training_runs'`
  reports `done` and `lora_training_run_stories` COUNT = 169, but
  `build/adapter/adapters.safetensors` doesn't exist.

Known pitfalls:
- file artifacts can succeed while DB bookkeeping fails if this contract is bypassed
- test-only runs (`mode='test'`) skip the adapter-existence check —
  they can't produce one by definition, and their story usage is
  intentionally recorded so the test coverage tracking works.
