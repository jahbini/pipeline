Step: `select_lora_stories_ite`
Recipe: `train_lora` (was `lora_ite`; also runs inside composite `elementary`)

Purpose:
- pick the next batch of stories for LoRA training

Inputs:
- meta read `loraStoryUsage.jsonl`
- artifact `lora_cycle_state` via `peek`

Outputs:
- artifact `selected_story_ids`
- artifact `lora_remaining_count`
- artifact `lora_cycle_state`
- possible meta write `loraCycleReset.json`

Selection rule:
- prioritize stories by lowest `use_count`
- when several stories share the same `use_count`, shuffle within that bucket instead of using a fixed story-id order

Cycle rule:
- when no stories remain, mark cycle complete and emit an empty
  `selected_story_ids` (no `pipeline:shutdown` — see 2026-09-12
  fix: shutting the pipeline down inside a composite recipe like
  `elementary` would halt the outer recipe mid-flight).
- on the next fresh start with `ready_for_reset`, reset LoRA usage and start a full retrain

Invariants:
- fresh DB should still run if `stories` exist and LoRA tables are empty
- `lora_remaining_count` is the UI-facing remaining count

Known pitfalls:
- if `stories` is empty, this step will correctly find nothing to train
- that usually means `base_ite` seeding failed upstream
