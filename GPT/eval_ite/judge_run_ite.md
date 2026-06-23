Step: `judge_run_ite`
Recipe: `eval_ite`

Purpose:
- apply a single-run scoring formula to the per-variant metrics, emit
  a one-shot verdict (`better`/`worse`/`unchanged`/`single-variant`)

Inputs:
- artifact `ablation_summary` (required via `L.need`)
- artifact `voice_similarity` (optional via `L.peek`; absent or
  `available: false` triggers the distinct2 fallback)

Outputs:
- artifact `eval_score`:
  ```
  score_by_variant: { <variant>: <float> }
  delta              # with_adapter - base, null if either missing
  verdict            # 'better' | 'worse' | 'unchanged' | 'single-variant'
  formula            # describes WHICH score was computed (voice or distinct2)
  summary            # passthrough of ablation_summary
  voice_similarity   # passthrough (so an evaluator can see if fallback fired)
  judged_at
  ```

Score formula:

```
preferred (when voice_similarity.by_variant[variant].cosine_mean exists):
  score = cosine_mean * 100  −  mem_sub_rate * 50

fallback (voice_similarity unavailable):
  score = distinct2_mean * 100  −  mem_sub_rate * 50
```

The `formula` string in the output flags which path ran. The fallback
flag reads `"distinct2_mean * 100 - mem_sub_rate * 50  (FALLBACK:
voice_similarity unavailable)"` so the consumer can tell at a glance.

Verdict thresholds:
- `delta = score_by_variant.with_adapter − score_by_variant.base`
- `delta > 0.5`  → `better`
- `delta < -0.5` → `worse`
- otherwise      → `unchanged`
- if either variant is missing entirely → `single-variant` and
  `delta = null`

Origins:
- scoring formula and the verdict structure are direct ports of the
  `scoreRun()` function in `~/development/pipeline/judging_finalizer.coffee`
- the legacy formula was `distinct2 × 100 − mem_sub × 50`. We replaced
  the lexical-diversity proxy with cosine-against-Jim-centroid as the
  modern signal, but kept distinct2 as the fallback path so the recipe
  still runs on corpora that haven't populated `kag_embeddings` yet

Invariants:
- score is rounded to 2 decimal places (`Math.round(x*100)/100`)
- `voice_similarity` is consulted via `L.peek` (non-blocking) — if the
  step never ran, was disabled, or emitted the empty-corpus placeholder,
  this falls back cleanly
- the verdict reflects whichever score was used; not different verdict
  rules per formula
- this step is single-run scoring only. Cross-run ranking (the
  legacy "champion of the day" pattern) is intentionally not here —
  that's a future `champion_ite.yaml` recipe that consumes the
  `evaluations` SQLite table (also future) and ranks across rows.
  Yesterday's design captured this as deferred work in
  `GPT/legacy_pipeline.md`

Known pitfalls:
- the ±0.5 threshold for better/worse is generous; on small prompt
  sets (N=5 default) noise easily exceeds that. Either bump the
  threshold or bump the prompt count for reliable verdicts
- `voice_similarity` placeholder presence is detected by the absence
  of `by_variant[variant].cosine_mean`, not by `available: false`
  directly. Either signal triggers the fallback consistently, but if
  the schema of voice_similarity changes, this check should be revisited
- the formula's `mem_sub_rate * 50` penalty is asymmetric with the
  `cosine * 100` reward; in practice `mem_sub_rate` is usually 0 (a
  40-char substring match is rare on diverse training corpora), so
  the score is effectively `cosine_mean * 100`. When memorization
  does fire, a 0.1 hit-rate (10% of completions contain memorized
  spans) costs 5 score points — meaningful but not catastrophic.
  Tune the coefficient if memorization detection matters more for
  your use case
- final scores are NOT persisted to SQLite. The `evaluations` table
  doesn't exist yet (see `GPT/legacy_pipeline.md`'s "deferred follow-ups").
  For now, `eval_out/eval_score.json` (the artifact's `target:` file)
  is the only durable surface; agent surface `/api/run/<id>` shows it
  via `artifacts_written`
