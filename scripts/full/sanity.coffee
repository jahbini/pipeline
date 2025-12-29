#!/usr/bin/env coffee
###
sanity.coffee — memo-native ablation summarizer (2025)
-------------------------------------------------------
Reads:
  <ablations_jsonl_key>    ← JSONL array from memo (no FS)
Writes:
  <ablations>_summary.json ← memo key only
  <ablations>_summary.csv  ← memo key only

Performs:
  - empty-rate check
  - sentence-ending % check
  - avg/median word counts
  - grouped by model_id × artifact × prompt_variant
###

d3   = require 'd3-dsv'
_    = require 'lodash'

@step =
  desc: "Aggregate and summarize ablation results (memo-native)"

  action: (M, stepName) ->
    params = (M.theLowdown "params/#{stepName}.json").value
    # Required:
    #    params.ablations_jsonl   ← memo key containing JSONL array of rows
    #    params.ablations_name    ← base name for summary outputs
    unless params.ablations?
      throw new Error "Missing #{stepName}.ablations (memo key)"


    ABL_KEY     = params.ablations + ".jsonl"      # memo key to read input rows
    BASE_NAME   = params.ablations       # "abl_123" → summary keys derived

    SUM_JSON_KEY = "#{BASE_NAME}_summary.json"
    SUM_CSV_KEY  = "#{BASE_NAME}_summary.csv"

    # ------------------------------------------------------------
    # Load input rows from memo ONLY
    # ------------------------------------------------------------
    entry = M.theLowdown(ABL_KEY)
    rows  = entry.value || await entry.notifier
    unless Array.isArray(rows) and rows.length > 0
      throw new Error "Memo key #{ABL_KEY} contains no rows"

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------
    pct = (x) -> "#{(x * 100).toFixed(1)}%"
    median = (xs) ->
      ys = _.sortBy(xs)
      return 0 unless ys.length
      mid = Math.floor(ys.length / 2)
      if ys.length % 2 then ys[mid] else (ys[mid-1] + ys[mid]) / 2

    endsSentence = (s) ->
      /[.!?…]$/.test(String(s).trim())

    # ------------------------------------------------------------
    # Group rows
    # ------------------------------------------------------------
    groups = _.groupBy(rows, (r) ->
      [
        r.model_id ? "unknown-model",
        r.artifact ? "unknown-artifact",
        r.prompt_variant ? "default"
      ].join('|')
    )

    agg = []

    for key, g of groups
      n = g.length
      emptyCount = _.sumBy(g, (x)-> if x.is_empty then 1 else 0)
      sentEnd    = _.sumBy(g, (x)-> if endsSentence(x.generation or "") then 1 else 0)

      lens = (x.len_words for x in g when typeof x.len_words is 'number')

      avgLen = _.mean(lens) or 0
      medLen = median(lens) or 0

      [model_id, artifact, prompt_variant] = key.split('|')

      agg.push
        model_id: model_id
        artifact: artifact
        prompt_variant: prompt_variant
        n: n
        empty_rate: emptyCount / n
        sent_end_rate: sentEnd / n
        avg_len: avgLen
        med_len: medLen

    # ------------------------------------------------------------
    # Construct summary
    # ------------------------------------------------------------
    ts = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
    summary =
      created_utc: ts
      total_rows: rows.length
      groups: agg

    csvOut = d3.csvFormat(agg)

    # ------------------------------------------------------------
    # Memo save (no filesystem)
    # ------------------------------------------------------------
    M.saveThis SUM_JSON_KEY, summary
    M.saveThis SUM_CSV_KEY, csvOut

    M.saveThis "#{stepName}:summary", summary

    # ------------------------------------------------------------
    # Console report
    # ------------------------------------------------------------
    console.log "=== Sanity / Ablation Summary ==="
    for r in agg
      console.log "#{r.model_id} | #{r.artifact} | #{r.prompt_variant} | n=#{r.n} " +
                  "empty=#{pct(r.empty_rate)} sent_end=#{pct(r.sent_end_rate)} " +
                  "avg=#{r.avg_len.toFixed(3)} med=#{r.med_len}"

    console.log "\nMemo outputs:"
    console.log "  JSON → #{SUM_JSON_KEY}"
    console.log "  CSV  → #{SUM_CSV_KEY}"

    return summary
