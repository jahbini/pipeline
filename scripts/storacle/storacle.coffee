###
  scripts/storacle/storacle.coffee — STORACLE pipeline step
  =========================================================
  Prompt-exploration harness. Takes one of Jim's stories (by story_id
  chosen from a UI dropdown) and a prompt template (UI textarea) that
  contains any of these placeholders:

    {{{STORY}}}          → full raw story text (kept for backwards compat)
    {{{LEAD_FRAGMENT}}}  → the exact opening fragment fed to LoRA
                            training (via build_lora_dataset_ite's
                            `buildFragmentParagraphs` — first paragraph,
                            plus second if the first is <300 chars).
                            Use this when testing whether the trained
                            adapter recognizes its own training prompts.

  Optional context knobs (all default OFF so bare-minimum calls behave
  exactly as they did pre-augmentation):

    use_chunks (bool)    → prepend top-K clean-embedding passages
                            retrieved via cosine over kag_embeddings_clean.
                            RAG lite.
    use_kag (bool)       → prepend the story's kag_entries rows
                            (keyword,headline pairs) as inline context.
    adapter_path (str)   → path to a LoRA adapter dir or file. Empty
                            string / "none" = base model. If set,
                            passed through to L.callLLM as adapterPath.

  Contract:
    needs: [] (reads runtime.sqlite directly)
    makes: storacle_raw, storacle_meta, storacle_text
###

fs = require 'fs'
path = require 'path'

STORY_PLACEHOLDER = '{{{STORY}}}'
LEAD_PLACEHOLDER  = '{{{LEAD_FRAGMENT}}}'

# Same helpers build_lora_dataset_ite uses. Kept byte-identical so
# {{{LEAD_FRAGMENT}}} substitution exactly matches what the LoRA saw
# during training.
splitParagraphs = (text) ->
  parts = []
  for rawPart in String(text ? '').split(/\n\s*\n/)
    part = String(rawPart ? '').trim()
    parts.push part if part.length
  parts

buildFragmentParagraphs = (paragraphs) ->
  rval = []
  return rval unless Array.isArray(paragraphs) and paragraphs.length
  firstPara = paragraphs[0] ? ''
  rval.push firstPara.trim() if firstPara.trim().length
  currentLen = rval.join("\n\n").length
  if currentLen < 300 and paragraphs.length > 2
    secondPara = paragraphs[1] ? ''
    rval.push secondPara.trim() if secondPara.trim().length
  rval

leadFragmentFor = (storyText) ->
  buildFragmentParagraphs(splitParagraphs(storyText)).join "\n\n"

readStoryText = (L, storyId) ->
  row = L.theLowdown("storyByID{#{storyId}}.json")?.value
  row?.text

# kag_entries → a short context block: one line per (keyword, headline)
# tuple. Reads via the sqlite meta rule to stay in-framework.
readKagContext = (L, storyId) ->
  rows = L.theLowdown("kagFor{#{storyId}}.jsonl")?.value
  return '' unless Array.isArray(rows) and rows.length
  seen = {}
  lines = []
  for r in rows when r?.keyword? and r?.headline?
    key = "#{r.keyword}|#{r.headline}"
    continue if seen[key]
    seen[key] = true
    lines.push "  - ##{r.keyword}: #{r.headline}"
  return '' unless lines.length
  "Story-derived context (KAG):\n" + lines.join("\n") + "\n\n"

# Top-K clean-embedding retrieval. Off unless use_chunks=true. Mirrors
# the retrieval in generate_prompt_llm.coffee. Reads from
# `kag_embeddings_clean` via the `kagAllCleanEmbeddings.jsonl` view.
retrievePassages = (L, queryText, modelDir, topK) ->
  return {augmented: '', passages: []} unless topK > 0 and queryText?.length
  qEmb = (await L.callLLM {op: 'embed', modelDir: modelDir, prompt: queryText, raw: true})?.embedding
  return {augmented: '', passages: []} unless qEmb?
  rows = L.theLowdown('kagAllCleanEmbeddings.jsonl')?.value ? []
  rows = L.theLowdown('kagAllEmbeddings.jsonl')?.value ? [] unless rows.length
  return {augmented: '', passages: []} unless rows.length
  scored = []
  for r in rows when r?.embedding_b64?
    emb = L.tools.embedding_blob.blobToFloatArray Buffer.from(r.embedding_b64, 'base64')
    scored.push {story_id: r.story_id, chunk_index: r.chunk_index, cos: L.tools.embedding_blob.cosineSimilarity(qEmb, emb)}
  scored.sort (a, b) -> b.cos - a.cos
  passages = []
  for s in scored
    break if passages.length >= topK
    story = L.theLowdown("storyByID{#{s.story_id}}.json")?.value
    continue unless story?.text?
    passages.push {story_id: s.story_id, title: (story.title ? s.story_id), chunk_index: s.chunk_index, cos: s.cos}
  return {augmented: '', passages: passages} unless passages.length
  contextBlock = ("From \"#{p.title}\" (chunk #{p.chunk_index}, cos=#{p.cos.toFixed(3)}):" for p in passages).join "\n"
  augmented = "Related passages (from clean embeddings):\n#{contextBlock}\n\n"
  {augmented, passages}

