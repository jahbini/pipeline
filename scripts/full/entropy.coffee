#!/usr/bin/env coffee
###
entropy.coffee — strict memo-aware (2025)
----------------------------------------------
Entropy Meter for MLX-LM stream_generate results.

Reads:
  - eval_out/generations.jsonl   (prompts only)
  - run.artifacts                (from memo)
  - eval/policy.yaml             (optional)

Writes:
  - eval_out/entropy_tokens.jsonl
  - eval_out/entropy_summary.csv
###
fs   = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

@step =
  desc: "Compute per-token entropy from MLX stream_generate (memo-native)"

  action: (M, stepName) ->

    EVAL_DIR = path.resolve(M.getStepParam stepName, "eval_dir")
    fs.mkdirSync(EVAL_DIR, {recursive:true})

    params = (M.theLowdown "params/#{stepName}.json").value
    
    GEN_JSONL = params.generations + ".jsonl"
    TOK_PATH  = params.entropy_tokens + ".jsonl"
    SUM_PATH  = params.entropy_summary + ".csv"
    POLICY_FILE = params.policy.yaml

    MAX_NEW   = parseInt(params.max_new_tokens)
    STOP_STRS = params.stop_strings
    unless Array.isArray(STOP_STRS) and STOP_STRS.length
      throw new Error "stop_strings must be non-empty array"

    # ---------------------------------------------------------------
    # Logging
    # ---------------------------------------------------------------
    LOG_PATH = path.join(EVAL_DIR, "#{stepName}.log")
    log = (msg) ->
      t = new Date().toISOString().replace('T',' ').replace(/\.\d+Z$/,'')
      line = "[#{t}] #{msg}"
      try fs.appendFileSync(LOG_PATH, line+"\n") catch then null
      console.log line

    log "Starting #{stepName}"

    # ---------------------------------------------------------------
    # Load policy
    # ---------------------------------------------------------------
    load_policy = ->
      if fs.existsSync(POLICY_FILE)
        yaml.load fs.readFileSync(POLICY_FILE,'utf8')
      else
        {prompt_policy:{name:'plain'},artifact_preference:['quantized','fused','adapter']}

    # ---------------------------------------------------------------
    # Load prompts from generations.jsonl
    # ---------------------------------------------------------------
    load_prompts = ->
      acc = []
      for line in fs.readFileSync(GEN_JSONL,'utf8').split(/\r?\n/)
        continue unless line.trim()
        try
          row = JSON.parse(line)
          acc.push row.prompt if row.prompt?
        catch then null
      acc

    # ---------------------------------------------------------------
    # Artifact selection from memo registry
    # ---------------------------------------------------------------
    reg = M.getStepParam stepName, "artifacts"
    reg = M.theLowdown reg
    reg = reg.value || await reg.notifier
    throw new Error "Missing artifacts in memo" unless reg?

    runs = reg.runs or []
    throw new Error "No runs found in artifacts registry" unless runs.length

    pick_artifact = (policy) ->
      pref = policy.artifact_preference or ['quantized','fused','adapter']
      cands = []
      for re in runs by -1
        if re.quantized_dir? then cands.push ['quantized', re.quantized_dir, null]
        if re.fused_dir?     then cands.push ['fused',     re.fused_dir,     null]
        if re.adapter_dir?   then cands.push ['adapter',   re.model_id,      re.adapter_dir]
      for want in pref
        for [lab,mpath,apath] in cands when lab is want
          return [mpath, apath, lab]
      cands[0]

    # ---------------------------------------------------------------
    # Entropy helpers
    # ---------------------------------------------------------------
    entropy_from_logprobs = (logs) ->
      maxv = Math.max.apply(null, logs)
      exps = logs.map((v)-> Math.exp(v-maxv))
      Z = exps.reduce(((a,b)->a+b), 0)
      ps = exps.map((e)-> e/(Z + 1e-12))
      -ps.reduce(((a,p)-> a + p*Math.log(p+1e-12)), 0)

    median = (xs) ->
      return 0 unless xs.length
      ys = xs.slice().sort((a,b)->a-b)
      n = ys.length
      if n%2 then ys[(n-1)/2] else 0.5*(ys[n/2-1]+ys[n/2])

    apply_prompt_policy = (p, policy) ->
      pp = policy.prompt_policy or {name:'plain'}
      switch pp.name
        when 'directive'
          "#{p}#{pp.directive?.suffix or ''}"
        when 'fewshot'
          fspec = pp.fewshot or {}
          prefix = fspec.prefix or ''
          joiner = fspec.joiner or '\n'
          suffix = fspec.suffix or '\n'
          shots  = fspec.shots or []
          "#{prefix}#{shots.join(joiner)}#{suffix}".replace('{prompt}', p)
        else p

    # ---------------------------------------------------------------
    # Main execution
    # ---------------------------------------------------------------
    policy  = load_policy()
    prompts = load_prompts()
    [model_path, adapter_path, artifact_label] = pick_artifact(policy)

    log "Model: #{model_path}"
    log "Adapter: #{adapter_path or '(none)'}"

    TOK = fs.createWriteStream(TOK_PATH)
    SUM = fs.createWriteStream(SUM_PATH)
    SUM.write "artifact,prompt_idx,tokens,mean_entropy,median_entropy,min_entropy,max_entropy\n"

    # ---------------------------------------------------------------
    # For each prompt → call MLX stream_generate
    # ---------------------------------------------------------------
    idx = 0
    for rawPrompt in prompts
      fullPrompt = apply_prompt_policy(rawPrompt, policy)

      args =
        op: "stream_generate"
        model_path: model_path
        adapter_path: adapter_path
        prompt: fullPrompt
        max_tokens: MAX_NEW
        stop: STOP_STRS

      log "stream_generate for prompt #{idx}"

      out = await M.callMLX("stream_generate", args)
      if out?.error?
        log "ERROR: #{out.error}"
        idx++; continue

      # out.records = [{token, logprobs:[...], ...}]
      recs = out.records or []
      ent = []

      for r in recs
        if r.logprobs?
          H = entropy_from_logprobs(r.logprobs)
          ent.push H
          TOK.write JSON.stringify({prompt_idx:idx, token:r.token, entropy:H})+"\n"

      if ent.length
        meanH = ent.reduce(((a,b)->a+b),0) / ent.length
        medH  = median(ent)
        minH  = Math.min.apply(null, ent)
        maxH  = Math.max.apply(null, ent)
        SUM.write "#{artifact_label},#{idx},#{ent.length},#{meanH.toFixed(4)},#{medH.toFixed(4)},#{minH.toFixed(4)},#{maxH.toFixed(4)}\n"

      idx++

    TOK.end()
    SUM.end()

    log "Wrote tokens → #{TOK_PATH}"
    log "Wrote summary → #{SUM_PATH}"

    M.saveThis "#{stepName}:paths", {tokens:TOK_PATH, summary:SUM_PATH}
    return
