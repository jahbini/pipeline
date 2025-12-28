#!/usr/bin/env coffee
###
md2segments.coffee — Markdown anthology → JSONL segments (STEP-PARAM NATIVE)
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Convert Markdown stories to JSONL segments (step-param native)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?
    throw new Error "Memo missing getStepParam()" unless typeof M.getStepParam is 'function'

    # ------------------------------------------------------------
    # Load params ONLY
    # ------------------------------------------------------------
    inPath = M.getStepParam stepName, 'stories_md'
    outKey = M.getStepParam stepName, 'marshalled_stories'
    mode   = M.getStepParam stepName, 'split_mode'

    throw new Error "Missing stories_md"          unless inPath?
    throw new Error "Missing marshalled_stories" unless outKey?
    throw new Error "Missing split_mode"          unless mode?

    unless mode in ['story','paragraph']
      throw new Error "split_mode must be 'story' or 'paragraph'"

    # ------------------------------------------------------------
    # Early exit if output already exists
    # ------------------------------------------------------------
    existing = M.theLowdown(outKey).value
    if Array.isArray(existing) and existing.length > 0
      console.log "[md2segments] output already exists — skipping"
      return

    # ------------------------------------------------------------
    # Load Markdown (ONLY fs access)
    # ------------------------------------------------------------
    inAbs = path.resolve inPath
    throw new Error "Markdown not found: #{inAbs}" unless fs.existsSync inAbs

    raw   = fs.readFileSync inAbs, 'utf8'
    lines = raw.split /\r?\n/

    # ------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------
    clean = (txt) ->
      s = String(txt ? '')
      s = s.replace(/{{{First Name}}}/g, 'friend')
      s = s.replace(/&[a-zA-Z]+;/g, ' ')
      s = s.replace(/\[([^\]]+)\]\[\d+\]/g, '$1')
      s = s.replace(/\[\d+\]/g, '')
      s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      s = s.replace(/[_*]{1,3}([^*_]+)[_*]{1,3}/g, '$1')
      s = s.replace(/ {2,}/g, ' ')
      s.trim()

    safe = (title) ->
      String(title or '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '') or 'untitled'

    # ------------------------------------------------------------
    # Parse stories
    # ------------------------------------------------------------
    stories = []
    currentTitle = null
    buf = []

    flushStory = ->
      return unless currentTitle? and buf.length
      text = clean buf.join("\n")
      if text.length
        stories.push title: currentTitle, text: text
      buf = []

    for line in lines
      if line.startsWith '# '
        flushStory()
        currentTitle = line.slice(2).trim()
      else
        buf.push line

    flushStory()

    # ------------------------------------------------------------
    # Build segments
    # ------------------------------------------------------------
    rows = []

    if mode is 'story'
      for S in stories
        rows.push
          meta:
            doc_id: safe S.title
            paragraph_index: '001'
            title: S.title
          text: S.text
    else
      for S in stories
        baseId = safe S.title
        paras  = S.text.split(/\n/)
          .map(clean)
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
    # Save to memo
    # ------------------------------------------------------------
    M.saveThis outKey, rows
    return