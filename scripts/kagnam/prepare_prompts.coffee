#!/usr/bin/env coffee
###
prepare_prompts.coffee — KAG V1 (runCfg version)
• Reads emotion-merged JSONL (run.merged_segments)
• Produces KAG prompt-only JSONL (run.kag_examples)
• NO defaults — all paths defined in run.*
• Fully memo-native: all output via M.saveThis
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: "Create KAG-friendly LoRA prompts (run.* paths only)"

  action: (M, stepName) ->

    # -------------------------------------------------------------
    # 1. Load experiment.yaml and verify run config
    # -------------------------------------------------------------
    cfg = M.theLowdown('experiment.yaml')?.value
    throw new Error "Missing experiment.yaml in memo" unless cfg?

    runCfg = cfg.run
    throw new Error "Missing run section in experiment.yaml" unless runCfg?

    # Step config exists but does not define paths (KAG V1)
    stepCfg = cfg[stepName] or {}

    IN_KEY  = runCfg.merged_segments
    OUT_KEY = runCfg.kag_examples

    throw new Error "Missing run.merged_segments" unless IN_KEY?
    throw new Error "Missing run.kag_examples"   unless OUT_KEY?

    # -------------------------------------------------------------
    # 2. Load merged JSONL from memo
    # -------------------------------------------------------------
    raw = M.theLowdown(IN_KEY)?.value
    throw new Error "Missing memo value for #{IN_KEY}" unless raw?

    unless typeof raw is 'string'
      throw new Error "Input #{IN_KEY} must be a JSONL string"

    lines = raw.trim().split(/\r?\n/)
    rows  = []
    for ln in lines when ln.trim().length
      try
        rows.push JSON.parse ln
      catch e
        console.warn "[prepare_prompts] Bad JSON in merged_segments:", e.message

    console.log "[prepare_prompts] Loaded #{rows.length} merged KAG rows"

    # -------------------------------------------------------------
    # 3. Build KAG V1 LoRA prompts
    # -------------------------------------------------------------
    outRows = []

    for r in rows
      meta   = r.Meta or {}
      story  = r.prompt        # original segment text
      ems    = r.Emotions or []

      continue unless story? and story.trim().length
      continue unless Array.isArray(ems) and ems.length > 0

      emoText = ems.map((e)-> "#{e.emotion} (#{e.intensity})").join(", ")

      # --- KAG V1 Instruction Format ---
      prompt =
        "Instruction:\n" +
        "Using the narrator voice and tone from my stories, " +
        "write a short passage that naturally expresses these emotional qualities:\n" +
        "#{emoText}\n\n" +
        "Context:\n#{story}\n\n" +
        "Response:\n"

      outRows.push prompt

    console.log "[prepare_prompts] Produced #{outRows.length} KAG prompts"

    # -------------------------------------------------------------
    # 4. Save to memo (memo auto-JSONL writes line-by-line)
    # -------------------------------------------------------------
    M.saveThis OUT_KEY, outRows

    console.log "[prepare_prompts] Wrote #{outRows.length} → #{OUT_KEY}"
    return