# Coerce a UI checkbox value (boolean OR string "true"/"false"/"1"/"0").
truthy = (v) ->
  return true if v is true
  return false unless v?
  s = String(v).toLowerCase()
  s in ['1', 'true', 'yes', 'on']

# Adapter param — accepts several sentinels for "no adapter":
#   null | "" | "none" | "base" | "-"
resolveAdapterPath = (raw) ->
  return null unless raw?
  s = String(raw).trim()
  return null unless s.length
  return null if s.toLowerCase() in ['none', 'base', '-']
  s

@step =
  desc: "Substitute placeholders in prompt_text with story text/context and call callLLM(generate)"

  action: (L) ->
    template  = String(L.param('prompt_text', '') ? '')
    storyId   = String(L.param('story_id', '') ? '').trim()
    modelDir  = L.param 'quantized_model_dir', null
    llmConfig = L.param 'llm', null
    useChunks = truthy L.param('use_chunks', false)
    useKag    = truthy L.param('use_kag', false)
    ragTopK   = Math.max(0, Number(L.param('rag_top_k', 4)) or 0)
    adapterRaw = L.param 'adapter_path', null
    adapterPath = resolveAdapterPath adapterRaw

    throw new Error "[#{L.stepName}] prompt_text is empty — nothing to send" unless template.trim().length
    throw new Error "[#{L.stepName}] story_id is empty — pick a story from the UI dropdown" unless storyId.length
    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    unless template.indexOf(STORY_PLACEHOLDER) >= 0 or template.indexOf(LEAD_PLACEHOLDER) >= 0
      throw new Error "[#{L.stepName}] prompt_text must contain #{STORY_PLACEHOLDER} or #{LEAD_PLACEHOLDER} — that's where the story text will be substituted"

    storyText = readStoryText L, storyId
    throw new Error "[#{L.stepName}] no story with story_id='#{storyId}' in CWD/runtime.sqlite" unless storyText?
    leadText = leadFragmentFor storyText

    # Placeholder substitution — both are always resolved so the human
    # can mix them ("Given the lead {{{LEAD_FRAGMENT}}}, complete the
    # story like Jim would; original for reference: {{{STORY}}}").
    prompt = template
      .split(STORY_PLACEHOLDER).join(storyText)
      .split(LEAD_PLACEHOLDER).join(leadText)

    # Optional prefix blocks — KAG first (structured signals), then
    # chunks (retrieval passages). Human's prompt template goes last.
    prefixParts = []
    kagBlock = ''
    passages = []
    if useKag
      kagBlock = readKagContext L, storyId
      prefixParts.push kagBlock if kagBlock.length
    if useChunks
      retrieval = await retrievePassages L, prompt, modelDir, ragTopK
      passages = retrieval.passages
      prefixParts.push retrieval.augmented if retrieval.augmented.length
    effectivePrompt = if prefixParts.length then prefixParts.join('') + prompt else prompt

    console.log "[storacle] story_id=#{storyId} (#{storyText.length} chars, lead=#{leadText.length})"
    console.log "[storacle] flags: use_chunks=#{useChunks} (top-#{ragTopK}, #{passages.length} retrieved) use_kag=#{useKag} (#{kagBlock.length} chars) adapter=#{adapterPath ? '(none — base model)'}"
    console.log "[storacle] template=#{template.length} → effective prompt=#{effectivePrompt.length} chars"
    console.log "[storacle] modelDir: #{modelDir}"

    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: effectivePrompt
      raw: true
    llmArgs.adapterPath = adapterPath if adapterPath?
    if llmConfig? and typeof llmConfig is 'object' and not Array.isArray(llmConfig)
      for own key, value of llmConfig
        continue unless value?
        llmArgs[key] = value

    result = await L.callLLM llmArgs

    raw = String(result?.rawText ? result?.text ? '')
    console.log "[storacle] generated #{result?.generatedTokens} tokens in #{result?.elapsedSec?.toFixed?(2) ? '?'}s"

    meta =
      mode: 'storacle'
      model_dir: modelDir
      adapter_path: adapterPath ? null
      story_id: storyId
      use_chunks: useChunks
      use_kag: useKag
      story_chars: storyText.length
      lead_chars: leadText.length
      kag_context_chars: kagBlock.length
      retrieved_passages: passages.map (p) -> {story_id: p.story_id, chunk_index: p.chunk_index, cos: p.cos}
      template_chars: template.length
      prompt_chars: effectivePrompt.length
      generated_tokens: result?.generatedTokens ? null
      prompt_tokens: result?.promptTokens ? null
      elapsed_sec: result?.elapsedSec ? null
      tok_per_sec: result?.tokPerSec ? null
      stop_marker: result?.stopMarker ? null
      peak_mem_gb: result?.peakMemGB ? null

    L.make 'storacle_raw', raw
    L.make 'storacle_meta', meta
    L.make 'storacle_text', String(result?.text ? raw)
    L.done()
    return
