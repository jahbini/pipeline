###
  reembed_chunks_clean.coffee — clean semantic re-embed of story chunks
  =====================================================================
  The oracle embedded ChatML(classification-prompt + chunk), so those vectors
  are content-diluted — RAG cosines came out clustered in a ~0.004 range and
  ranking was noise. This re-embeds each chunk's RAW text (raw:true, no
  classification prompt) so retrieval discriminates by content.

  Writes build/chunk_embeddings_clean.jsonl (one JSON object per line:
  {story_id, chunk_index, embedding_b64}) which generate_prompt_llm reads (rag_top_k > 0)
  in preference to kag_embeddings. Chunking matches the oracle's 5-group split
  so chunk_index still maps to the same passage for text reconstruction.

  One-time; re-run if the corpus changes. ~1-3 min for ~900 chunks (embed is a
  single cold-KV prefill each; session cache disposed per call, so flat memory).
###
fs   = require 'fs'
path = require 'path'

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

@step =
  desc: "Re-embed each story chunk's raw text (clean semantic embeddings for RAG)"

  action: (L) ->
    # Resolve model dir with the same graceful degradation session_api
    # uses. Priority:
    #   1. explicit `quantized_model_dir` param (if set and dir exists)
    #   2. that same path with `-mlx4` stripped (raw fp16 dir) if the
    #      quantized dir is missing but the raw is present — matches
    #      the fallback symlink pattern quantize_model.coffee stages
    #      after a Metal crash.
    #   3. `model_dir` param, or run.loraLand.
    # We throw only if NOTHING is usable.
    quantParam = L.param 'quantized_model_dir', null
    modelParam = L.param 'model_dir', null
    loraLand   = L.param 'loraLand', null   # ${MODELS}/${run.model}
    candidates = [quantParam, modelParam]
    # If quantParam ends with -mlx4 and doesn't exist, try the raw
    # sibling. session_api does the same trick.
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
    console.log "[#{L.stepName}] using modelDir=#{modelDir} (from: #{if modelDir is quantParam then 'quantized_model_dir' else if modelDir is modelParam then 'model_dir' else 'raw fallback'})"
    outFile = String(L.param('clean_embeddings_file', 'build/chunk_embeddings_clean.jsonl'))

    stories = L.theLowdown('allStories.jsonl')?.value ? []
    throw new Error "[#{L.stepName}] no stories in this pipe" unless stories.length

    lines = []
    chunkCount = 0
    for story, si in stories
      sid = story.story_id ? story.id ? story.doc_id ? null
      continue unless sid? and story.text?
      groups = buildStoryGroups story.text
      for text, i in groups
        continue unless text.length
        emb = (await L.callLLM {op: 'embed', modelDir: modelDir, prompt: text, raw: true})?.embedding
        continue unless emb?
        b64 = L.tools.embedding_blob.floatArrayToBlob(emb).toString('base64')
        lines.push JSON.stringify {story_id: sid, chunk_index: i + 1, embedding_b64: b64}
        chunkCount += 1
      console.log "[#{L.stepName}] #{si + 1}/#{stories.length} stories, #{chunkCount} chunks embedded" if (si + 1) % 25 is 0

    # Write real JSONL directly (one object per line) — NOT via L.make with a
    # .jsonl target, which mangled a pre-joined string into millions of lines.
    fs.writeFileSync outFile, (if lines.length then lines.join("\n") + "\n" else "")
    console.log "[#{L.stepName}] done — wrote #{chunkCount} chunk embeddings (#{lines.length} lines) to #{outFile}"
    L.done()
    return
