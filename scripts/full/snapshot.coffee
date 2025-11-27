#!/usr/bin/env coffee
###
snapshot.coffee — memo-native meta-runner snapshot generator (2025)
-------------------------------------------------------------------
Reads:
  run.artifacts_json    ← artifact registry (from memo)
  stepCfg.prompts       ← array of prompts
Writes:
  <snap>.jsonl          ← array-of-objects (memo JSONL)
  <snap>.yaml           ← grouped-by-prompt YAML (memo)

Uses:
  M.callMLX "generate", {model, prompt, adapter_path, max_tokens}
###

yaml = require 'js-yaml'

@step =
  desc: "Generate prompt snapshots using MLX (memo-only, no filesystem)"

  action: (M, stepName) ->

    # ---------------------------------------------------------------
    # Load experiment.yaml
    # ---------------------------------------------------------------
    cfg = M.theLowdown("experiment.yaml")?.value
    throw new Error "Missing experiment.yaml" unless cfg?

    stepCfg = cfg[stepName]
    runCfg  = cfg.run

    throw new Error "Missing step config '#{stepName}'" unless stepCfg?
    throw new Error "Missing run section" unless runCfg?

    # Required config keys (NO defaults injected)
    SNAP_NAME        = stepCfg.snapshots          # "generations"
    PROMPTS          = stepCfg.prompts or []
    MAX_NEW          = stepCfg.max_new_tokens
    ONLY_MODEL_ID    = stepCfg.only_model_id      # optional
    ART_KEY          = runCfg.artifacts_json      # memo key containing registry

    throw new Error "Missing #{stepName}.snapshots" unless SNAP_NAME?
    throw new Error "Missing #{stepName}.prompts"   unless Array.isArray(PROMPTS)
    throw new Error "Missing #{stepName}.max_new_tokens" unless MAX_NEW?
    throw new Error "Missing run.artifacts_json" unless ART_KEY?

    # ---------------------------------------------------------------
    # Load artifact registry from memo
    # ---------------------------------------------------------------
    regEntry = M.demand(ART_KEY)
    registry = regEntry.value
    unless registry?.runs?
      throw new Error "Artifact registry missing or invalid in '#{ART_KEY}'"

    runs = registry.runs.slice()

    if ONLY_MODEL_ID? and ONLY_MODEL_ID.length > 0
      runs = runs.filter (r) -> r.model_id is ONLY_MODEL_ID
      throw new Error "No matching runs for only_model_id='#{ONLY_MODEL_ID}'" unless runs.length

    # ---------------------------------------------------------------
    # Choose modeling paths (quantized → fused → base+adapter)
    # ---------------------------------------------------------------
    pickArtifacts = (re) ->
      out = []
      if re.quantized_dir? then out.push {model: re.quantized_dir, adapter: null, label: "quantized"}
      if re.fused_dir?     then out.push {model: re.fused_dir,     adapter: null, label: "fused"}
      out.push {model: re.model_id, adapter: re.adapter_dir, label: "base+adapter"}

      uniq = []
      seen = new Set()
      for x in out
        key = "#{x.model}|#{x.adapter or ''}"
        continue if seen.has(key)
        seen.add(key)
        uniq.push x
      uniq

    # ---------------------------------------------------------------
    # MLX one-prompt runner using memo-native callMLX
    # ---------------------------------------------------------------
    runOneModel = (modelPath, adapterPath, prompts, maxTokens) ->
      outs = []
      for p in prompts
        args =
          op: "generate"
          model: modelPath
          prompt: p
          max_tokens: maxTokens

        if adapterPath?
          args["adapter-path"] = adapterPath

        # MLX op is async; use await on internal notifier
        outEntry = M.callMLX "generate", args
        res = await outEntry.notifier

        if res?.error?
          throw new Error "mlx-lm.generate error: #{res.error}"

        raw = res.output or res.text or ""
        # Remove echoed prompt if model echoes it
        g = if raw.startsWith(p) then raw.slice(p.length).trim() else raw.trim()
        outs.push g

      outs

    # ---------------------------------------------------------------
    # Main generation loop
    # ---------------------------------------------------------------
    allRows = []
    stamp = new Date().toISOString().replace(/\.\d+Z$/, 'Z')

    for re in runs
      variants = pickArtifacts(re)

      for v in variants
        gens = await runOneModel(v.model, v.adapter, PROMPTS, MAX_NEW)

        for i in [0...PROMPTS.length]
          p = PROMPTS[i]
          g = gens[i] or ""

          allRows.push
            timestamp_utc: stamp
            model_id: re.model_id
            artifact: v.label
            prompt: p
            generation: g
            len_chars: g.length
            len_words: g.split(/\s+/).filter((x)->x.length).length
            is_empty: if g.trim().length is 0 then 1 else 0

    # ---------------------------------------------------------------
    # Emit JSONL + YAML via memo (no filesystem)
    # ---------------------------------------------------------------
    JSONL_KEY = "#{SNAP_NAME}.jsonl"
    YAML_KEY  = "#{SNAP_NAME}.yaml"

    # jsonl = array of JSON strings → meta-rules persist automatically
    M.saveThis JSONL_KEY, allRows.map (r) -> JSON.stringify(r)

    grouped = {}
    for r in allRows
      key = (r.prompt or "").trim()
      grouped[key] ?= []
      grouped[key].push r

    M.saveThis YAML_KEY, yaml.safeDump(grouped, {sortKeys:false})

    # Mark done
    M.saveThis "done:#{stepName}", true

    console.log "snapshot: wrote #{allRows.length} rows"
    console.log "JSONL → #{JSONL_KEY}"
    console.log "YAML  → #{YAML_KEY}"

    return allRows