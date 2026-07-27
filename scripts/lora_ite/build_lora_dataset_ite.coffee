###
  build_lora_dataset_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  Shapes the selected training stories into the JSONL
  shards (`train.jsonl`, `valid.jsonl`, `test.jsonl`)
  that `mlx_lm.lora` expects. Owns token-budget
  estimation and paragraph splitting; the
  `splitParagraphs` heuristic is what keeps a single
  long story from blowing the model's context window.
###
fs = require 'fs'
path = require 'path'

# Resolve the model's end-of-turn token STRING from its tokenizer config, so
# every emitted training row can be terminated with it — this is what teaches
# the adapter to STOP. Read from tokenizer_config.json (the model's own
# `eos_token`) rather than hardcoding '<|im_end|>' so a different base model's
# EOT travels correctly. `eos_token` may be a bare string or an AddedToken
# object ({content: "..."}); handle both. No fallback: if it can't be resolved,
# fail loudly rather than silently emit rows with no stop signal.
resolveEotToken = (modelDir) ->
  cfgPath = path.join modelDir, 'tokenizer_config.json'
  throw new Error "[build_lora_dataset_ite] tokenizer_config.json not found at #{cfgPath}" unless fs.existsSync cfgPath
  cfg = JSON.parse fs.readFileSync(cfgPath, 'utf8')
  eot = cfg.eos_token
  eot = eot.content if eot? and typeof eot is 'object'
  throw new Error "[build_lora_dataset_ite] no usable eos_token in #{cfgPath}" unless eot? and typeof eot is 'string' and eot.length > 0
  eot

estimateTokens = (text) ->
  return 0 unless text?
  cleaned = String(text).trim()
  return 0 unless cleaned.length > 0
  Math.ceil(cleaned.length / 4)

splitParagraphs = (text) ->
  rawParagraphs = String(text ? '').split /\n\s*\n/
  paragraphs = []
  for para in rawParagraphs
    cleanPara = String(para ? '').trim()
    continue unless cleanPara.length > 0
    paragraphs.push cleanPara
  paragraphs

buildStoryGroups = (paragraphs) ->
  return [] unless Array.isArray(paragraphs)
  return [] unless paragraphs.length

  if paragraphs.length < 5
    return [paragraphs.slice()]

  groups = []
  total = paragraphs.length
  baseSize = Math.floor(total / 5)
  remainder = total % 5
  startIndex = 0

  for groupIndex in [0...5]
    groupSize = baseSize
    groupSize += 1 if groupIndex < remainder
    selected = paragraphs.slice startIndex, startIndex + groupSize
    groups.push selected
    startIndex += groupSize

  groups

buildFragmentParagraphs = (paragraphs) ->
  rval = []
  return rval unless Array.isArray(paragraphs)
  return rval if paragraphs.length is 0

  firstPara = paragraphs[0] ? ''
  if firstPara.trim().length > 0
    rval.push firstPara.trim()

  currentText = rval.join "\n\n"
  currentLen = currentText.length

  if currentLen < 300 and paragraphs.length > 2
    secondPara = paragraphs[1] ? ''
    if secondPara.trim().length > 0
      rval.push secondPara.trim()

  rval

splitSingleParagraphTrainingText = (paragraph) ->
  text = String(paragraph ? '').trim()
  return null unless text.length >= 120

  sentences = text.split /(?<=[.!?])\s+/
    .map (sentence) -> String(sentence ? '').trim()
    .filter (sentence) -> sentence.length > 0

  if sentences.length >= 2
    promptSentences = 1
    if sentences.length >= 4
      promptSentences = Math.max 1, Math.floor(sentences.length / 3)
    prompt = sentences.slice(0, promptSentences).join " "
    completion = sentences.slice(promptSentences).join " "
    if prompt.length > 0 and completion.length > 0
      return prompt: prompt + "\n\n", completion: completion

  words = text.split /\s+/
    .map (word) -> String(word ? '').trim()
    .filter (word) -> word.length > 0
  return null unless words.length >= 24

  splitAt = Math.max 8, Math.floor(words.length * 0.35)
  return null if splitAt >= words.length

  prompt = words.slice(0, splitAt).join " "
  completion = words.slice(splitAt).join " "
  return null unless prompt.length > 0 and completion.length > 0
  prompt: prompt + "\n\n", completion: completion

