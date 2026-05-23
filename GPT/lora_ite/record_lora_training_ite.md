Step: `record_lora_training_ite`
Recipe: `lora_ite`

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

Known pitfalls:
- file artifacts can succeed while DB bookkeeping fails if this contract is bypassed
