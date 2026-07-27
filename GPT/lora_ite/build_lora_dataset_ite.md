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

Token budgeting & truncation contract (verified 2026-07-25):
- Budget: `MAX_TOTAL_TOKENS = 1024`, `SAFETY_TOKENS = 64`; per row
  `maxCompletionTokens = 1024 - promptTokens - 64`.
- **It CHUNKS, it does NOT truncate and does NOT drop long content.** When the
  accumulated completion would exceed the budget, `flushChunk` emits the
  current paragraphs as a finished row and starts a fresh chunk with the next
  paragraph — the cut is at a **paragraph boundary**, same `prompt` re-used on
  each row. A single paragraph over budget drops to a finer split at
  **sentence boundaries**. So a long group becomes several rows
  (`prompt + contiguous slice`); nothing is silently lost here.
- **`estimateTokens` is `ceil(chars/4)` — an estimate, NOT the real
  tokenizer.** The 1024 budget is approximate. Dense/unusual prose (i.e. the
  stylistically distinctive text) can tokenize *higher* than chars/4 predicts,
  eroding the gap to the trainer's real cap.
- **The one genuine silent tail-loss path:** a single *sentence* longer than
  the budget can't be split further — it is emitted as one **oversized** row
  (> `MAX_TOTAL_TOKENS`). If that row also exceeds the trainer's
  `maxSeqLength` (default 2048), `mlx/lora/train.coffee` head-keeps and
  **tail-drops it silently** (`ids[...maxSeqLen]`, no warning). Narrow but real.
  The builder's own budget never fires the trainer warning, so this loss is
  invisible unless you look for it.
- Over-large *prompt* is a **hard crash, not a drop**: if the fragment prompt
  estimates > ~880 tokens, the step throws `prompt too large for token budget
  on story <id>`.

Training-shape note (interacts with the trainer):
- The same fragment prompt is prepended to EVERY chunk of a long group, and
  the trainer's loss mask is **pad-only — prompt tokens are NOT masked**
  (`mlx/lora/train.coffee` buildBatch). So a long distinctive passage is
  fragmented across rows at arbitrary budget boundaries, each decontextualized
  except the shared opening fragment. Content survives; stylistic continuity
  across the passage does not. This is closer to the real training cost than
  truncation would be. See `GPT/lora_ite/train_contract.md` for the trainer
  contract (pad-only mask, head-truncation, no EOS, uncapped KV) and
  `GPT/lora_ite/log_scan_reference.md` for the OOM linkage.

Known pitfalls:
- this step used to carry inference-style scaffolding; do not restore it
- short stories are common near the end of a LoRA cycle; do not let the prompt
  fragment consume every paragraph in a two-paragraph story
- one-paragraph stories should produce a simple prefix/continuation row when
  the paragraph is long enough, rather than causing a zero-row batch shutdown
- edge drops (small, not the long paragraphs): a completion paragraph under
  120 chars / 24 words that hits `splitSingleParagraphTrainingText` returns
  null and yields no row; an empty first paragraph makes `buildFragmentParagraphs`
  return empty and the whole group is skipped
