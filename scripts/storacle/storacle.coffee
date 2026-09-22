###
  scripts/storacle/storacle.coffee — STORACLE pipeline step
  =========================================================
  Prompt-exploration harness. Takes one of Jim's stories (by story_id
  chosen from a UI dropdown) and a prompt template (UI textarea) that
  contains any of these placeholders:

    {{{STORY}}}          → full raw story text
    {{{FRAGMENT_1}}} .. {{{FRAGMENT_5}}}
                          → the story chunked by `buildStoryGroups` (the
                            SAME chunker oracle_ask_sqlite uses and the
                            SAME one build_lora_dataset_ite pairs against
                            chunk_simplifications rows). This is the
                            distribution the adapter was TRAINED on
                            (2026-09-15+): one bland-vs-spicy pair per
                            chunk. Test the adapter at inference by
                            feeding a single fragment, not the whole
                            story — whole-story input is
                            out-of-distribution for a chunk-pair adapter.
                            Stories shorter than 5 paragraphs collapse
                            to a single group; FRAGMENT_2..5 resolve to
                            empty string in that case.

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

# 2026-09-16: `fs` + `path` requires retired — this step is now
# purely meta-mediated (all reads via S.theLowdown, all writes via
# S.make / S.saveThis). Matches pipeline/GPT/CONVENTIONS.md fs-stinginess.
STORY_PLACEHOLDER    = '{{{STORY}}}'
# 2026-09-15: numbered chunk placeholders. Indexed 1..5 to match
# buildStoryGroups' 1-based group_index. Five is fixed because
# buildStoryGroups always emits exactly 5 groups for stories with
# ≥5 paragraphs; short stories emit 1, and placeholders past the
# actual group count resolve to '' (harmless — a prompt template
# with unused {{{FRAGMENT_N}}} just gets empty substitutions there).
FRAGMENT_PLACEHOLDERS = ('{{{FRAGMENT_' + i + '}}}' for i in [1..5])

# --- Chunker for FRAGMENT_N placeholders -----------------------------------
# Bit-for-bit copy of the chunker in oracle_ask_sqlite.coffee (line ~324)
# AND build_lora_dataset_ite.coffee. All three MUST stay in sync — pair
# alignment between (chunk_simplifications.simple_text, storyGroups[i].text)
# depends on it. If oracle's chunker changes, this changes too.
splitParagraphsChunk = (text) ->
  rawParts = String(text ? '').split /\n\s*\n/
  parts = []
  for rawPart in rawParts
    part = String(rawPart ? '').replace(/\s+/g, ' ').trim()
    continue unless part.length
    parts.push part
  parts

buildStoryGroups = (text) ->
  paragraphs = splitParagraphsChunk text
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
    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    # 2026-09-15: neither placeholders nor story_id are required. If
    # story_id is empty, storacle runs the prompt as-is (KAG and
    # placeholder substitution both no-op). If story_id is set but the
    # story cannot be found we still fail — that catches typos, not
    # an intentionally-empty story_id.

    if storyId.length
      storyText = readStoryText L, storyId
      throw new Error "[#{L.stepName}] no story with story_id='#{storyId}' in CWD/runtime.sqlite" unless storyText?
      storyGroups = buildStoryGroups storyText
    else
      storyText   = ''
      storyGroups = []

    # Fragment placeholders resolve from `buildStoryGroups` in the same
    # order oracle_ask_sqlite processes chunks. Missing indices (story
    # has fewer groups than 5) → ''.
    fragmentTexts = for i in [1..5]
      (storyGroups[i - 1]?.text) ? ''

    # Placeholder substitution — all always resolved so the human can
    # mix them. Empty story / short story collapses unused placeholders
    # to '' (harmless).
    prompt = template.split(STORY_PLACEHOLDER).join(storyText)
    for placeholder, idx in FRAGMENT_PLACEHOLDERS
      prompt = prompt.split(placeholder).join(fragmentTexts[idx])

    # Optional prefix blocks — KAG first (structured signals), then
    # chunks (retrieval passages). Human's prompt template goes last.
    prefixParts = []
    kagBlock = ''
    passages = []
    if useKag and storyId.length
      kagBlock = readKagContext L, storyId
      prefixParts.push kagBlock if kagBlock.length
    if useChunks
      retrieval = await retrievePassages L, prompt, modelDir, ragTopK
      passages = retrieval.passages
      prefixParts.push retrieval.augmented if retrieval.augmented.length
    effectivePrompt = if prefixParts.length then prefixParts.join('') + prompt else prompt

    fragmentSummary = ("F#{i + 1}=#{fragmentTexts[i].length}" for i in [0...5]).join(' ')
    console.log "[storacle] story_id=#{storyId or '(none)'} (story=#{storyText.length} chars, groups=#{storyGroups.length}, #{fragmentSummary})"
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

    # 2026-09-15: stamp the effective llm config into meta so future
    # storacle_observations rows carry the sampling provenance. Copy
    # only the numeric/string fields — no functions or objects.
    llmSnapshot = {}
    if llmConfig? and typeof llmConfig is 'object' and not Array.isArray(llmConfig)
      for own k, v of llmConfig
        continue unless v?
        if typeof v is 'number' or typeof v is 'string' or typeof v is 'boolean'
          llmSnapshot[k] = v

    meta =
      mode: 'storacle'
      model_dir: modelDir
      adapter_path: adapterPath ? null
      story_id: storyId
      use_chunks: useChunks
      use_kag: useKag
      rag_top_k: ragTopK
      story_chars: storyText.length
      fragment_char_counts: (fragmentTexts[i].length for i in [0...5])
      kag_context_chars: kagBlock.length
      retrieved_passages: passages.map (p) -> {story_id: p.story_id, chunk_index: p.chunk_index, cos: p.cos}
      template_chars: template.length
      template_text: template
      prompt_chars: effectivePrompt.length
      llm_config: llmSnapshot
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
