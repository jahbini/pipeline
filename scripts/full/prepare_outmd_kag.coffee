#!/usr/bin/env coffee
###
prepare_outmd_kag.coffee — strict memo-native version (2025)

Converts Markdown stories stored in @memo into KAG-style
prompt/response training elements.

NO disk reads.
NO disk writes.
All I/O goes through @memo.

Requires:
  run.data_dir      – logical namespace only
  step.input_md     – memo key holding raw markdown text
  step.output_jsonl – memo key to store the JSONL array
###

@step =
  desc: "Convert Markdown stories into KAG-style JSONL entries (memo-native)"

  action: (M, stepName) ->

    throw new Error "Missing stepName" unless stepName?

    # ----------------------------------------------------------
    # Load experiment.yaml
    # ----------------------------------------------------------
    cfg = M.theLowdown("experiment.yaml")?.value
    throw new Error "Missing experiment.yaml in memo" unless cfg?

    stepCfg = cfg[stepName]
    throw new Error "Missing step config '#{stepName}'" unless stepCfg?

    runCfg = cfg.run
    throw new Error "Missing global run section" unless runCfg?

    # ----------------------------------------------------------
    # Required keys
    # ----------------------------------------------------------
    for k in ['data_dir']
      throw new Error "Missing run.#{k}" unless runCfg[k]?

    for k in ['input_md','output_jsonl']
      throw new Error "Missing step param #{k}" unless stepCfg[k]?

    DATA_DIR_KEY   = runCfg.data_dir          # logical namespace only
    INPUT_MD_KEY   = stepCfg.input_md         # memo key containing markdown string
    OUTPUT_JSONL_KEY = stepCfg.output_jsonl   # memo key to store JSONL array

    log = (msg) ->
      stamp = new Date().toISOString().replace('T',' ').replace('Z','')
      line = "[#{stamp}] #{msg}"
      console.log line
      try M.logThis?(stepName, line) catch e then null

    # ----------------------------------------------------------
    # Prompt template
    # ----------------------------------------------------------
    PROMPT_TEMPLATE = [
      "You are St. John's Jim — a myth-weaving, bar-stool Buddha of the Pacific Northwest.",
      "Tell a new short story in your own voice, using this idea as inspiration:\n"
    ].join "\n"

    # ----------------------------------------------------------
    # Split Markdown into story chunks
    # ----------------------------------------------------------
    extract_chunks = (mdText) ->
      raw = String(mdText ? '')
      parts = raw.split(/^#\s+/m)
      chunks = []
      for p in parts
        t = p.trim()
        continue unless t.length
        chunks.push t
      chunks

    # ----------------------------------------------------------
    # Make JSONL entry
    # ----------------------------------------------------------
    make_entry = (chunk) ->
      idea = chunk.slice(0, 200) + "…"
      {
        prompt: PROMPT_TEMPLATE + idea
        response: chunk.trim()
      }

    # ----------------------------------------------------------
    # Start
    # ----------------------------------------------------------
    log "Starting step #{stepName}"
    log "Reading markdown from memo key: #{INPUT_MD_KEY}"

    mdEntry = M.theLowdown(INPUT_MD_KEY)
    throw new Error "Missing markdown in memo: #{INPUT_MD_KEY}" unless mdEntry?
    mdText = mdEntry.value ? ""
    mdText = String(mdText)

    chunks = extract_chunks(mdText)
    log "Extracted #{chunks.length} chunks"

    entries = (make_entry c for c in chunks)

    # ----------------------------------------------------------
    # Save JSONL array to memo
    # ----------------------------------------------------------
    jsonlLines = entries.map((e)-> JSON.stringify(e))
    M.saveThis OUTPUT_JSONL_KEY, jsonlLines
    M.saveThis "out_kag:entries", entries
    M.saveThis "done:#{stepName}", true

    log "Wrote #{entries.length} KAG entries to memo key #{OUTPUT_JSONL_KEY}"
    log "Completed successfully."
    return