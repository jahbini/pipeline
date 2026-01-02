#!/usr/bin/env coffee

# -------------------------------------------------------------------
# examination.coffee — meta-aware, MLX-runner (M.callMLX ONLY)
# -------------------------------------------------------------------

fs   = require 'fs'
yaml = require 'js-yaml'

@step =
  desc: "Run regeneration ablations using MLX via M.callMLX"

  action: (M, stepName) ->

    params = (M.theLowdown "params/#{stepName}.json").value
    PROMPTS       = M.getStepParam stepName, "prompts"
    ABLATIONS     = M.getStepParam stepName, "ablations"
    MAX_SHORT     = M.getStepParam stepName, "max_new_short"
    MAX_LONG      = M.getStepParam stepName, "max_new_long"
    ONLY_MODEL_ID = M.getStepParam stepName, "only_model_id"
    regMemo = M.getStepParam stepName, "artifacts"

    # ---------------------------------------------------------------
    # Artifact registry: memo only
    # ---------------------------------------------------------------
    reg = M.theLowdown regMemo
    console.error "JIM awaits artifacts",stepName,regMemo unless reg.value
    reg = reg.value || await reg.notifier
    throw new Error "Missing artifacts in memo: #{reg}" unless reg?

    runs = reg.runs or []
    throw new Error "No runs in artifacts" unless runs.length

    if ONLY_MODEL_ID? and ONLY_MODEL_ID.length > 0
      runs = runs.filter (r) -> r.model_id is ONLY_MODEL_ID
    throw new Error "No matching runs after filter" unless runs.length

    # ---------------------------------------------------------------
    # Artifact resolution helper
    # ---------------------------------------------------------------
    pickArtifacts = (re) ->
      console.error "JIM bad model path",stepName, re
      out = []
      if re.quantized_dir? then out.push [re.quantized_dir, null, 'quantized']
      if re.fused_dir?     then out.push [re.fused_dir, null, 'fused']
      out.push [re.model_id, re.adapter_dir, 'base+adapter']

      uniq = []
      seen = new Set()
      for [m,a,label] in out
        key = "#{m}|#{a or ''}"
        continue if seen.has(key)
        seen.add(key)
        uniq.push [m,a,label]
      console.error "JIM bad uniq",stepName,uniq
      uniq

    # ---------------------------------------------------------------
    # Prompt transformers
    # ---------------------------------------------------------------
    pvPlain = (p) -> p

    pvDirective = (p) ->
      "#{p}\n\nAnswer with a single important thought:"

    pvFewshot = (p) ->
      shots = [
        "The moon does not race the tide."
        "A river carves stone by lingering."
      ]
      "Proverbs:\n- #{shots.join('\n- ')}\n\n#{p}\n- "

    PROMPT_VARIANTS =
      [
        ['plain', pvPlain]
        ['directive', pvDirective]
        ['fewshot', pvFewshot]
      ]

    # ---------------------------------------------------------------
    # MLX call helper (M.callMLX ONLY)
    # ---------------------------------------------------------------
    runOne = (modelPath, adapterPath, prompts, maxTokens) ->
      outs = []

      for p in prompts
        args =
          model: modelPath
          prompt: p
          'max-tokens': maxTokens
      
        args['adapter-path'] =  adapterPath if adapterPath

        console.error "JIM call mlx",stepName, args
        result = await M.callMLX("generate", args)

        if result?.error?
          throw new Error "mlx-lm.generate error: #{result.error}"

        txt = result.output or result.text or ""
        out = if txt.startsWith(p) then txt.slice(p.length) else txt
        outs.push out.trim()

      outs

    # ---------------------------------------------------------------
    # Main logic
    # ---------------------------------------------------------------
    allRows = []
    stamp = new Date().toISOString().replace(/\.\d+Z$/, 'Z')

    for re in runs
      arts = pickArtifacts(re)
      console.error "JIM runOne",re,runs,arts

      for [modelPath, adapterPath, artLabel] in arts
        for [pvLabel, pvFn] in PROMPT_VARIANTS

          promptsV = PROMPTS.map(pvFn)

          shortOuts = await runOne(modelPath, adapterPath, promptsV, MAX_SHORT)
          longOuts  = await runOne(modelPath, adapterPath, promptsV, MAX_LONG)

          for idx in [0...PROMPTS.length]
            p = PROMPTS[idx]
            s = shortOuts[idx] or ''
            l = longOuts[idx] or ''

            allRows.push
              timestamp_utc: stamp
              model_id: re.model_id
              artifact: artLabel
              prompt_variant: pvLabel
              budget: 'short'
              prompt: p
              generation: s
              len_chars: s.length
              len_words: s.split(/\s+/).filter((x)->x.length).length
              is_empty: (s.trim().length is 0) and 1 or 0

            allRows.push
              timestamp_utc: stamp
              model_id: re.model_id
              artifact: artLabel
              prompt_variant: pvLabel
              budget: 'long'
              prompt: p
              generation: l
              len_chars: l.length
              len_words: l.split(/\s+/).filter((x)->x.length).length
              is_empty: (l.trim().length is 0) and 1 or 0

    # ---------------------------------------------------------------
    # Write to memo as JSONL-array and YAML
    # ---------------------------------------------------------------
    jsonlKey = "#{ABLATIONS}.jsonl"
    yamlKey  = "#{ABLATIONS}.yaml"

    M.saveThis jsonlKey, allRows.map (r) -> JSON.stringify(r)

    grouped = {}
    for r in allRows
      key = (r.prompt or '').trim()
      grouped[key] ?= []
      grouped[key].push r

    M.saveThis yamlKey, yaml.safeDump(grouped, {sortKeys:false})

    return
