#!/usr/bin/env coffee
###
oracle_ask.coffee — Select untagged segments + query MLX emotion oracle
NEW VERSION — compliant with M.demand + memo-native JSONL I/O
###

@step =
  desc: "Select a batch of untagged segments and query the MLX emotion oracle"

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
    throw new Error "Missing step section" unless stepCfg?

    segKey = runCfg.marshalled_stories
    emoKey = runCfg.kag_emotions
    batchSz = stepCfg.batch_size

    throw new Error "Missing run.marshalled_stories" unless segKey?
    throw new Error "Missing run.kag_emotions"        unless emoKey?
    throw new Error "Missing stepCfg.batch_size"      unless batchSz?

    # ------------------------------------------------------------
    # Load segments via memo-demand
    # ------------------------------------------------------------
    segEntry = M.demand(segKey)
    segments = segEntry.value
    throw new Error "marshalled_stories: expected array" unless Array.isArray(segments)

    # ------------------------------------------------------------
    # Load already-tagged emotion entries (JSONL)
    # (M.demand handles both existing + empty files)
    # ------------------------------------------------------------
    emoEntry = M.demand(emoKey)
    taggedLines = emoEntry.value ? []

    tagged = new Set()
    for obj in taggedLines
      continue unless obj?.meta?
      k = "#{obj.meta.doc_id}|#{obj.meta.paragraph_index}"
      tagged.add(k)

    # ------------------------------------------------------------
    # Select batch of untagged segments
    # ------------------------------------------------------------
    pending = []
    for s in segments
      key = "#{s.meta?.doc_id}|#{s.meta?.paragraph_index}"
      continue if tagged.has(key)
      pending.push s
      break if pending.length >= batchSz

    if pending.length is 0
      console.log "oracle_ask: no new segments to tag."
      M.saveThis "oracle_ask:empty", true
      M.saveThis "done:#{stepName}", true
      return

    # ------------------------------------------------------------
    # Helper: safely extract JSON from LLM response
    # ------------------------------------------------------------
    extractJSON = (raw) ->
      return {} unless raw?
      block = raw.match(/\{[\s\S\n]*\}/)?.[0]
      return {} unless block?
      try JSON.parse(block) catch then {}

    # ------------------------------------------------------------
    # Query MLX for each pending segment
    # (memo meta-rule persists JSONL updates automatically)
    # ------------------------------------------------------------
    outRows = taggedLines.slice()   # mutating copy

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

      result = M.callMLX "generate", args
      emotions = extractJSON result

      outRows.push
        meta:
          doc_id: meta.doc_id
          paragraph_index: meta.paragraph_index
        emotions: emotions

      console.log "oracle_ask: tagged #{meta.doc_id} #{meta.paragraph_index}"

    # ------------------------------------------------------------
    # Persist new emotion lines via M.saveThis
    # ------------------------------------------------------------
    M.saveThis emoKey, outRows

    # ------------------------------------------------------------
    # Step is finished
    # ------------------------------------------------------------
    M.saveThis "done:#{stepName}", true
    return