###
  generate_prompt_llm.coffee  —  PROMPT_LLM pipeline step (optional RAG)
  =====================================================================
  Sibling of prompt_ite/generate_prompt_ite.coffee. Drives the in-process
  C++/node-mlx door via L.callLLM({op:'generate', ...}) — no Python spawn.

  RAG (folded in from the former prompt_rag_llm step): when `rag_top_k` > 0,
  the step first retrieves the top-K most similar Jim-story passages and
  prepends them as context — the LORE (characters, places, facts) the style
  adapter can't hold. `rag_top_k` = 0 (default) generates from the prompt
  as-is, i.e. the plain prompt_llm behaviour.

  Legacy hyphenated MLX keys under the yaml `mlx:` block are translated to
  camelCase (max-tokens → maxTokens, temp → temperature, top-p → topP,
  system-prompt → systemPrompt) so existing overrides keep working.
###
fs = require 'fs'

cleanGeneratedText = (prompt, rawOutput) ->
  text = String(rawOutput ? '').trim()
  return '' unless text.length

  if text.indexOf(prompt) is 0
    text = text.slice(prompt.length).trim()

  lines = text.split /\r?\n/
  lines = lines.filter (line) ->
    trimmed = line.trim()
    return false if /^=+$/.test trimmed
    return false if /^Prompt:\s+\d+\s+tokens/.test trimmed
    return false if /^Generation:\s+\d+\s+tokens/.test trimmed
    return false if /^Peak memory:\s+/.test trimmed
    true

  lines.join("\n").trim()

resolveRunTag = (L) ->
  raw = process.env.HH_MM ? L.theLowdown('env/HH_MM')?.value ? null
  return null unless raw?
  text = String(raw).trim()
  text = text.replace(/^"+|"+$/g, '')
  text = text.replace(/^'+|'+$/g, '')
  return null unless text.length
  text

buildDiaryRecord = (prompt, passages, text) ->
  lines = ["Prompt:", prompt, ""]
  if passages?.length
    ctx = ("- [#{p.cos.toFixed(3)}] #{p.story_id}##{p.chunk_index}" for p in passages).join("\n")
    lines.push "Retrieved passages:", ctx, ""
  lines.push "Generation:", text, ""
  lines.join "\n"

# --- RAG chunk reconstruction — MUST match kag_oracle_ite/oracle_ask_sqlite --
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

chunkTextFor = (storyText, chunkIndex) ->
  groups = buildStoryGroups storyText
  return '' unless groups.length
  idx = (Number(chunkIndex) or 1) - 1
  groups[idx] ? groups[0]

# Retrieve the top-K most similar story passages for `userPrompt`. Returns
# {augmented, passages}: the context-prefixed prompt and the passage records.
retrievePassages = (L, userPrompt, modelDir, topK) ->
  # 1. Embed the query as RAW text — matches the clean re-embeddings (made
  #    from raw chunk text).
  qEmb = (await L.callLLM {op: 'embed', modelDir: modelDir, prompt: userPrompt, raw: true})?.embedding
  throw new Error "[#{L.stepName}] query embed returned nothing" unless qEmb?

  # 2. Load chunk embeddings — prefer the CLEAN re-embeddings
  #    (build/chunk_embeddings_clean.jsonl from reembed_clean) over the
  #    content-diluted kag_embeddings.
  cleanFile = L.param 'clean_embeddings_file', 'build/chunk_embeddings_clean.jsonl'
  rows = null
  if fs.existsSync cleanFile
    rows = (JSON.parse(line) for line in String(fs.readFileSync(cleanFile, 'utf8')).split(/\r?\n/) when line.trim().length)
    console.log "[#{L.stepName}] using CLEAN re-embeddings (#{rows.length}) from #{cleanFile}"
  else
    rows = L.theLowdown('kagAllEmbeddings.jsonl')?.value ? []
    console.log "[#{L.stepName}] clean embeddings not found — using kag_embeddings (#{rows.length}); run reembed_clean for real retrieval"
  throw new Error "[#{L.stepName}] no chunk embeddings available" unless rows?.length

  # 3. Score every chunk embedding by cosine; sort desc.
  scored = []
  for r in rows when r?.embedding_b64?
    emb = L.tools.embedding_blob.blobToFloatArray Buffer.from(r.embedding_b64, 'base64')
    scored.push {story_id: r.story_id, chunk_index: r.chunk_index, cos: L.tools.embedding_blob.cosineSimilarity(qEmb, emb)}
  scored.sort (a, b) -> b.cos - a.cos

  # 4. Reconstruct passage text for the top-K (from stories.text).
  passages = []
  for s in scored
    break if passages.length >= topK
    story = L.theLowdown("storyByID{#{s.story_id}}.json")?.value
    continue unless story?.text?
    txt = chunkTextFor story.text, s.chunk_index
    continue unless txt.length
    passages.push {story_id: s.story_id, title: (story.title ? s.story_id), chunk_index: s.chunk_index, cos: s.cos, text: txt}

  console.log "[#{L.stepName}] top #{passages.length} passages for prompt \"#{userPrompt.slice(0,50)}\":"
  for p in passages
    console.log "  cos=#{p.cos.toFixed(4)}  #{p.story_id}##{p.chunk_index}  \"#{p.text.slice(0,70).replace(/\n/g, ' ')}...\""

  contextBlock = ("From \"#{p.title}\":\n#{p.text}" for p in passages).join "\n\n"
  augmented = "Context from Jim's writing:\n\n#{contextBlock}\n\n---\n\n#{userPrompt}"
  {augmented, passages}

