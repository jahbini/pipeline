#!/usr/bin/env coffee
###
md2segments.coffee — Markdown anthology → JSONL segments (memo-native)

Adapted to NEW pipeline rules:
- All external data files are accessed via M.demand()
- experiment.yaml is pulled from memo
- Direct fs reads ONLY for the external markdown source
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Convert Markdown stories to JSONL segments (memo only)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ------------------------------------------------------------
    # LOAD CONFIG (from memo)
    # ------------------------------------------------------------
    cfgEntry = M.theLowdown('experiment.yaml')
    throw new Error "Missing experiment.yaml in memo" unless cfgEntry?

    cfg     = cfgEntry.value
    runCfg  = cfg.run
    stepCfg = cfg[stepName]

    throw new Error "Missing run section"  unless runCfg?
    throw new Error "Missing step section" unless stepCfg?

    inPath = runCfg.stories_md
    outKey = runCfg.marshalled_stories ? runCfg.story_segments
    mode   = stepCfg.split_mode
    # ------------------------------------------------------------
    # EARLY EXIT: output already exists
    # ------------------------------------------------------------
    existing = M.theLowdown(outKey)
    if existing?.value? and Array.isArray(existing.value) and existing.value.length > 0
      console.log "[md2segments] output already exists — skipping generation"
      return

    throw new Error "Missing #{stepName}.input_md" unless inPath?
    throw new Error "Missing run.marshalled_stories/run.story_segments" unless outKey?
    throw new Error "Missing #{stepName}.split_mode" unless mode?
    unless mode in ['story','paragraph']
      throw new Error "split_mode must be 'story' or 'paragraph', got #{mode}"

    # ------------------------------------------------------------
    # Load Markdown (EXTERNAL file — only place fs.read allowed)
    # ------------------------------------------------------------
    inAbs = path.resolve(inPath)
    throw new Error "Markdown input not found: #{inAbs}" unless fs.existsSync(inAbs)

    raw = fs.readFileSync(inAbs, 'utf8')
    lines = raw.split(/\r?\n/)

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------
    clean = (txt) ->
      s = String(txt ? '')

      # 1) template token
      s = s.replace(/{{{First Name}}}/g, 'friend')

      # 2) HTML entities
      s = s.replace(/&[a-zA-Z]+;/g, ' ')

      # 3) markdown link syntax
      s = s.replace(/\[([^\]]+)\]\[\d+\]/g, '$1')
      s = s.replace(/\[\d+\]/g, '')
      s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')

      # 4) emphasis
      s = s.replace(/[_*]{1,3}([^*_]+)[_*]{1,3}/g, '$1')

      # 5) excessive spaces
      s = s.replace(/ {2,}/g, ' ')

      s.trim()

    safe = (title) ->
      String(title or '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '') or 'untitled'

    # ------------------------------------------------------------
    # Parse anthology into story blocks
    # ------------------------------------------------------------
    stories = []
    currentTitle = null
    buf = []

    flushStory = ->
      return unless currentTitle? and buf.length
      body = buf.join("\n").trim()
      text = clean(body)
      return unless text.length
      stories.push
        title: currentTitle
        text:  text
      buf = []

    for line in lines
      if line.startsWith('# ')
        flushStory()
        currentTitle = line.slice(2).trim()
      else
        buf.push line

    flushStory()

    # ------------------------------------------------------------
    # Build SEGMENTS
    # ------------------------------------------------------------
    rows = []

    if mode is 'story'
      for S in stories
        baseId = safe(S.title)
        rows.push
          meta:
            doc_id: baseId
            paragraph_index: "001"
            title: S.title
          text: S.text

    else
      # mode == 'paragraph'
      for S in stories
        baseId = safe(S.title)
        paras = S.text.split(/\n/)
          .map((p)-> clean(p))
          .filter((p)-> p.length)

        idx = 1
        for p in paras
          rows.push
            meta:
              doc_id: baseId
              paragraph_index: idx.toString().padStart(3,'0')
              title: S.title
            text: p
          idx += 1

    console.log "[md2segments] stories:", stories.length, "segments:", rows.length

    # ------------------------------------------------------------
    # Persist to Memo (JSONL auto-written by meta rule)
    # ------------------------------------------------------------
    M.saveThis outKey, rows
    return
