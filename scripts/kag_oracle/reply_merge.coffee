#!/usr/bin/env coffee
###
reply_merge.coffee — Merge MLX oracle replies into story segments
NEW VERSION — fully memo-native with M.demand
###

@step =
  desc: "Merge oracle emotion replies into marshalled story segments (memo-native)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load config from memo
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml in memo" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName]

    throw new Error "Missing run section"  unless runCfg?
    throw new Error "Missing step config" unless stepCfg?

    segKey = runCfg.marshalled_stories
    emoKey = runCfg.kag_emotions
    outKey = runCfg.merged_segments

    throw new Error "Missing run.marshalled_stories" unless segKey?
    throw new Error "Missing run.kag_emotions"       unless emoKey?
    throw new Error "Missing run.merged_segments"    unless outKey?

    # ------------------------------------------------------------
    # Load inputs via M.demand()
    # ------------------------------------------------------------
    segEntry = M.demand(segKey)
    segments = segEntry.value ? []
    throw new Error "marshalled_stories must be array" unless Array.isArray(segments)

    emoEntry = M.demand(emoKey)
    replies  = emoEntry.value ? []
    throw new Error "kag_emotions must be array" unless Array.isArray(replies)

    # ------------------------------------------------------------
    # Build emotion lookup: "doc|para" → emotions object
    # ------------------------------------------------------------
    lookup = Object.create(null)

    for r in replies
      continue unless r?.meta?
      id = "#{r.meta.doc_id}|#{r.meta.paragraph_index}"
      lookup[id] = r.emotions

    # ------------------------------------------------------------
    # Merge — only segments that have matching oracle data
    # ------------------------------------------------------------
    merged = []

    for s in segments
      id = "#{s.meta?.doc_id}|#{s.meta?.paragraph_index}"
      emos = lookup[id]
      continue unless emos?

      merged.push
        meta: s.meta
        prompt: s.text ? s.prompt
        emotions: emos

    console.log "[reply_merge] merged segments:", merged.length

    # ------------------------------------------------------------
    # Persist to memo; pipeline meta-rule writes JSONL
    # ------------------------------------------------------------
    M.saveThis outKey, merged
    M.saveThis "done:#{stepName}", true

    return