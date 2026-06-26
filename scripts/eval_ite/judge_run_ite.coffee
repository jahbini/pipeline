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
      formula:          "voice_similarity * 100 - mem_sub_rate * 50",
      summary:          <pass-through of ablation_summary>,
      voice_similarity: <pass-through of voice_similarity or null>,
      judged_at:        <ISO>
    }

  Persists to the `evaluations` SQLite table keyed by the current
  run_id (read from the memo at `run/current_run_id`, set by the
  runner at startup). Captures numeric metrics as proper columns and
  the full `eval_score` as `details_json` for forensics; also gathers
  a hyperparams snapshot from the param blobs of the steps named in
  the `hyperparam_steps` recipe param. See
  GPT/eval_ite/evaluations_table.md.
###
crypto = require 'crypto'

sha1Hex = (s) -> crypto.createHash('sha1').update(String(s ? ''), 'utf8').digest('hex')

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

    fallbackUsed = not voice?

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

    judgedAt = new Date().toISOString()

    evalScore =
      score_by_variant: scoreByVariant
      delta:            delta
      verdict:          verdict
      formula:          formula
      summary:          summary
      voice_similarity: voice
      judged_at:        judgedAt
    L.make 'eval_score', evalScore

    # ---- Persist to `evaluations` SQLite table -----------------------------
    # Best-effort: a missing run_id, missing meta, or write failure must NOT
    # fail the step. The `eval_score` artifact above is the source of truth;
    # the SQLite row is for the advice loop's historical queries.
    try
      runID = L.theLowdown('run/current_run_id')?.value
      throw new Error "run/current_run_id not set in memo (runner mismatch)" unless runID

      # Hyperparams snapshot from sibling step params. List defaults to
      # the 4 steps holding all tunable knobs; recipe can override via
      # `hyperparam_steps:` on judge_run_ite.
      hyperparamSteps = L.param 'hyperparam_steps', [
        'run_lora_train_ite'
        'generate_ablations_ite'
        'oracle_ask_sqlite'
        'collect_diary_kag_ite'
      ]
      hyperparams = {}
      for stepName in (hyperparamSteps ? [])
        p = L.theLowdown("params/#{stepName}.yaml")?.value
        hyperparams[stepName] = p if p?

      # Eval-prompts hash for comparability across runs.
      genParams = L.theLowdown('params/generate_ablations_ite.yaml')?.value ? {}
      prompts = genParams.eval_prompts ? []
      promptsHash = if Array.isArray(prompts) and prompts.length > 0 then sha1Hex(JSON.stringify(prompts)) else null
      promptsCount = if Array.isArray(prompts) then prompts.length else null

      # Pipeline name from the runs row (registered at startup).
      runsRow = L.theLowdown("runById{#{runID}}.json")?.value
      pipelineName = runsRow?.pipeline ? null

      voiceByVariant = voice?.by_variant ? {}
      summaryByVariant = summary.by_variant ? {}

      row =
        run_id:                    runID
        pipeline:                  pipelineName
        judged_at:                 judgedAt
        formula:                   formula
        fallback_used:             fallbackUsed
        score_base:                scoreByVariant.base ? null
        score_with_adapter:        scoreByVariant.with_adapter ? null
        delta:                     delta
        verdict:                   verdict
        voice_cosine_base:         voiceByVariant.base?.cosine_mean ? null
        voice_cosine_with_adapter: voiceByVariant.with_adapter?.cosine_mean ? null
        mem_sub_rate_base:         summaryByVariant.base?.mem_sub_rate ? null
        mem_sub_rate_with_adapter: summaryByVariant.with_adapter?.mem_sub_rate ? null
        distinct2_base:            summaryByVariant.base?.distinct2_mean ? null
        distinct2_with_adapter:    summaryByVariant.with_adapter?.distinct2_mean ? null
        eval_prompts_hash:         promptsHash
        eval_prompts_count:        promptsCount
        hyperparams:               hyperparams
        details:                   evalScore
        created_at:                judgedAt

      L.saveThis "evaluationRegister{#{runID}}.json", row
      console.log "[#{L.stepName}] evaluations row :  written for run #{runID}"
    catch err
      console.error "[#{L.stepName}] could not persist evaluations row: #{err?.message ? err}"

    L.done()
    return
