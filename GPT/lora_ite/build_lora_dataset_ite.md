Step: `build_lora_dataset_ite`
Recipe: `train_lora` (composed inside `elementary`)

Purpose:
- build `train.jsonl`, `valid.jsonl`, and `test.jsonl` from SQLite-backed
  stories, in whole-story shape.

Inputs:
- artifact `selected_story_ids`
- meta reads `storyByID{story_id}.json`
- meta reads `storySimplification{story_id}.json` (produced upstream by
  `simplify_stories_ite`)

Outputs:
- artifacts `train_rows`, `valid_rows`, `test_rows`

Row shape (2026-09-13 fix — was silently broken 2026-09-12):
- **one row per whole story**, no fragment/paragraph-group splitting.
- Emitted as `{prompt, completion}` — the supervised shape mlx_lm.lora
  expects when `--mask-prompt` is on. Under the mask, loss is computed
  ONLY on completion tokens — the whole point of a style-transfer LoRA.
- `prompt`     = the plain-language retelling from `story_simplifications.simple_text`
- `completion` = the original Jim-voice `stories.text` + tokenizer's `eos_token`
- rationale: this is a supervised **style-transfer** signal — flat prose →
  Jim's word-play — not a next-paragraph continuation task.
- Stories with no `story_simplifications` row yet are **skipped with a log
  line**. `simplify_stories_ite` populates that row for every story that
  has kag_entries; a missing row means simplification hasn't caught up.
- 2026-09-13 fingerprint of the old bug: `head -1 build/train/train.jsonl`
  reports a single `text` key concatenating prompt + completion, and
  the trainer sees no mask → learns to reproduce plain prose too. If
  you see that shape on a live pipe, the code is stale; sync and
  regenerate via `reset` + `force_lora_reset` (and `force_oracle_reset`
  if the `story_simplifications` rows are also polluted by Qwen
  thinking-mode leakage — see `simplify_stories_ite.md`).

EOS supervision:
- reads `tokenizer_config.json` from the pipe's quantized model dir
  (`quantized_model_dir` param, falls back to `loraLand`).
- appends the model's `eos_token` to each `completion` so the trainer's
  loss covers the stop signal.

Train / valid / test split (unchanged):
- deterministic per-story bucketing: sort story ids, bucket by
  `index % (trainOut + validOut + testOut)`. Default 8 / 1 / 1.
- rows from one story never appear in more than one split, because the
  bucket is chosen per story-id — not per row (there's only one row per
  story anyway now, but the invariant matters if the shape ever changes
  back).

Drain-safe empty case (see 2026-09-12 note in the source):
- if the selected stories produce zero trainable rows (all skipped for
  missing simplifications), emit empty `train_rows` / `valid_rows` /
  `test_rows` and `L.done()`. Do **NOT** emit `pipeline:shutdown` — that
  would halt the outer composite recipe (`elementary`) mid-flight;
  downstream steps that consume zero rows will no-op cleanly and
  queue_run_ite decides what runs next.

Historical (removed 2026-09-12):
- `buildStoryGroups` (5-paragraph-group segmentation)
- `buildFragmentParagraphs` (fragment-prompt / continuation)
- `splitSingleParagraphTrainingText` (sentence-boundary fallback for
  single-paragraph stories)
- token-budget chunker with `MAX_TOTAL_TOKENS = 1024` / `SAFETY_TOKENS = 64`
- the "one silent tail-loss path" for oversized rows
- companion `build_lora_story_dataset_ite` chat-format step (never
  implemented past its doc)
All were replaced by the one-row-per-whole-story shape above. If a future
design needs fragmentation again, restart from the git history at
2026-09-12.
