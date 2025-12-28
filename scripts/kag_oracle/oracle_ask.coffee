#!/usr/bin/env coffee
###
oracle_ask.coffee — Select untagged segments + query MLX emotion oracle
(STEP-PARAM NATIVE)
###

@step =
  desc: "Select a batch of untagged segments and query the MLX emotion oracle"

  action: (M, stepName) ->
    throw new Error "Memo missing getStepParam()" unless typeof M.getStepParam is 'function'

    # ------------------------------------------------------------
    # Load params ONLY
    # ------------------------------------------------------------
    segKey   = M.getStepParam stepName, 'marshalled_stories'
    emoKey   = M.getStepParam stepName, 'kag_emotions'
    batchSz  = M.getStepParam stepName, 'batch_size'
    modelId  = M.getStepParam stepName, 'model'
    maxTok   = M.getStepParam stepName, 'max_tokens' ? 256

    throw new Error "Missing marshalled_stories" unless segKey?
    throw new Error "Missing kag_emotions"       unless emoKey?
    throw new Error "Missing batch_size"         unless batchSz?
    throw new Error "Missing model"              unless modelId?

    # ------------------------------------------------------------
    # Load story segments
    # ------------------------------------------------------------
    segments = M.theLowdown(segKey).value
    throw new Error "marshalled_stories must be array" unless Array.isArray(segments)

    # ------------------------------------------------------------
    # Load existing emotion rows
    # ------------------------------------------------------------
    taggedRows = M.theLowdown(emoKey).value ? []
    throw new Error "kag_emotions must be array" unless Array.isArray(taggedRows)

    tagged = new Set()
    for row in taggedRows when row?.meta?
      tagged.add "#{row.meta.doc_id}|#{row.meta.paragraph_index}"

    # ------------------------------------------------------------
    # Select pending batch
    # ------------------------------------------------------------
    pending = []
    for s in segments
      k = "#{s.meta?.doc_id}|#{s.meta?.paragraph_index}"
      continue if tagged.has k
      pending.push s
      break if pending.length >= batchSz

    console.log "[oracle_ask] pending:", pending.length

    # ------------------------------------------------------------
    # No work left → SHUTDOWN SIGNAL
    # ------------------------------------------------------------
    if pending.length is 0
      M.saveThis "pipeline:shutdown",
        by: stepName
        reason: "no more untagged segments"
        timestamp: new Date().toISOString()
      return

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------
    extractJSON = (raw) ->
      return {} unless raw?
      blk = raw.match(/\{[\s\S]*\}/)?[0]
      try JSON.parse(blk) catch then {}

    # ------------------------------------------------------------
    # Query MLX + append
    # ------------------------------------------------------------
    outRows = taggedRows.slice()

    for seg in pending
      text = seg.text ? ""
      meta = seg.meta ? {}

      prompt = """
You are a classifier. Given this sample <<< #{text} >>> classify each emotion as:
"none", "mild", "moderate", "strong", or "extreme".

Return exactly:
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
        model: modelId
        prompt: prompt
        "max-tokens": maxTok

      raw      = M.callMLX "generate", args
      emotions = extractJSON raw

      outRows.push
        meta:
          doc_id: meta.doc_id
          paragraph_index: meta.paragraph_index
        emotions: emotions

      console.log "[oracle_ask] tagged #{meta.doc_id} #{meta.paragraph_index}"

    # ------------------------------------------------------------
    # Persist (append-only semantics)
    # ------------------------------------------------------------
    M.saveThis emoKey, outRows
    return
