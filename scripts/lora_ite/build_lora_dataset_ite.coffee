###
  build_lora_dataset_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  Shapes the selected training stories into the JSONL
  shards (`train.jsonl`, `valid.jsonl`, `test.jsonl`)
  that `mlx_lm.lora` expects. Owns token-budget
  estimation, paragraph splitting, and the story-level
  train/valid/test partition. `splitParagraphs` is what
  keeps a single long story from blowing the model's
  context window; the deterministic per-story bucketing
  at the tail is what keeps validation honest — chunks
  from one story never appear in more than one split.
###
fs = require 'fs'
path = require 'path'

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

# (2026-09-12: removed buildStoryGroups / buildFragmentParagraphs /
# splitSingleParagraphTrainingText. They served the old
# per-paragraph-group training design; the rewritten step emits ONE
# row per whole story — `{prompt: simple_text, completion: jim_story}`
# — with no fragment splitting.)

# Deterministic per-story split. Sort story ids, then bucket by index:
# 0..7 → train, 8 → valid, 9 → test. No RNG state; identical stories in
# identical order always land in identical splits. Bucketing by story
# rather than by row matters because the chunker above emits multiple
# rows per story sharing the same prompt prefix — a row-level split
# would put near-duplicates in train AND valid, and valid loss would
# collapse into a memorization score.
splitStoryIds = (storyIds, trainOut = 8, validOut = 1, testOut = 1) ->
  total = trainOut + validOut + testOut
  sorted = storyIds.slice().sort()
  buckets =
    train: []
    valid: []
    test:  []
  for id, i in sorted
    bucket = i % total
    if bucket < trainOut
      buckets.train.push id
    else if bucket < trainOut + validOut
      buckets.valid.push id
    else
      buckets.test.push id
  buckets

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

    # Rows tagged with their origin story so we can bucket by story
    # after every row is emitted. The chunker is unchanged; it just
    # calls emit(storyID, rowText) instead of pushing to a flat array.
    rowsByStory = {}
    processedStoryIds = []
    rowsWritten = 0
    fallbackRowsWritten = 0
    storiesProcessed = 0

    # 2026-09-13: emit {prompt, completion} — the supervised shape
    # mlx_lm.lora expects when --mask-prompt is on. The trainer then
    # computes loss ONLY on completion tokens, which is the whole
    # point of a style-transfer LoRA (given plain content, produce
    # Jim's voice). The prior `{text: prompt + completion}` shape
    # trained on both halves equally and defeated the design.
    emit = (storyID, promptText, completionText) ->
      rowsByStory[storyID] ?= []
      rowsByStory[storyID].push prompt: promptText, completion: completionText
      rowsWritten += 1
      return

    # 2026-09-12 REDESIGN #2 — style-transfer training rows.
    #
    # Row shape:
    #   prompt     = the story's PLAIN-LANGUAGE RETELLING (from
    #                story_simplifications; populated by
    #                simplify_stories_ite before this step runs)
    #   completion = Jim's WHOLE original story
    #
    # This teaches the LoRA: "given plain content, produce Jim's voice."
    # A story with no simplification row yet is skipped (with a log)
    # — simplify_stories_ite must run first (guaranteed by the
    # elementary DAG's depends_on chain).
    #
    # Stories where prompt+completion exceed max_total_tokens are
    # logged and skipped. Bump the budget in the recipe if you want
    # more coverage.
    MAX_TOTAL_TOKENS = Number(L.param('max_total_tokens', 2048))
    SAFETY_TOKENS = 64
    skippedTooLong = 0
    skippedNoSimp = 0

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

      # Read the plain-language retelling from sqlite. If none exists
      # yet, skip this story — simplify_stories_ite must run first.
      simpEntry = L.theLowdown "storySimplification{#{storyID}}.json"
      simpRow = simpEntry?.value
      simpleText = String(simpRow?.simple_text ? '').trim()
      unless simpleText.length
        console.log "[#{L.stepName}] skip #{storyID}: no story_simplifications row yet (run simplify_stories_ite first)"
        skippedNoSimp += 1
        continue

      # Style-transfer pairing:
      #   prompt     = the plain-language retelling (drives conditioning)
      #   completion = Jim's original story (what the adapter should learn to produce)
      # No trailing "\n\n" on the prompt — the trainer joins the two
      # halves with tokenizer eos/bos glue as configured. Keep the
      # completion clean; EOS is appended in the collect() pass.
      promptText     = simpleText
      completionText = fullStoryText
      rowTokens = estimateTokens(promptText) + estimateTokens(completionText)

      if rowTokens + SAFETY_TOKENS > MAX_TOTAL_TOKENS
        console.log "[#{L.stepName}] skip #{storyID}: row is #{rowTokens} tok — exceeds max_total_tokens=#{MAX_TOTAL_TOKENS}"
        skippedTooLong += 1
        continue

      emit storyID, promptText, completionText
      storiesProcessed += 1
      processedStoryIds.push storyID if rowsByStory[storyID]?

    console.log "[#{L.stepName}] skipped no-simplification: #{skippedNoSimp}"
    console.log "[#{L.stepName}] skipped over-budget stories: #{skippedTooLong}"

    console.log "[build_lora_dataset_ite] stories processed:", storiesProcessed
    console.log "[build_lora_dataset_ite] rows written:", rowsWritten
    console.log "[build_lora_dataset_ite] single-paragraph fallback rows:", fallbackRowsWritten

    if rowsWritten is 0
      # 2026-09-12: no `pipeline:shutdown` emission. Composite recipes
      # (elementary) chain build_lora_dataset → train_lora → record via
      # depends_on. A shutdown here would halt the whole recipe; instead
      # emit empty row-sets so downstream steps see zero work and
      # exit cleanly, and let queue_run_ite pick the next entry.
      console.log "[build_lora_dataset_ite] selected stories produced no trainable rows — emitting empty row sets"
      L.make 'train_rows', []
      L.make 'valid_rows', []
      L.make 'test_rows', []
      L.done()
      return

    # --- EOS supervision ---------------------------------------------------
    modelDir = L.param('quantized_model_dir', null) ? L.param('loraLand', null)
    throw new Error "[#{L.stepName}] Missing model directory (quantized_model_dir or loraLand) — needed to read the end-of-turn token" unless modelDir?
    eotToken = resolveEotToken modelDir

    # --- Deterministic per-story split (80/10/10) --------------------------
    # Under 10 stories, plain modulo can leave valid/test empty; guard by
    # moving one story from train into each empty non-train bucket when we
    # have at least 3 stories to distribute.
    buckets = splitStoryIds processedStoryIds
    if processedStoryIds.length >= 3
      if buckets.valid.length is 0
        buckets.valid.push buckets.train.pop()
      if buckets.test.length is 0
        buckets.test.push buckets.train.pop()

    # EOS is appended to the COMPLETION half only — that's what
    # participates in the loss under --mask-prompt. Prompt tokens are
    # context; teaching the adapter to produce EOS after the story
    # is what makes generation stop cleanly at inference time.
    collect = (ids) ->
      out = []
      for id in ids
        continue unless rowsByStory[id]?
        for row in rowsByStory[id]
          out.push prompt: row.prompt, completion: "#{row.completion}#{eotToken}"
      out

    trainRows = collect buckets.train
    validRows = collect buckets.valid
    testRows  = collect buckets.test

    console.log "[build_lora_dataset_ite] split: #{buckets.train.length} train / #{buckets.valid.length} valid / #{buckets.test.length} test stories"
    console.log "[build_lora_dataset_ite] rows:  #{trainRows.length} train / #{validRows.length} valid / #{testRows.length} test"
    console.log "[build_lora_dataset_ite] appended EOT #{JSON.stringify eotToken}"

    L.make 'train_rows', trainRows
    L.make 'valid_rows', validRows
    L.make 'test_rows',  testRows
    L.done()
    return