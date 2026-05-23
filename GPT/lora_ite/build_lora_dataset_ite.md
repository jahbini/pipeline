Step: `build_lora_dataset_ite`
Recipe: `lora_ite`

Purpose:
- build `train.jsonl`, `valid.jsonl`, and `test.jsonl` from SQLite-backed stories

Inputs:
- artifact `selected_story_ids`
- meta reads `storyByID{story_id}.json`

Outputs:
- artifacts `train_rows`, `valid_rows`, `test_rows`

Current segmentation:
- split each story into 5 paragraph groups when paragraph count >= 5
- if paragraph count < 5, use all paragraphs as one group

Training format:
- minimal prompt
- each row is just fragment text, two newlines, then continuation text
- no instruction preamble
- no `Begin:`
- no `<stop>`

Invariants:
- use SQLite-seeded cleaned text, never raw `jim.md`
- skip groups with no continuation

Known pitfalls:
- this step used to carry inference-style scaffolding; do not restore it
- short stories are common near the end of a LoRA cycle; do not let the prompt
  fragment consume every paragraph in a two-paragraph story
- one-paragraph stories should produce a simple prefix/continuation row when
  the paragraph is long enough, rather than causing a zero-row batch shutdown
