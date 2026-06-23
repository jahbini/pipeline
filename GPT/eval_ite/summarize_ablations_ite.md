Step: `summarize_ablations_ite`
Recipe: `eval_ite`

Purpose:
- aggregate ablation rows into per-variant metrics that downstream
  scoring (judge_run_ite) consumes
- compute the two metrics the legacy scoring formula referenced but
  never implemented (`distinct2_mean`, `mem_sub_rate`) plus the
  hygiene metrics from the legacy sanity step (empty rate, sentence-
  ending rate, word counts)

Inputs:
- artifact `ablations`
- meta read `allStories.jsonl` (the corpus, for memorization detection)
- param `mem_substring_length` (default 40)

Outputs:
- artifact `ablation_summary`:
  ```
  by_variant:
    <variant>:
      n
      empty_rate
      sentence_ending_rate
      word_count_mean
      word_count_median
      distinct2_mean
      mem_sub_rate
  variants:              # list of variant names found
  total_rows             # total ablation rows
  corpus_stories         # number of stories the memorization check saw
  corpus_chars           # total chars in the corpus (post whitespace-normalization)
  mem_substring_length
  summarized_at
  ```

Metric definitions:
- `distinct-2` = `|unique bigrams in completions| / |total bigrams|`.
  Lexical diversity proxy. Higher = less repetitive. Note: longer
  completions structurally produce more unique bigrams, so the metric
  is biased toward verbose outputs.
- `mem_sub_rate` = fraction of completions containing any contiguous
  substring of length `mem_substring_length` (default 40 chars) that
  also appears in the training corpus. The corpus is normalized to
  single-space whitespace before scanning. Substring match is
  case-sensitive.
- empty completions count toward `n` but contribute zero to all
  per-completion metrics

Origins:
- port of `~/development/pipeline/scripts/full/sanity.coffee` (the
  hygiene metrics)
- the `distinct2_mean` + `mem_sub_rate` computations are new — the
  legacy repo's `judging_finalizer.coffee` referenced them in its
  scoring formula but no step in the legacy code base implemented
  them. See `GPT/legacy_pipeline.md` § "The missing pieces"

Invariants:
- corpus is read via the SAME meta request the agent surface uses
  (`allStories.jsonl`); always reflects the current SQLite, never a
  stale snapshot
- if the corpus is empty (e.g., `allStories` returns []), `mem_sub_rate`
  falls back to 0 for every completion (the substring search just
  never matches) — `corpus_chars: 0` in the summary signals this
- corpus text is concatenated with `\n` separator and normalized to
  single-space; a single short story can still produce a memorization
  hit on a long shared phrase

Known pitfalls:
- `distinct2` is the wrong metric for voice fidelity (the very thing
  the eval is meant to detect). It rewards lexical breadth, which
  voice-transfer LoRAs reduce by design (Jim's voice is narrower than
  a base model's range). The June 22 eval against writediary returned
  `base=0.965 / with_adapter=0.929` — the adapter scored "worse"
  under distinct2 while qualitatively producing the correct Jim
  voice. That's why `voice_similarity_ite` exists: a direct measure
  of "did the output land in Jim's distribution" that distinct2 can't
  give
- the substring-based memorization check misses paraphrased
  memorization (style copy without exact reproduction). A `mem_sub_rate
  = 0` is necessary but not sufficient evidence the adapter isn't
  overfit
- `mem_substring_length: 40` is a default that works for English
  prose with vocabulary diversity. Domains with shorter natural
  phrases (poetry, lists, telegraphic style) may want a lower threshold
- the memorization scan is O(completion_len × corpus_chars) per
  completion — `corpus_chars: 589975` (writediary) × 5 completions =
  manageable. At larger corpora (~10 MB+) the cost compounds; if it
  becomes a problem, a suffix-array or rolling-hash precompute over
  the corpus would amortize
