#!/usr/bin/env coffee
###
rotate_merged.coffee — merged → LoRA train/valid (pairwise continuation)
Each training example:
  prompt     = emotions + paragraph i
  completion = paragraph i+1
###

@step =
  desc: "Create LoRA train/valid JSONL from merged segments (i → i+1 continuation)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # Load config from memo
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown("experiment.yaml")
    throw new Error "Missing experiment.yaml in memo" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName] ? {}

    for k in ['merged_segments','train_file','valid_file']
      throw new Error "Missing run.#{k}" unless runCfg[k]?

    mergedKey = runCfg.merged_segments
    trainKey  = runCfg.train_file
    validKey  = runCfg.valid_file

    # ------------------------------------------------------------
    # Load merged + existing train/valid (memo-first)
    # ------------------------------------------------------------
    mergedEntry = M.theLowdown(mergedKey)
    mergedRows  = mergedEntry?.value ? []
    unless Array.isArray(mergedRows)
      throw new Error "Merged rows (#{mergedKey}) must be array"

    trainEntry = M.theLowdown(trainKey)
    oldTrain   = trainEntry?.value ? []
    oldTrain   = [] unless Array.isArray(oldTrain)

    validEntry = M.theLowdown(validKey)
    oldValid   = validEntry?.value ? []
    oldValid   = [] unless Array.isArray(oldValid)

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------
    normEmo = (emo={}) ->
      get = (k) -> emo[k] ? 'unknown'
      """
anger=#{get 'anger'}, fear=#{get 'fear'}, joy=#{get 'joy'},
sadness=#{get 'sadness'}, desire=#{get 'desire'}, curiosity=#{get 'curiosity'}
""".trim()

    mkPrompt = (row) ->
      meta = row.meta ? {}
      """
You are reading a personal narrative written by Jim.

Context:
- Document: #{meta.doc_id ? 'unknown'}
- Paragraph: #{meta.paragraph_index ? 'unknown'}
- Emotional tones present:
  #{normEmo(row.emotions)}

Text:
#{row.prompt}

Continue in the same voice, with emotional honesty and human warmth.
""".trim()

    isSequential = (a, b) ->
      return false unless a?.meta?.doc_id? and b?.meta?.doc_id?
      return false unless a.meta.doc_id is b.meta.doc_id
      ai = parseInt(a.meta.paragraph_index, 10)
      bi = parseInt(b.meta.paragraph_index, 10)
      bi is ai + 1

    # ------------------------------------------------------------
    # Build new training pairs (i → i+1)
    # ------------------------------------------------------------
    newTrain = []
    skipped  = 0

    for i in [0...mergedRows.length - 1]
      cur = mergedRows[i]
      nxt = mergedRows[i+1]

      unless isSequential(cur, nxt)
        skipped++
        continue

      newTrain.push
        prompt: mkPrompt(cur)
        completion: nxt.prompt

    # ------------------------------------------------------------
    # Rotate datasets
    #   train = freshly built pairs
    #   valid = previous valid + previous train
    # ------------------------------------------------------------
    newValid = oldValid.concat(oldTrain)

    console.log "[rotate_merged]"
    console.log "  merged rows:", mergedRows.length
    console.log "  new train pairs:", newTrain.length
    console.log "  skipped (non-seq):", skipped
    console.log "  old train:", oldTrain.length
    console.log "  old valid:", oldValid.length
    console.log "  → new valid:", newValid.length

    # ------------------------------------------------------------
    # Persist via memo (meta handles filesystem)
    # ------------------------------------------------------------
    M.saveThis trainKey, newTrain
    M.saveThis validKey, newValid

    return
