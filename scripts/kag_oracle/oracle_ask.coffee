#!/usr/bin/env coffee
###
oracle_ask.coffee — Select untagged segments + query MLX emotion oracle

Contract:
  • Reads marshalled story segments
  • Appends new Kag emotion rows (never truncates)
  • If new rows are added:
      → DOES NOT mark done
  • If no work is done:
      → marks done normally
###

@step =
  desc: "Select a batch of untagged segments and query the MLX emotion oracle"

  action: (M, stepName) ->
    console.log "JIM step oracke starting",stepName

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load config
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml in memo" unless cfgEntry?.value?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName]

    throw new Error "Missing run section"  unless runCfg?
    throw new Error "Missing step section" unless stepCfg?

    segKey  = runCfg.marshalled_stories
    emoKey  = runCfg.kag_emotions
    batchSz = stepCfg.batch_size

    throw new Error "Missing run.marshalled_stories" unless segKey?
    throw new Error "Missing run.kag_emotions"        unless emoKey?
    throw new Error "Missing stepCfg.batch_size"      unless batchSz?

    # ------------------------------------------------------------
    # Load story segments
    # ------------------------------------------------------------
    segEntry = M.theLowdown(segKey)
    segments = segEntry.value
    throw new Error "marshalled_stories must be array" unless Array.isArray(segments)

    # ------------------------------------------------------------
    # Load existing Kag emotion rows (may be empty)
    # ------------------------------------------------------------
    emoEntry   = M.theLowdown(emoKey)
    taggedRows = emoEntry.value ? []
    throw new Error "kag_emotions must be array" unless Array.isArray(taggedRows)

    # Build lookup of already-tagged segments
    tagged = new Set()
    for row in taggedRows
      continue unless row?.meta?
      k = "#{row.meta.doc_id}|#{row.meta.paragraph_index}"
      tagged.add(k)

    # ------------------------------------------------------------
    # Select untagged batch
    # ------------------------------------------------------------
    pending = []
    for s in segments
      key = "#{s.meta?.doc_id}|#{s.meta?.paragraph_index}"
      continue if tagged.has(key)
      pending.push s
      break if pending.length >= batchSz

    console.log "[oracle_ask] pending:", pending.length

    # ------------------------------------------------------------
    # Nothing to do → normal completion
    # ------------------------------------------------------------
    if pending.length is 0
      console.log "[oracle_ask] nothing to do"
      return

    # ------------------------------------------------------------
    # Helper: extract JSON from LLM output
    # ------------------------------------------------------------
    extractJSON = (raw) ->
      return {} unless raw?
      block = raw.match(/\{[\s\S\n]*\}/)?[0]
      return {} unless block?
      try JSON.parse(block) catch then {}

    # ------------------------------------------------------------
    # Query MLX and append rows
    # ------------------------------------------------------------
    outRows = taggedRows.slice()
    added   = 0

    for seg in pending
      text = seg.text ? ""
      meta = seg.meta ? {}

      prompt = """
You are a classifier. Given this sample <<< #{text} >>> classify each emotion with classification of:
"none", "mild", "moderate", "strong", "extreme".

Return exactly like this:
{
  "anger": classification,
  "fear": classification,
  "joy": classification,
  "sadness": classification,
  "desire": classification,
  "curiosity": classification
}
"""

      args =
        model: runCfg.model
        prompt: prompt
        "max-tokens": stepCfg.max_tokens ? 256

      ###
      console.log "M.constructor?.name =", M.constructor?.name
      console.log "typeof M.callMLX =", typeof M.callMLX
      console.log "own keys:", Object.keys M
      console.log "proto keys:", Object.getOwnPropertyNames Object.getPrototypeOf M
      ###

      result   = M.callMLX "generate", args
      emotions = extractJSON result

      outRows.push
        meta:
          doc_id: meta.doc_id
          paragraph_index: meta.paragraph_index
        emotions: emotions

      added += 1
      console.log "[oracle_ask] tagged #{meta.doc_id} #{meta.paragraph_index}"

    # ------------------------------------------------------------
    # Persist updated Kag file
    # ------------------------------------------------------------
    M.saveThis emoKey, outRows

    # IMPORTANT:
    #   DO NOT write done:<stepName>
    #   Runner will handle downstream invalidation on next startup
    return
