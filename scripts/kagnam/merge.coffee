#!/usr/bin/env coffee
###
kag_merge.coffee — strict memo-native KAG merge step
-------------------------------------------------------
• Reads story JSONL + emotion JSONL
• Matches on (meta.doc_id, meta.paragraph_index)
• Writes JSONL → {"text": "..."} per line
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Merge story segments with emotion tags (KAG-ready JSONL)"

  action: (M, stepName) ->

    throw new Error "Missing stepName argument" unless stepName?

    cfg = M.theLowdown('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml" unless cfg?

    stepCfg = cfg[stepName]
    runCfg  = cfg.run
    throw new Error "Missing step config #{stepName}" unless stepCfg?
    throw new Error "Missing run section" unless runCfg?

    # Required step keys
    for k in ['stories','emotions','mergedStories']
      unless stepCfg[k]?
        throw new Error "Missing #{stepName}.#{k}"

    storiesPath  = path.resolve(stepCfg.stories)
    emotionsPath = path.resolve(stepCfg.emotions)
    outKey       = stepCfg.mergedStories    # memo key

    # --- Helpers ---------------------------------------------------
    readLines = (p) ->
      fs.readFileSync(p, 'utf8').split(/\r?\n/).filter (l)->l.trim().length

    parseJSONL = (lines, label) ->
      out = []
      for line, idx in lines
        try out.push JSON.parse(line)
        catch e
          console.warn "[kag_merge] bad #{label} JSON at line #{idx+1}: #{e.message}"
      out

    makeKey = (meta) ->
      doc  = meta?.doc_id ? meta?.docID ? meta?.id
      para = meta?.paragraph_index ? meta?.para ? meta?.paragraph
      return null unless doc? and para?
      "#{doc}|#{para}"

    # --- 1) Load emotion tags -------------------------------------
    emoLines = readLines(emotionsPath)
    emoRows  = parseJSONL(emoLines, "emotions")

    emoMap = Object.create(null)
    for row in emoRows
      k = makeKey(row.meta or {})
      continue unless k?
      emoMap[k] ?= []
      emoMap[k] = emoMap[k].concat(row.emotions or [])

    # --- 2) Load stories ------------------------------------------
    storyLines = readLines(storiesPath)
    storyRows  = parseJSONL(storyLines, "stories")

    outLines = []
    total     = 0
    matched   = 0
    missing   = 0

    for row in storyRows
      total += 1
      meta = row.meta or {}
      k    = makeKey(meta)

      emos = emoMap[k]
      unless emos? and emos.length
        missing += 1
        continue

      continue unless row.prompt?.length

      matched += 1

      parts =
        Meta:
          doc_id: meta.doc_id
          paragraph_index: meta.paragraph_index
        Emotions: emos
        prompt: row.prompt

      text = JSON.stringify(parts)
      outLines.push JSON.stringify({text})

    # --- 3) Save JSONL array to memo ------------------------------
    M.saveThis outKey, outLines

    console.log "[kag_merge] total=#{total} matched=#{matched} missing=#{missing}"
    console.log "[kag_merge] KAG rows=", outLines.length

    M.saveThis "kag_merge:counts",
      total: total
      matched: matched
      missing: missing
      output_key: outKey

    M.saveThis "done:#{stepName}", true
    return