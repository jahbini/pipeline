#!/usr/bin/env coffee
###
reply_merge.coffee — Merge MLX oracle replies into story segments
(STEP-PARAM NATIVE)
###

@step =
  desc: "Merge oracle emotion replies into marshalled story segments (memo-native)"

  action: (M, stepName) ->
    # ------------------------------------------------------------
    # Load params ONLY
    # ------------------------------------------------------------
    segKey = M.getStepParam stepName, 'marshalled_stories'
    emoKey = M.getStepParam stepName, 'kag_emotions'
    outKey = M.getStepParam stepName, 'merged_segments'

    throw new Error "Missing marshalled_stories" unless segKey?
    throw new Error "Missing kag_emotions"       unless emoKey?
    throw new Error "Missing merged_segments"    unless outKey?

    # ------------------------------------------------------------
    # Load inputs
    # ------------------------------------------------------------
    segments = M.theLowdown(segKey).value ? []
    replies  = M.theLowdown(emoKey).value ? []

    throw new Error "marshalled_stories must be array" unless Array.isArray(segments)
    throw new Error "kag_emotions must be array"       unless Array.isArray(replies)

    if replies.length is 0
      console.log "[reply_merge] no oracle replies yet"
      return

    # ------------------------------------------------------------
    # Build lookup
    # ------------------------------------------------------------
    lookup = Object.create null
    for r in replies when r?.meta?
      lookup["#{r.meta.doc_id}|#{r.meta.paragraph_index}"] = r.emotions

    # ------------------------------------------------------------
    # Merge
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
    # Persist
    # ------------------------------------------------------------
    M.saveThis outKey, merged
    return
