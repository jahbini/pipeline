###
  judge_run_ite.coffee  —  EVAL_ITE pipeline step
  =====================================================
  Port of the scoring core of `~/development/pipeline/judging_finalizer.coffee`.
  Applies the legacy scoring formula:

      score = distinct2_mean * 100 - mem_sub_rate * 50

  …to each variant in the ablation summary. When both `base` and
  `with_adapter` variants are present, also emits a `delta` (the
  adapter's score minus base) — positive deltas indicate the
  adapter improved over the base, negative indicate degradation.

  Output `eval_score` artifact shape:
    {
      score_by_variant: { base: ..., with_adapter: ... },
      delta:            <number or null>,
      verdict:          'better' | 'worse' | 'unchanged' | 'single-variant',
      formula:          "distinct2_mean * 100 - mem_sub_rate * 50",
      summary:          <pass-through of ablation_summary>,
      judged_at:        <ISO>
    }

  This step DOES NOT write to a `evaluations` SQLite table yet — that's
  the next iteration (will let `/api/sqlite/diff` and a future
  `champion_ite` recipe rank evaluations across runs). For now the
  verdict file `eval_out/eval_score.json` is the source of truth.
###
@step =
  desc: "Apply the voice-similarity score formula and write a single-run verdict"

  action: (L) ->
    summary = await L.need 'ablation_summary'
    throw new Error "[#{L.stepName}] ablation_summary missing by_variant" unless summary?.by_variant?

    # voice_similarity is OPTIONAL — present when the corpus has
    # kag_embeddings populated (the modern path). Without it, fall back
    # to the legacy distinct2-based score so the recipe still runs on
    # corpora where the oracle hasn't been run yet.
    voice = null
    try
      voice = await L.peek 'voice_similarity', null
    catch
      voice = null

    # The primary score combines:
    #   voice_similarity (0..1)  →  scale × 100 to get 0..100
    #   mem_sub_rate     (0..1)  →  scale × 50  as a memorization penalty
    # When voice_similarity is unavailable, distinct2_mean stands in.
    scoreVariant = (variant) ->
      m   = summary.by_variant[variant] ? {}
      mem = Number(m.mem_sub_rate ? 0)
      vs  = voice?.by_variant?[variant]?.cosine_mean
      if vs?
        Math.round(((Number(vs) * 100) - (mem * 50)) * 100) / 100
      else
        d2 = Number(m.distinct2_mean ? 0)
        Math.round(((d2 * 100) - (mem * 50)) * 100) / 100

    scoreByVariant = {}
    for own variant of summary.by_variant
      scoreByVariant[variant] = scoreVariant(variant)

    delta = null
    verdict = 'single-variant'
    if scoreByVariant.with_adapter? and scoreByVariant.base?
      delta = Math.round((scoreByVariant.with_adapter - scoreByVariant.base) * 100) / 100
      verdict =
        if      delta > 0.5  then 'better'
        else if delta < -0.5 then 'worse'
        else                      'unchanged'

    formula = if voice? then "voice_similarity * 100 - mem_sub_rate * 50" else "distinct2_mean * 100 - mem_sub_rate * 50  (FALLBACK: voice_similarity unavailable)"
    console.log "[#{L.stepName}] formula          :", formula
    console.log "[#{L.stepName}] score_by_variant :", JSON.stringify(scoreByVariant)
    console.log "[#{L.stepName}] delta            :", delta if delta isnt null
    console.log "[#{L.stepName}] verdict          :", verdict

    L.make 'eval_score',
      score_by_variant: scoreByVariant
      delta:            delta
      verdict:          verdict
      formula:          formula
      summary:          summary
      voice_similarity: voice
      judged_at:        new Date().toISOString()
    L.done()
    return
