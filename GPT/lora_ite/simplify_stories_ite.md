Step: `simplify_stories_ite`
Recipe: runs inside composite `elementary`
File: `pipeline/scripts/lora_ite/simplify_stories_ite.coffee`
Added: 2026-09-12

Purpose:
- For each story that has `kag_entries` but no `story_simplifications`
  row yet, ask the pipe's LOCAL quantized model to retell the story in
  plain, straightforward language — stripping Jim's wordplay and
  unusual phrasing, keeping only the sequence of events and content.
- These plain retellings become the PROMPT half of every LoRA
  training row (see `build_lora_dataset_ite`). The COMPLETION half is
  Jim's original story text. The adapter thus learns
  "given plain content → produce Jim's voice."

Contrast with the (rejected) `simplify_chunks_ite` design:
- That design paraphrased per-KAG-chunk (paragraph-level), for
  emotional-signal work. Whole-story simplification is a
  style-transfer signal — a different purpose that needed a whole
  story of context to be useful.
- The `chunk_simplifications` sqlite table, its meta rules, and the
  `chunkSimplification{sid|idx}` memo keys were all removed
  2026-09-12. Do not restore them for a LoRA use case.

Inputs:
- meta read `storySimplificationsMissing.jsonl` — sqlite-projected view
  of `stories WHERE EXISTS kag_entries AND NOT EXISTS story_simplifications`.
  Rows: `{story_id, text, …}`.
- step param `quantized_model_dir` — required; the LOCAL model, no
  HFChat / no external token budget.
- step param `batch_size` — required, positive integer. Stories per
  invocation.
- step param `prompt_template` — optional; defaults to a template with
  a `{{{STORY}}}` placeholder that is replaced verbatim per row.
- step param `llm` — optional map merged into the `callLLM` args (all
  values except `op` are forwarded).

Outputs:
- Per-story meta write: `storySimplificationRegister{sid}.json`
  → one row in `story_simplifications` (sqlite is the source of
  truth; no JSONL persistence).
- Step artifact: `simplify_remaining_count`.

Iterate contract:
- Uses step-scoped `L.iterate()` (2026-09-11): after each batch, if
  work remains, re-fires the step with `storySimplificationsMissing.jsonl`
  invalidated so the next batch reads fresh sqlite state. When the
  view is empty, the step just `L.done()`s — no `pipeline:shutdown`
  emission (that would halt the composite `elementary` recipe
  mid-flight, same failure mode fixed in `oracle_ask_sqlite` and
  `select_lora_stories_ite`).

Skip cases (logged, not fatal):
- row missing `story_id` or `text` → skipped
- `L.callLLM` throws → skipped, next row proceeds
- generation is empty after prompt-echo strip → skipped
Failures never poison the batch; a re-fire retries missed rows via
the sqlite view.

Elementary-recipe placement:
- `reset` → `oracle_ask_sqlite` → `reembed_chunks_clean` →
  **`simplify_stories_ite`** → `select_lora_stories_ite` →
  `build_lora_dataset_ite` → `run_lora_train_ite` → `record_lora_training_ite`.
- Elementary's business-truth verifier in `queue_run_ite` treats a
  pipe as done for the `simplify` sub-goal when the
  `story_simplifications` row count matches the kag-populated story
  count. See `hf_queue_gen_ite.coffee` `simplify_pending` probe.

Related:
- `pipeline/GPT/lora_ite/build_lora_dataset_ite.md` — consumes these
  rows as the prompt half of training pairs.
- `pipeline/GPT/hfchat_meta.md` is NOT relevant here: this step
  intentionally uses the local `callLLM` path so completion
  runs cost nothing on the HF budget.
