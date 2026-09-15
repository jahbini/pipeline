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
  # NOTE: this matches the whitespace-collapsing form in
  # oracle_ask_sqlite.coffee — both files must chunk identically or the
  # bland/spicy pair alignment breaks. Keep in sync.
  rawParts = String(text ? '').split /\n\s*\n/
  parts = []
  for rawPart in rawParts
    part = String(rawPart ? '').replace(/\s+/g, ' ').trim()
    continue unless part.length
    parts.push part
  parts

# 2026-09-15: RE-ADDED buildStoryGroups. Bit-for-bit copy of the
# function in `oracle_ask_sqlite.coffee` (line ~339) — the LoRA
# training pair (bland from chunk_simplifications, spicy from
# stories.text) only aligns when both sides use the SAME chunker on
# the SAME story text. If oracle_ask_sqlite ever changes its chunking,
# THIS FUNCTION MUST CHANGE IN LOCKSTEP. Consider extracting to a
# shared helper when a third caller appears.
buildStoryGroups = (text) ->
  paragraphs = splitParagraphs text
  return [] unless paragraphs.length

  if paragraphs.length < 5
    return [
      group_index: 1
      start_paragraph: 1
      end_paragraph: paragraphs.length
      paragraphs: paragraphs.slice()
      text: paragraphs.join "\n\n"
    ]

  groups = []
  total = paragraphs.length
  baseSize = Math.floor(total / 5)
  remainder = total % 5
  startIndex = 0

  for groupIndex in [0...5]
    groupSize = baseSize
    groupSize += 1 if groupIndex < remainder
    selected = paragraphs.slice startIndex, startIndex + groupSize
    endIndex = startIndex + selected.length - 1
    groups.push
      group_index: groupIndex + 1
      start_paragraph: startIndex + 1
      end_paragraph: endIndex + 1
      paragraphs: selected
      text: selected.join "\n\n"
    startIndex += groupSize

  groups

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

    # 2026-09-15 REDESIGN #3 — per-chunk style-transfer training rows.
    #
    # Row shape (one row per chunk, up to 5 rows per story):
    #   prompt     = chunk_simplifications.simple_text[i]
    #                (bland plain-English rewrite of THAT chunk;
    #                 populated by oracle_ask_sqlite on every run)
    #   completion = buildStoryGroups(story.text)[i-1].text
    #                (Jim's original spicy chunk; regenerated
    #                 deterministically from stories.text)
    #
    # Both sides use the SAME chunker so pairs align by index.
    # Rationale: the prior redesign #2 fed whole story → whole story,
    # which trained on paragraph-arc as much as voice. Users asked
    # for local bland↔spicy pairs so the adapter learns rewording
    # per paragraph-group, decoupled from narrative structure.
    #
    # A story with no chunk_simplifications rows is skipped (with a
    # log) — oracle_ask_sqlite must run first (guaranteed by the
    # elementary DAG's depends_on chain).
    #
    # Chunks where prompt+completion exceed max_total_tokens are
    # logged and skipped INDIVIDUALLY — other chunks from the same
    # story still contribute if they fit.
    MAX_TOTAL_TOKENS = Number(L.param('max_total_tokens', 2048))
    SAFETY_TOKENS = 64
    skippedTooLong = 0
    skippedNoSimp = 0
    skippedNoMatch = 0

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

      # Read all bland-rewrite rows for this story. Empty → skip.
      chunksEntry = L.theLowdown "chunkSimplificationsForStory{#{storyID}}.jsonl"
      chunkRows = chunksEntry?.value
      unless Array.isArray(chunkRows) and chunkRows.length
        console.log "[#{L.stepName}] skip #{storyID}: no chunk_simplifications rows yet (run oracle_ask_sqlite first)"
        skippedNoSimp += 1
        continue

      # Deterministic re-chunk of the spicy source, keyed by group_index
      # (1..5). Must match oracle's chunker exactly — that's the
      # invariant behind pair alignment.
      spicyGroups = buildStoryGroups fullStoryText
      spicyByIdx = {}
      for group in spicyGroups
        spicyByIdx[group.group_index] = group.text

      emittedThisStory = 0
      for row in chunkRows
        chunkIdx = Number(row?.chunk_index)
        continue unless Number.isFinite(chunkIdx) and chunkIdx > 0
        promptText = String(row?.simple_text ? '').trim()
        continue unless promptText.length
        completionText = String(spicyByIdx[chunkIdx] ? '').trim()
        unless completionText.length
          # Bland row exists but the deterministic chunker no longer
          # produces a group at that index — story text may have
          # shrunk (edits since the bland was generated). Skip.
          console.log "[#{L.stepName}] #{storyID}|#{chunkIdx}: no spicy chunk at that index (chunker mismatch)"
          skippedNoMatch += 1
          continue

        rowTokens = estimateTokens(promptText) + estimateTokens(completionText)
        if rowTokens + SAFETY_TOKENS > MAX_TOTAL_TOKENS
          console.log "[#{L.stepName}] skip #{storyID}|#{chunkIdx}: #{rowTokens} tok — exceeds max_total_tokens=#{MAX_TOTAL_TOKENS}"
          skippedTooLong += 1
          continue

        emit storyID, promptText, completionText
        emittedThisStory += 1

      if emittedThisStory > 0
        storiesProcessed += 1
        processedStoryIds.push storyID if rowsByStory[storyID]?

    console.log "[#{L.stepName}] skipped no-simplification: #{skippedNoSimp}"
    console.log "[#{L.stepName}] skipped chunker-mismatch chunks: #{skippedNoMatch}"
    console.log "[#{L.stepName}] skipped over-budget chunks: #{skippedTooLong}"

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