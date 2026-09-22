###
  voice_from_prompt.coffee — one-step voice smoke test.
  Reads a ready-to-use prompt from params/diary_prompt.txt, feeds it
  verbatim to the pipe's own quantized model, writes the raw diary
  text to out/diary_voice.txt.

  Decouples voice-evaluation from the whole story spine. The prompt
  was authored by some other pipe (or the puppeteer) and dropped
  into this pipe's params/. This step doesn't know or care where it
  came from.
###

fs   = require 'fs'
path = require 'path'

@step =
  desc: 'Voice test — generate a diary from a pre-built prompt file.'

  action: (L) ->
    modelDir   = String L.param('quantized_model_dir', L.param('run.quantized_dir', ''))
    unless modelDir.length
      throw new Error "[#{L.stepName}] quantized_model_dir (or run.quantized_dir) required"
    unless fs.existsSync(modelDir) and fs.existsSync(path.join(modelDir, 'config.json'))
      throw new Error "[#{L.stepName}] model dir has no config.json: #{modelDir}"

    cwd = process.env.CWD ? process.cwd()

    # Two ways to supply the prompt:
    #   spine: <name>      — read from data/spines/<name>.txt (via
    #                        the meta layer, so BASE/data/spines wins
    #                        over CWD/data/spines shadows). This is
    #                        the preferred entry point — the spine
    #                        library is the single source of truth.
    #                        On step start, the resolved spine text
    #                        is copied to out/diary_prompt.txt so the
    #                        UI's Outputs panel shows exactly what was
    #                        fed to the model.
    #   prompt_file: <rel> — read a literal file path (relative to
    #                        CWD). Used when the spine was fanned in
    #                        by an upstream step (celarien, story
    #                        chain) — default 'out/diary_prompt.txt'.
    spineName = L.param 'spine', null
    prompt = null
    sourceLabel = null
    autoPrefill = null

    if spineName? and String(spineName).length
      spineName = String(spineName).replace(/\.txt$/, '')
      key = "data/spines/#{spineName}.txt"
      prompt = L.theLowdown(key)?.value
      unless typeof prompt is 'string' and prompt.length
        throw new Error "[#{L.stepName}] spine '#{spineName}' not found via meta at #{key}"
      # Copy to out/ so the UI Outputs panel shows exactly what was fed.
      outPath = path.join(cwd, 'out', 'diary_prompt.txt')
      fs.mkdirSync path.dirname(outPath), { recursive: true }
      fs.writeFileSync outPath, prompt, 'utf8'
      sourceLabel = "spine:#{spineName} → out/diary_prompt.txt"
      # 2026-09-22 — auto-load matching prefill if present. Sibling file
      # data/spines/<name>.prefill.txt (imperative-list plan) that
      # becomes the <think> block content, shifting the model from
      # THINK to DO mode. If absent, no prefill fires; force_think can
      # still be set explicitly.
      prefillKey = "data/spines/#{spineName}.prefill.txt"
      autoPrefill = L.theLowdown(prefillKey)?.value
      if typeof autoPrefill is 'string' and autoPrefill.length
        outPrefillPath = path.join(cwd, 'out', 'diary_prefill.txt')
        fs.writeFileSync outPrefillPath, autoPrefill, 'utf8'
        console.log "[#{L.stepName}] spine prefill: #{autoPrefill.length} chars → out/diary_prefill.txt"
    else
      promptRel  = String L.param('prompt_file', 'out/diary_prompt.txt')
      promptPath = if path.isAbsolute(promptRel) then promptRel else path.join(cwd, promptRel)
      unless fs.existsSync promptPath
        throw new Error "[#{L.stepName}] prompt_file not found: #{promptPath}"
      prompt = fs.readFileSync(promptPath, 'utf8')
      sourceLabel = promptRel

    console.log "[#{L.stepName}] prompt: #{prompt.length} chars from #{sourceLabel}"
    console.log "[#{L.stepName}] modelDir: #{modelDir}"

    maxTokens   = Number L.param('max_tokens',  2400)
    temperature = Number L.param('temperature', 0.85)
    topP        = Number L.param('top_p',       0.9)

    # Adapter loading — the voice a pipe was trained to produce lives
    # in its LoRA. Base generation ignores that entirely, so the voice
    # reading is unfair without this. adapter_path is optional:
    # explicit null (or missing) means "run the base model."
    adapterPath = L.param 'adapter_path', null
    adapterOk   = false
    if adapterPath?
      cwd = process.env.CWD ? process.cwd()
      resolved = if path.isAbsolute(String(adapterPath)) then String(adapterPath) else path.join(cwd, String(adapterPath))
      if fs.existsSync(path.join(resolved, 'adapter_config.json'))
        adapterPath = resolved
        adapterOk   = true
        console.log "[#{L.stepName}] adapter: #{resolved}"
      else
        console.log "[#{L.stepName}] adapter_path #{resolved} has no adapter_config.json — skipping (base voice)"
        adapterPath = null

    # Think-mode controls (Qwen3 family). Defaults match the previous
    # bare-completion behavior (raw=true, no chat template, no <think>
    # block). Overrides in the recipe let a caller flip on the chat
    # template to expose <think>...</think> chatter for prompt tuning,
    # or prefill a completed <think> block, or force noThinking.
    raw            = L.param('raw',            true) is true
    noThinking     = L.param('no_thinking',    false) is true
    enableThinking = L.param('enable_thinking', null)
    thinkPrefill   = L.param 'think_prefill',   null
    # If the spine supplied a matching prefill file and the recipe
    # didn't override think_prefill, use the spine's prefill.
    thinkPrefill   = autoPrefill if not thinkPrefill? and autoPrefill? and String(autoPrefill).length
    systemPrompt   = L.param 'system_prompt',   null
    repPen         = Number L.param('repetition_penalty',      1.0)
    repCtx         = Number L.param('repetition_context_size', 128)
    presPen        = Number L.param('presence_penalty',        0)

    # 2026-09-22 force_think — for instruct-tuned Qwen3 variants
    # (e.g. 4B-Instruct-2507) that default to no-think. Manually
    # build the chat template with an UNCLOSED `<think>\n` opener as
    # the last token, then send raw:true so session_api doesn't
    # re-template. The model resumes generation from inside a think
    # block, must reason and emit </think> before the letter body.
    # force_think defaults to TRUE when a think_prefill is set (spine's
    # or explicit) — otherwise the prefill would be a no-op under
    # raw:false. Recipe can still explicitly set force_think:false to
    # disable this.
    forceThinkParam = L.param 'force_think', null
    forceThink =
      if forceThinkParam? then forceThinkParam is true
      else thinkPrefill? and String(thinkPrefill).length > 0
    if forceThink
      sysBlock = if systemPrompt? and String(systemPrompt).length
        "<|im_start|>system\n#{systemPrompt}<|im_end|>\n"
      else ''
      # If think_prefill was also supplied, close the think block with
      # the prefill content — the model reads it as its own already-
      # completed reasoning and moves to writing (DO mode).
      # Otherwise open an empty <think> and let the model do its own reasoning.
      thinkSection =
        if thinkPrefill? and String(thinkPrefill).trim().length
          body = String(thinkPrefill).trim()
          "<think>\n#{body}\n</think>\n\n"
        else
          "<think>\n"
      prompt = "#{sysBlock}<|im_start|>user\n#{prompt}<|im_end|>\n<|im_start|>assistant\n#{thinkSection}"
      raw = true
      mode = if thinkPrefill? and String(thinkPrefill).trim().length then "PREFILLED (#{String(thinkPrefill).trim().length} chars)" else "OPEN"
      console.log "[#{L.stepName}] force_think ON — think block: #{mode}"

    llmArgs =
      op:          'generate'
      modelDir:    modelDir
      prompt:      prompt
      maxTokens:   maxTokens
      temperature: temperature
      topP:        topP
      raw:         raw
    llmArgs.adapterPath           = adapterPath if adapterOk
    llmArgs.systemPrompt          = systemPrompt if systemPrompt? and not forceThink
    llmArgs.no_thinking           = true         if noThinking
    llmArgs.enable_thinking       = enableThinking if enableThinking?
    llmArgs.think_prefill         = String(thinkPrefill) if thinkPrefill? and String(thinkPrefill).length and not forceThink
    llmArgs.repetition_penalty    = repPen if repPen isnt 1.0
    llmArgs.repetition_context_size = repCtx if repPen isnt 1.0
    llmArgs.presence_penalty      = presPen if presPen isnt 0

    resp = await L.callLLM llmArgs
    # Capture BOTH the cleaned text and the raw generation so the
    # <think>...</think> chatter (if any) survives for inspection.
    rawText = String(resp?.rawText ? '')
    cleaned = String(resp?.text ? '')
    console.log "[#{L.stepName}] rawText: #{rawText.length} chars   cleaned: #{cleaned.length} chars"
    if rawText.indexOf('<think>') >= 0 or rawText.indexOf('</think>') >= 0
      console.log "[#{L.stepName}] <think> chatter present in rawText"
    else
      console.log "[#{L.stepName}] no <think> tags in rawText — model wasn't in thinking mode"

    # Write the RAW text (thinking + answer) so the prompt-tuning
    # inspection has everything. Recipe consumers wanting only the
    # answer body can strip up to </think>\n\n themselves.
    finalText = if rawText.length then rawText else cleaned
    L.make 'diary_voice_text', finalText

    # Tournament archival — when `spine:` was set, also drop a copy at
    # out/voice/<spine>.txt (+ a sibling <spine>.meta.json with the
    # generation params) so a multi-spine sweep on the same pipe
    # doesn't overwrite earlier voice runs, AND so the tournament
    # render step can pull provenance alongside the text.
    if spineName? and String(spineName).length
      archiveDir = path.join cwd, 'out', 'voice'
      fs.mkdirSync archiveDir, { recursive: true }
      archivePath = path.join archiveDir, "#{spineName}.txt"
      metaPath    = path.join archiveDir, "#{spineName}.meta.json"
      fs.writeFileSync archivePath, finalText, 'utf8'
      crypto = require 'crypto'
      adapterHash = null
      if adapterOk
        try
          safetensors = path.join adapterPath, 'adapters.safetensors'
          if fs.existsSync safetensors
            buf = fs.readFileSync safetensors
            adapterHash = crypto.createHash('sha256').update(buf).digest('hex')
        catch _err
          adapterHash = null
      meta =
        pipe_cwd:        cwd
        spine:           spineName
        model_dir:       modelDir
        adapter_path:    if adapterOk then adapterPath else null
        adapter_sha256:  adapterHash
        prompt_bytes:    prompt.length
        prompt_source:   sourceLabel
        rawText_bytes:   rawText.length
        cleaned_bytes:   cleaned.length
        finalText_bytes: finalText.length
        has_think_block: rawText.indexOf('</think>') >= 0
        sampler:
          raw:                       raw
          max_tokens:                maxTokens
          temperature:               temperature
          top_p:                     topP
          no_thinking:               noThinking
          enable_thinking:           enableThinking
          think_prefill_bytes:       (thinkPrefill? and String(thinkPrefill).length) or 0
          repetition_penalty:        repPen
          repetition_context_size:   repCtx
          presence_penalty:          presPen
        system_prompt: systemPrompt
        # Timing — approximate; the step doesn't clock the callLLM
        # itself here but the step's state file gets started_at /
        # finished_at from the runner. We record when we WROTE the
        # artifact so downstream consumers have a stamp.
        wrote_at: new Date().toISOString()
      fs.writeFileSync metaPath, JSON.stringify(meta, null, 2), 'utf8'
      console.log "[#{L.stepName}] archived to out/voice/#{spineName}.txt + .meta.json"

    L.done()
    return