@step =
  desc: "Build LoRA train/valid/test rows from SQLite-backed stories"

  action: (L) ->
    selectedStoryIDs = await L.need 'selected_story_ids'

    throw new Error "[#{L.stepName}] selected_story_ids must be an array" unless Array.isArray selectedStoryIDs

    if selectedStoryIDs.length is 0
      console.log "[build_lora_dataset_ite] no selected stories; writing empty datasets and stopping"
      L.make 'train_rows', []
      L.make 'valid_rows', []
      L.make 'test_rows', []
      L.done()
      return

    rows = []
    rowsWritten = 0
    fallbackRowsWritten = 0
    storiesProcessed = 0

    # Row token budget (estimateTokens = chars/4). Lower it to build shorter
    # rows that fit under the trainer's maxSeqLength WITHOUT truncation — so the
    # appended EOT lands only at a natural completion end, never mid-word.
    MAX_TOTAL_TOKENS = Number(L.param('max_total_tokens', 1024))
    SAFETY_TOKENS = 64

    for storyID in selectedStoryIDs
      continue unless storyID?

      storyEntry = L.theLowdown "storyByID{#{storyID}}.json"
      story = storyEntry?.value
      if story is undefined
        if typeof storyEntry?.waitFor is 'function'
          story = await storyEntry.waitFor()
        else if storyEntry?.notifier?
          story = await storyEntry.notifier

      throw new Error "[#{L.stepName}] Missing storyByID for #{storyID}" unless story?

      fullStoryText = String(story.text ? '').trim()
      continue unless fullStoryText.length > 0

      paragraphs = splitParagraphs fullStoryText

      continue unless paragraphs.length > 0

      storyGroups = buildStoryGroups paragraphs

      for groupParagraphs in storyGroups
        continue unless Array.isArray(groupParagraphs)
        continue unless groupParagraphs.length > 0

        fragmentParagraphs = buildFragmentParagraphs groupParagraphs
        continue unless fragmentParagraphs.length > 0

        fragmentText = fragmentParagraphs.join "\n\n"
        prompt = fragmentText.trim() + "\n\n"
        promptTokens = estimateTokens prompt

        completionStartIndex = fragmentParagraphs.length
        completionParagraphs = groupParagraphs.slice completionStartIndex

        if completionParagraphs.length is 0
          if groupParagraphs.length is 1
            fallback = splitSingleParagraphTrainingText groupParagraphs[0]
            if fallback?
              rows.push text: fallback.prompt + fallback.completion
              rowsWritten += 1
              fallbackRowsWritten += 1
          continue

        maxCompletionTokens = MAX_TOTAL_TOKENS - promptTokens - SAFETY_TOKENS
        # Graceful skip (was a hard throw): a small max_total_tokens can make a
        # long fragment prompt exceed the budget. Skip that group rather than
        # crash the whole build.
        if maxCompletionTokens < 80
          console.log "[#{L.stepName}] skip group in #{storyID}: prompt too large (#{promptTokens} tok) for budget #{MAX_TOTAL_TOKENS}"
          continue

        chunkParagraphs = []
        chunkTokens = 0

        flushChunk = (isLastChunk) ->
          return unless chunkParagraphs.length > 0

          completionText = chunkParagraphs.join "\n\n"

          textOut = prompt + completionText

          rows.push text: textOut
          rowsWritten += 1
          chunkParagraphs = []
          chunkTokens = 0
          return

        for para, idx in completionParagraphs
          paraTokens = estimateTokens para
          proposedTokens = chunkTokens + paraTokens

          if chunkParagraphs.length > 0 and proposedTokens > maxCompletionTokens
            flushChunk false

          if paraTokens > maxCompletionTokens
            sentences = para.split /(?<=[.!?])\s+/
            sentenceChunk = []
            sentenceTokens = 0

            for sentence in sentences
              cleanSentence = String(sentence ? '').trim()
              continue unless cleanSentence.length > 0

              sentTokens = estimateTokens cleanSentence
              proposedSentenceTokens = sentenceTokens + sentTokens

              if sentenceChunk.length > 0 and proposedSentenceTokens > maxCompletionTokens
                completionText = sentenceChunk.join " "
                textOut = prompt + completionText
                rows.push text: textOut
                rowsWritten += 1
                sentenceChunk = []
                sentenceTokens = 0

              sentenceChunk.push cleanSentence
              sentenceTokens += sentTokens

            if sentenceChunk.length > 0
              isLastSentenceChunk = idx is completionParagraphs.length - 1
              completionText = sentenceChunk.join " "
              textOut = prompt + completionText
              rows.push text: textOut
              rowsWritten += 1

            continue

          chunkParagraphs.push para
          chunkTokens += paraTokens

        if chunkParagraphs.length > 0
          flushChunk true

      storiesProcessed += 1

    console.log "[build_lora_dataset_ite] stories processed:", storiesProcessed
    console.log "[build_lora_dataset_ite] rows written:", rowsWritten
    console.log "[build_lora_dataset_ite] single-paragraph fallback rows:", fallbackRowsWritten

    if rows.length is 0
      shutdownAt = new Date().toISOString()
      console.log "[build_lora_dataset_ite] selected stories produced no trainable rows; shutting down pipeline cleanly"
      L.saveThis 'pipeline:shutdown',
        by: L.stepName
        reason: 'selected stories produced no LoRA training rows'
        timestamp: shutdownAt
      L.make 'train_rows', []
      L.make 'valid_rows', []
      L.make 'test_rows', []
      L.done()
      return

    # --- EOS supervision -----------------------------------------------------
    # Append the model's end-of-turn token to every emitted row's completion.
    # Each row is `prompt + completion`, so the end of `text` IS the end of the
    # completion — appending here terminates the completion for all row shapes
    # (chunked, sentence-split, and single-paragraph fallback) in one place,
    # without touching the chunking logic above. train.coffee's raw
    # tokenizer.encode maps this string to the single EOT id and it lands inside
    # the loss mask (it is the last real target, and pad_token != eos_token).
    modelDir = L.param('quantized_model_dir', null) ? L.param('loraLand', null)
    throw new Error "[#{L.stepName}] Missing model directory (quantized_model_dir or loraLand) — needed to read the end-of-turn token" unless modelDir?
    eotToken = resolveEotToken modelDir
    rows = rows.map (row) -> text: "#{row.text}#{eotToken}"
    console.log "[build_lora_dataset_ite] appended EOT #{JSON.stringify eotToken} to #{rows.length} rows"

    L.make 'train_rows', rows
    L.make 'valid_rows', rows
    L.make 'test_rows', rows
    L.done()
    return
