###
  reembed_chunks_clean.coffee — clean semantic re-embed of story chunks
  =====================================================================
  Re-embeds each chunk's RAW text (raw:true, no classification prompt)
  so RAG retrieval discriminates by content instead of the ChatML noise
  in kag_embeddings.

  SQLITE-BACKED (2026-09-11 rewrite). Both the pending-work list and
  the embeddings themselves live in sqlite now — no JSONL file:
    - reads `storiesMissingCleanEmbeddings.jsonl` (meta/sqlite view)
      to get the batch of stories still missing clean embeddings
    - writes each chunk's embedding via
      `kagEmbeddingCleanRegister{story_id|chunk_index}.json`
      → landing in the `kag_embeddings_clean` table
    - retrievers (generate_prompt_llm) read `kagAllCleanEmbeddings.jsonl`

  BATCH pattern — modeled after oracle_ask_sqlite. Matched batch_size
  so oracle and reembed march in lockstep (4 stories per iteration).
  Calls `L.iterate()` if more pending, invalidates the pending-work
  view before the next iteration. When drained, L.done() naturally
  completes the step.

  Idempotent across restarts: sqlite is the source of truth for both
  "what's pending" and "what's already embedded." A crash mid-batch
  costs at most one batch of embed work; the next launch resumes
  from the current pending set.
###

@step =
  desc: "Re-embed a batch of story chunks (raw-text embeddings for RAG, sqlite-backed)"

  action: (L) ->
    fs   = require 'fs'
    path = require 'path'

    batchSzRaw = L.param 'batch_size'
    batchSz = Number(batchSzRaw)
    throw new Error "[#{L.stepName}] batch_size must be a positive integer" unless Number.isFinite(batchSz) and batchSz > 0 and Math.floor(batchSz) is batchSz

    # Model dir resolution — same graceful degradation session_api uses.
    quantParam = L.param 'quantized_model_dir', null
    modelParam = L.param 'model_dir', null
    loraLand   = L.param 'loraLand', null
    candidates = [quantParam, modelParam]
    if quantParam and quantParam.endsWith('-mlx4')
      candidates.push quantParam.slice(0, -'-mlx4'.length)
    candidates.push loraLand if loraLand
    modelDir = null
    for c in candidates when c
      if fs.existsSync(c) and fs.existsSync(path.join(c, 'config.json'))
        modelDir = c
        break
    unless modelDir?
      throw new Error "[#{L.stepName}] no usable model dir; tried: #{candidates.filter((c)->c).join(', ')}"
    console.log "[#{L.stepName}] using modelDir=#{modelDir}"

    # 1. Pull the pending-work list from sqlite (via meta rule).
    pendingStories = L.theLowdown('storiesMissingCleanEmbeddings.jsonl')?.value ? []
    unless Array.isArray pendingStories
      throw new Error "[#{L.stepName}] storiesMissingCleanEmbeddings.jsonl must be an array (got #{typeof pendingStories})"

    console.log "[#{L.stepName}] stories pending clean-reembed: #{pendingStories.length}"

    if pendingStories.length is 0
      # Drained — nothing to do. Downstream steps proceed.
      L.make 'reembed_remaining_count', 0
      L.done()
      return

    batch = pendingStories.slice 0, batchSz
    remainingAfterBatch = Math.max(pendingStories.length - batch.length, 0)
    console.log "[#{L.stepName}] batch=#{batch.length} (#{remainingAfterBatch} stories will remain after this batch)"

    # 2. For each story in the batch, chunk it and embed each chunk;
    #    persist each embedding to sqlite via the register request key.
    #    Chunking matches the oracle's 5-group split (buildStoryGroups
    #    would live in a tool if this pattern grew a third caller).
    splitParagraphs = (text) ->
      parts = []
      for rawPart in String(text ? '').split(/\n\s*\n/)
        part = String(rawPart ? '').replace(/\s+/g, ' ').trim()
        parts.push part if part.length
      parts

    buildStoryGroups = (text) ->
      paragraphs = splitParagraphs text
      return [] unless paragraphs.length
      return [ paragraphs.join("\n\n") ] if paragraphs.length < 5
      groups = []
      total = paragraphs.length
      baseSize = Math.floor(total / 5)
      remainder = total % 5
      startIndex = 0
      for groupIndex in [0...5]
        groupSize = baseSize + (if groupIndex < remainder then 1 else 0)
        selected = paragraphs.slice startIndex, startIndex + groupSize
        groups.push selected.join("\n\n")
        startIndex += groupSize
      groups

    appended = 0
    for story, si in batch
      sid = story.story_id ? story.id ? story.doc_id ? null
      continue unless sid? and story.text?
      groups = buildStoryGroups story.text
      for text, i in groups
        continue unless text.length
        chunkIndex = i + 1
        emb = (await L.callLLM {op: 'embed', modelDir: modelDir, prompt: text, raw: true})?.embedding
        continue unless emb?
        embBlob = L.tools.embedding_blob.floatArrayToBlob emb
        L.saveThis "kagEmbeddingCleanRegister{#{sid}|#{chunkIndex}}.json",
          story_id:    sid
          chunk_index: chunkIndex
          dim:         emb.length
          embedding:   embBlob
        appended += 1
      console.log "[#{L.stepName}] batch #{si + 1}/#{batch.length}: #{sid} — #{appended} chunks written so far"

    L.make 'reembed_remaining_count', remainingAfterBatch
    console.log "[#{L.stepName}] batch done — appended #{appended} chunk embeddings; #{remainingAfterBatch} stories pending"

    if remainingAfterBatch > 0
      # More work — iterate. Invalidate the pending-work view so the
      # next iteration re-queries sqlite (which now includes rows we
      # just wrote).
      L.iterate?(
        "#{remainingAfterBatch} stories still pending for clean-reembed"
        invalidate: ['storiesMissingCleanEmbeddings.jsonl']
      )

    L.done()
    return
