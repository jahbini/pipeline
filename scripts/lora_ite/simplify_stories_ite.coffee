###
  simplify_stories_ite.coffee  —  whole-story plain-language retelling
  ====================================================================
  For each story that has kag_entries but no story_simplifications row
  yet, ask the LOCAL quantized model (no HFChat / no external tokens)
  to retell the story in plain language — stripped of Jim's wordplay,
  focused on the sequence of events and content.

  These retellings become the PROMPT half of LoRA training rows
  (see build_lora_dataset_ite). The COMPLETION is Jim's actual story
  text. The adapter learns "given plain content, produce Jim's voice."

  Distinct purpose from `simplify_chunks_ite` (per-KAG-chunk emotional
  signal). This step is per-whole-story style-transfer signal.

  Batched with `L.iterate`: batch_size stories per invocation. Reads
  pending work from `storiesMissingCleanEmbeddings`-shaped view
  `storySimplificationsMissing.jsonl`. Persists via
  `storySimplificationRegister{sid}.json` — sqlite is the source of
  truth; no filesystem JSONL.
###

@step =
  desc: "Generate whole-story plain-language retellings for LoRA style-transfer prompts"

  action: (L) ->
    batchSzRaw = L.param 'batch_size'
    batchSz = Number(batchSzRaw)
    throw new Error "[#{L.stepName}] batch_size must be a positive integer" unless Number.isFinite(batchSz) and batchSz > 0 and Math.floor(batchSz) is batchSz

    modelDir = L.param 'quantized_model_dir', null
    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?

    llmConfig = L.param('llm', null) ? {}
    promptTemplate = String(L.param('prompt_template', '''
      Retell this story in plain, straightforward language. Focus on the sequence of events and what happens. Strip out wordplay, unusual phrasings, and stylistic flourishes — deliver the content in clear neutral prose that a summary writer would use. Keep it as long as needed to cover the whole story.

      Story:
      {{{STORY}}}

      Plain retelling:
    '''.trim()))

    # Pull the pending-work list from sqlite.
    pending = L.theLowdown('storySimplificationsMissing.jsonl')?.value ? []
    unless Array.isArray pending
      throw new Error "[#{L.stepName}] storySimplificationsMissing.jsonl must be an array (got #{typeof pending})"

    console.log "[#{L.stepName}] stories pending simplification: #{pending.length}"

    if pending.length is 0
      L.make 'simplify_remaining_count', 0
      L.done()
      return

    batch = pending.slice 0, batchSz
    remainingAfterBatch = Math.max(pending.length - batch.length, 0)
    console.log "[#{L.stepName}] batch=#{batch.length} (#{remainingAfterBatch} stories will remain after this batch)"

    written = 0
    for story, si in batch
      sid = story?.story_id
      text = String(story?.text ? '').trim()
      unless sid? and text.length
        console.log "[#{L.stepName}] SKIP row #{si}: missing story_id or text"
        continue

      prompt = promptTemplate.split('{{{STORY}}}').join(text)

      # 2026-09-13: force no_thinking + a nonzero presence_penalty on
      # every simplification call. Qwen's default "thinking" mode
      # dumps chain-of-thought into the output ("Okay, so the user
      # wants…"), and without a presence penalty the model recurses
      # on its own summary ("I think that's the final version…" repeated
      # dozens of times). Both bugs were baked into every existing
      # `story_simplifications.simple_text` row before this fix.
      # Recipe-level `llm:` can override these if a specific model
      # needs different settings.
      llmArgs =
        op:               'generate'
        modelDir:         modelDir
        prompt:           prompt
        raw:              true
        no_thinking:      true
        presence_penalty: 1.5
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op'
        llmArgs[key] = value

      try
        result = await L.callLLM llmArgs
      catch err
        console.error "[#{L.stepName}] FAILED #{sid}: #{err?.message ? err}"
        continue

      simple = String(result?.text ? result?.rawText ? '').trim()
      # If the model echoed the prompt, strip that prefix.
      simple = simple.slice(prompt.length).trim() if simple.indexOf(prompt) is 0
      unless simple.length
        console.log "[#{L.stepName}] SKIP #{sid}: empty generation"
        continue

      L.saveThis "storySimplificationRegister{#{sid}}.json",
        story_id:    sid
        simple_text: simple
        model:       modelDir
        created_at:  new Date().toISOString()
      written += 1
      console.log "[#{L.stepName}] #{si + 1}/#{batch.length} #{sid}: #{simple.length} chars simplified"

    L.make 'simplify_remaining_count', remainingAfterBatch
    console.log "[#{L.stepName}] batch done — wrote #{written} rows; #{remainingAfterBatch} stories pending"

    if remainingAfterBatch > 0
      L.iterate?(
        "#{remainingAfterBatch} stories still pending for simplification"
        invalidate: ['storySimplificationsMissing.jsonl']
      )

    L.done()
    return