@step =
  desc: "Generate from a UI prompt via L.callLLM(generate); optional top-K story RAG (rag_top_k)"

  action: (L) ->
    prompt = String(L.param('prompt_text', '') ? '').trim()
    throw new Error "[#{L.stepName}] prompt_text must be a non-empty string" unless prompt.length

    modelDir = L.param 'quantized_model_dir', null
    adapterPath = L.param 'adapter_path', null
    mlxConfig = L.param 'mlx', null
    llmConfig = L.param 'llm', null
    topK = Math.max(0, (Number(L.param('rag_top_k', 0)) or 0))
    outputPrefix = String(L.param('output_file_prefix', 'prompt_generate') ? 'prompt_generate').trim() or 'prompt_generate'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] mlx must be an object when provided" if mlxConfig? and (typeof mlxConfig isnt 'object' or Array.isArray(mlxConfig))
    throw new Error "[#{L.stepName}] llm must be an object when provided" if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))

    # Optional RAG: retrieve context and prepend it to the prompt.
    passages = []
    effectivePrompt = prompt
    if topK > 0
      retrieval = await retrievePassages L, prompt, modelDir, topK
      effectivePrompt = retrieval.augmented
      passages = retrieval.passages

    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: effectivePrompt
    llmArgs.adapterPath = adapterPath if adapterPath?

    if mlxConfig? and typeof mlxConfig is 'object'
      for own key, value of mlxConfig
        continue unless value?
        camel = switch key
          when 'max-tokens' then 'maxTokens'
          when 'temp', 'temperature' then 'temperature'
          when 'top-p' then 'topP'
          when 'system-prompt' then 'systemPrompt'
          else key
        llmArgs[camel] = value

    if llmConfig? and typeof llmConfig is 'object'
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op'
        llmArgs[key] = value

    result = await L.callLLM llmArgs
    rawOutput = String(result.rawText ? result.text ? '')
    text = cleanGeneratedText effectivePrompt, rawOutput

    meta =
      mode: (if topK > 0 then 'prompt_generate_rag_llm' else 'prompt_generate_llm')
      model_dir: modelDir
      adapter_path: adapterPath ? null
      rag_top_k: topK
      retrieved: ({story_id: p.story_id, chunk_index: p.chunk_index, cos: p.cos, title: p.title} for p in passages)
      prompt_chars: prompt.length
      augmented_chars: effectivePrompt.length
      raw_chars: rawOutput.length
      text_chars: text.length
      prompt_tokens: result.promptTokens ? null
      generated_tokens: result.generatedTokens ? null
      elapsed_sec: result.elapsedSec ? null
      ttft_sec: result.ttftSec ? null
      tok_per_sec: result.tokPerSec ? null
      peak_mem_gb: result.peakMemGB ? null

    console.log "[generate_prompt_llm] prompt chars:", prompt.length, (if topK > 0 then "(+RAG #{passages.length} passages)" else "")
    console.log "[generate_prompt_llm] text chars:", text.length
    if result.generatedTokens?
      console.log "[generate_prompt_llm] generated #{result.generatedTokens} tokens" +
        (if result.tokPerSec? then " (#{result.tokPerSec.toFixed(1)} tok/s)" else "")

    L.make 'prompt_generate_raw', rawOutput
    L.make 'prompt_generate_meta', meta
    L.make 'prompt_generate_text', text

    runTag = resolveRunTag L
    if typeof runTag is 'string' and runTag.length
      L.saveThis "out/#{outputPrefix}_#{runTag}.txt", text
      L.saveThis "diary/#{outputPrefix}_#{runTag}.txt", buildDiaryRecord(prompt, passages, text)

    L.done()
    return
