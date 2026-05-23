Step: `build_lora_story_dataset_ite`
Recipe: `lora_story_ite`

Purpose:
- build chat-formatted `train.jsonl`, `valid.jsonl`, and `test.jsonl` from
  SQLite-backed stories
- companion to `build_lora_dataset_ite`; differs only in output row format

Inputs:
- artifact `selected_story_ids`
- meta reads `storyByID{story_id}.json`

Outputs:
- artifacts `train_rows`, `valid_rows`, `test_rows` — each row is shaped
  `{"messages": [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]}`

Current row design (May 2026, voice-transfer LoRA):
- `assistant` content: the ENTIRE paragraph group — all voice prose lives here
- `user` content: a short generic instruction with NO story prose embedded
- One row per group. No fragment/completion split. No sentence-level fallback.
- Single-paragraph stories: one row, whole paragraph as assistant content.
- Token budget: 1024 total, 96 reserved for chat-wrapper overhead. Groups that
  exceed the budget are skipped with a log line (cannot split them anymore).

Why this design (contrast with the prior inverted design):
- The OLD design put the first 1-2 paragraphs of a group in the user turn as a
  "seed text," and only the remaining paragraphs in the assistant turn. This put
  Jim-voice prose in the USER role — teaching the adapter "user messages look
  like the target voice." Exactly inverted from the intent.
- The NEW design keeps ALL voice prose in the assistant turn. The user turn is
  a short instruction containing no target-voice prose. The adapter trains to
  produce the voice in response to a prompt, not to mimic the prompt.

User instruction pool (current — rotating, deterministic):
- 7 short generic instructions: "Write a passage in your distinctive voice.",
  "Tell me a story in your voice.", etc.
- Rotation is deterministic on (rowIndex, storyID). storyIDs are non-numeric
  strings; the offset is a char-code sum — never `Number(storyID)` which
  returns NaN. (This was a real crash bug, fixed May 2026.)

PENDING DESIGN CHANGE — "Jim writes" trigger phrase:
- Replace the rotating pool with a single fixed string: `"Jim writes"`
- Train WITHOUT mask_prompt so the loss covers those two tokens explicitly
- The adapter then learns: "Jim writes" in user turn → Jim's voice in assistant
- At inference, any prompt containing "Jim writes" activates the learned behavior
- Remove `mask-prompt:` from `run_lora_train_ite.mlx` in the pipe override
- This change must be made BEFORE the next training run on the mac-mini

mask_prompt / --mask-prompt:
- `--mask-prompt` IS a valid mlx_lm lora CLI flag (mlx_lm/lora.py:118,
  `action="store_true"`)
- When true: loss is computed only over assistant tokens; user tokens are
  context only
- Currently wired in `pipes/Qwen_Qwen3-4B-Instruct-2507/override.yaml` under
  `run_lora_train_ite: mlx: mask-prompt:` (null value → only the flag is
  pushed, no spurious positional arg)
- With the fixed "Jim writes" trigger, mask_prompt should be REMOVED so the
  adapter explicitly learns the trigger → voice mapping through loss on the
  trigger tokens too

Segmentation (unchanged):
- 5 paragraph groups when paragraph count >= 5 (buildStoryGroups)
- If paragraph count < 5, one group with all paragraphs

Invariants:
- assistant content is plain prose from the corpus, no trailing marker tokens
- use SQLite-seeded cleaned text, never raw `jim.md`
- `train_rows`, `valid_rows`, `test_rows` all contain the same rows
  (full-corpus-for-all-splits is the established convention in this repo)

Known pitfalls:
- if `chat: false` is set in `generate_prompt_gypsy_ite`, training on this
  step's output is the wrong distribution — switch back to
  `build_lora_dataset_ite` or change inference to `chat: true`
- story IDs are NON-numeric strings. Any hash/index code must not use
  `Number(storyID)` — it returns NaN. Use char-code sum (`storyOffset`).

Training-cycle design (with `select_lora_stories_ite` +
`run_lora_train_ite`) — CONFIRMED with the human May 2026:

This recipe trains in MANY TINY GENTLE BATCHES, not one big run. The
mental model "iters = total training budget" is WRONG here.

- `select_lora_stories_ite` selects only `batch_size: 4` stories per
  cycle → this step emits roughly 4-20 chat rows per cycle, NOT the
  full corpus.
- `run_lora_train_ite` RESUMES on `build/adapter/adapters.safetensors`.
  The resume IS the accumulation mechanism — each 4-story batch builds
  on the prior batch's adapter. The voice accumulates across dozens of
  batches, not within any one batch. NEVER "fix" a problem by deleting
  the adapter mid-cycle; that throws away the whole accumulated run.
- the UI continuous-loop repeats batch after batch until every story is
  consumed, then `select_lora_stories_ite` shuts the pipeline down. One
  full loop = one pass over all stories.
- small batches are also fault tolerance: a power loss or thermal
  shutdown on the training mini only costs the in-flight batch.
- `iters` is PER BATCH and must stay tiny (~5). Each batch should only
  NUDGE the adapter. Driving a single batch to low loss memorizes that
  batch; across the loop that produces an overfit / no-output adapter.
- `out/lora_train.txt` is overwritten every batch — it shows ONLY the
  last batch. A per-batch curve from val loss ~6 down to ~0.008 means
  that batch memorized — iters is too high.
- the cycle auto-resets: when `select_lora_stories_ite` exhausts the
  story pool it sets `cycleState.ready_for_reset = true` and shuts the
  pipeline down once; the NEXT run sees that flag and starts a fresh
  full pass. "Shutdown: no remaining stories" is expected end-of-pass
  behavior, not an error.

RESOLVED (May 2026): a chat-format run at `iters: 80` per batch trained
each batch to train loss < 0.02 (memorization), and the accumulated
adapter produced NO output in gypsy. Root cause: `iters: 80` is far too
high for this gentle-nudge design. Recipe default is `iters: 5`.
