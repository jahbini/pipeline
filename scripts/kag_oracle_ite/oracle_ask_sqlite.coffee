###
  oracle_ask_sqlite.coffee  —  ORACLE_ITE pipeline step
  =====================================================
  The workhorse of the oracle pipeline. For each new
  story without KAG, sends the oracle prompt through
  the in-process LLM door (L.callLLM), parses the
  model's `#keyword --- headline` lines into KAG row
  objects, and writes them back through the
  `kagFor{...}.json` sqlite request key. Failed parses
  increment `oracleFailureFor{...}` for backoff.

  Embedding pipeline: for each chunk, ALSO produce a
  1024-dim Float32 embedding via L.callLLM({op:'embed'}).
  Same last-layer-V mean-pool as before; the K/V cache
  lives in-process now, no safetensors file detour.
  Persisted via kagEmbeddingRegister request key (see
  GPT/eval_ite/embedding_blob.md for the downstream
  voice-similarity scoring consumer).
###
# embedding_blob is reached as `S.tools.embedding_blob.<fn>(...)` —
# we only need its floatArrayToBlob helper to serialize the
# Float32Array into a SQLite BLOB.
cleanFragment = (value) ->
  text = String(value ? '').trim()
  text = text.replace /^\*+|\*+$/g, ''
  text = text.replace /^["'“”]+|["'“”]+$/g, ''
  text = text.replace /\bend_assistant_\d+\b/ig, ''
  text = text.replace /\bassistant_\d+\b/ig, ''
  text = text.replace /_+/g, '_'
  text.trim()

ALLOWED_EMOTION_KEYWORDS = new Set [
  # Ekman-adjacent core (original 12)
  'joy'
  'contentment'
  'sadness'
  'grief'
  'fear'
  'anxiety'
  'anger'
  'frustration'
  'disgust'
  'shame'
  'surprise'
  'neutral'
  # Register additions (2026-08-06) — fit Jim's dominant tones that
  # the Ekman set collapses awkwardly. See GPT/story/kag_vocabulary.md.
  'absurd'
  'wry'
  'playful'
  'melancholy'
  'mysterious'
]

normalizeAllowedEmotionKeyword = (value) ->
  text = cleanFragment(value).toLowerCase()
  text = text.replace /^#/, ''
  text = text.replace /[^a-z0-9]+/g, '_'
  text = text.replace /^_+|_+$/g, ''
  return null unless text.length
  return text if ALLOWED_EMOTION_KEYWORDS.has(text)
  match = text.match /^(joy|contentment|sadness|grief|fear|anxiety|anger|frustration|disgust|shame|surprise|neutral|absurd|wry|playful|melancholy|mysterious)(?:_|$)/
  return match[1] if match?
  null

toEmotionKey = (value, fallbackIndex) ->
  text = cleanFragment(value).toLowerCase()
  text = text.replace /^#/, ''
  text = text.replace /#/g, '_'
  text = text.replace /[^a-z0-9]+/g, '_'
  text = text.replace /^_+|_+$/g, ''
  text = "emotion_#{fallbackIndex}" unless text.length
  text

# Some models emit the whole numbered list on ONE line — e.g.
# `1. #Joy --- ...  2. #Contentment --- ...  3. #Disgust --- ...`
# — and continue past the answer with `<|endoftext|>` followed by a
# hallucinated re-echo of the prompt. Normalize both before the
# per-line loop so a glued single-line response still produces N
# separate parsed items.
#
# Steps:
#   1. Truncate at any end-of-text-ish marker (`<|endoftext|>`,
#      `<|im_end|>`, `</s>`) — everything after is hallucinated echo.
#   2. Split BEFORE any inline ` N. #Word` / ` N. Word ---` boundary
#      by inserting a newline. Anchor: whitespace, one-or-more digits,
#      dot, whitespace, optional hash, then a letter. Applied only
#      when there IS whitespace preceding — so a legitimate
#      line-leading `1.` at position 0 is untouched.
normalizeRaw = (raw) ->
  s = String(raw ? '')
  s = s.split(/<\|endoftext\|>|<\|im_end\|>|<\/s>/)[0]
  s = s.replace /[ \t]+(\d+)\.\s+(#?[A-Za-z])/g, '\n$1. $2'
  s

extractJSON = (raw) ->
  return {} unless raw?
  block = raw.match(/\{[\s\S]*\}/)?[0]
  if block?
    try
      return JSON.parse block
    catch
      null

  { headlined, bare } = extractTiers raw
  # Precedence: any headlined entry wins over a bare one for the same
  # key. If ANY headlined entries exist, bare entries are dropped in
  # full (they're almost always warm-up / tail echo of the allowed
  # keyword list). This matches the observed model behavior where the
  # real answer is a middle block of `Keyword -- text` lines surrounded
  # by list-repetition noise. The two tiers are exported separately
  # via extractTiers so probes can see what was dropped.
  if Object.keys(headlined).length > 0
    headlined
  else
    bare

# Two-tier parse. Exposed so probes can see EVERYTHING the parser
# extracted — both winners and losers under the precedence rule —
# rather than only the survivors.
#   headlined — line had a separator + real text (`#Joy --- <text>`
#               or `Joy -- <text>`).
#   bare      — line was just a keyword (e.g. the prompt-echo warm-up
#               `Joy\nContentment\n...`).
extractTiers = (raw) ->
  return {headlined: {}, bare: {}} unless raw?
  headlined = {}
  bare      = {}
  lines     = normalizeRaw(raw).split /\r?\n/

  # Separators the LLM uses between key and headline. Accept 2+ hyphens
  # (`--`, `---`, `----`), em-dash, en-dash, or 1+ equals signs (the
  # storacle-authored prompt uses `#keyword = headline`).
  SEP = /(?:-{2,}|—|–|=+)/

  for line, idx in lines
    cleanedLine = String(line ? '').trim()
    continue unless cleanedLine.length
    continue if /^=+$/.test(cleanedLine)

    # Optionally strip a leading ordinal (`1.`, `2)`, `3 -`, …). The
    # ordinal is a courtesy; the emotion keyword itself is the anchor,
    # so lines without a number are accepted too.
    ordinal = idx + 1
    body = cleanedLine
    numbered = cleanedLine.match /^\s*(\d+)(?!\d)[^A-Za-z\s]*\s*(.+?)\s*$/
    if numbered?
      ordinal = Number numbered[1]
      body = cleanFragment numbered[2]

    body = cleanFragment body
    continue unless body.length

    # `#Keyword --- headline` (any 2+-hyphen or dash separator).
    strictHash = body.match new RegExp "^#([A-Za-z0-9_-]+)\\s*" + SEP.source + "\\s*(.+?)\\s*$"
    if strictHash?
      emotionKey = toEmotionKey strictHash[1], ordinal
      emotionText = cleanFragment strictHash[2]
      continue unless emotionText.length
      headlined[emotionKey] = emotionText
      continue

    # `Keyword --- headline` (no hash prefix, any 2+-hyphen or dash).
    looseStructured = body.match new RegExp "^(.+?)\\s*" + SEP.source + "\\s*(.+?)\\s*$"
    if looseStructured?
      emotionKey = toEmotionKey looseStructured[1], ordinal
      emotionText = cleanFragment looseStructured[2]
      continue unless emotionText.length
      headlined[emotionKey] = emotionText
      continue

    emotionKey = toEmotionKey body, ordinal
    bare[emotionKey] = cleanFragment body

  {headlined, bare}

# Hoisted to module scope so probes can inspect exactly which
# patterns caught a rejected entry (see writer/test/oracle_probe.coffee).
# Order matters for per-rule attribution — the probe reports the FIRST
# matching rule per rejected key.
REJECT_PATTERNS = [
  { name: 'short_headline',        re: /\bshort headline\b/i }
  { name: 'final_answer',          re: /\bfinal answer\b/i }
  { name: 'note',                  re: /\bnote\b/i }
  { name: 'prompt',                re: /\bprompt\b/i }
  { name: 'generation',            re: /\bgeneration\b/i }
  { name: 'peak_memory',           re: /\bpeak memory\b/i }
  { name: 'tokens_per_sec',        re: /\btokens-per-sec\b/i }
  { name: 'no_response',           re: /\bno response\b/i }
  { name: 'refusal_sorry',         re: /\bi(?:'| a)?m sorry\b/i }
  { name: 'refusal_cannot',        re: /\bcan(?:not|'t)\b/i }
  { name: 'misunderstanding',      re: /\bmisunderstanding\b/i }
  { name: 'clarify',               re: /\bclarify\b/i }
  { name: 'boilerplate_requested', re: /\brequested content formatted\b/i }
  { name: 'placeholder',           re: /\bplaceholder\b/i }
]

filterEmotions = (emotions) ->
  return {} unless emotions? and typeof emotions is 'object'

  filtered = {}
  seenValues = new Set()

  for own key, value of emotions
    emotionKey = normalizeAllowedEmotionKeyword(key) ? normalizeAllowedEmotionKeyword(value)
    continue unless emotionKey?
    emotionText = cleanFragment value
    continue unless emotionText.length
    continue if REJECT_PATTERNS.some (p) -> p.re.test(emotionKey) or p.re.test(emotionText)
    dedupeKey = "#{emotionKey}|#{emotionText.toLowerCase()}"
    continue if seenValues.has dedupeKey
    seenValues.add dedupeKey
    filtered[emotionKey] = emotionText

  filtered

isUsableEmotionList = (emotions) ->
  return false unless emotions? and typeof emotions is 'object'
  Object.keys(emotions).length >= 1

# Map the legacy `mlx:` block's kebab-case CLI flags onto the LLM
# door's camelCase gopts. Unrecognized keys pass through as-is so a
# recipe/override that already speaks camelCase (an `llm:` block)
# also works. Values that mlx_lm CLI needed but callLLM does not
# (e.g. max-kv-size) are silently dropped.
MLX_TO_LLM_KEY = {
  'max-tokens':    'maxTokens'
  'temp':          'temperature'
  'temperature':   'temperature'
  'top-p':         'topP'
  'topP':          'topP'
  'seed':          'seed'
  # dropped (session-level, not per-call): 'max-kv-size'
}

buildGenerateOpts = (block) ->
  return {} unless block? and typeof block is 'object' and not Array.isArray(block)
  out = {}
  for own key, value of block
    continue unless value?
    mapped = MLX_TO_LLM_KEY[key] ? key
    continue if mapped is null                # explicit drop
    out[mapped] = value
  out

runOracleOnce = (S, modelDir, prompt, adapterPath, llmConfig, debugLlm = false) ->
  # Two calls to the in-process LLM door. Both are cold-KV per call
  # (session_api.embed disposes the cache before and after; generate
  # runs in the same session but with a fresh prefill because the cache
  # was cleared). This matches the human-directed rule: the oracle sees
  # no cross-story context, only the one chunk it's classifying.
  embedding = null
  embeddingError = null
  embedParams =
    op:       'embed'
    modelDir: modelDir
    prompt:   prompt
  embedParams.adapterPath = adapterPath if adapterPath?
  try
    embedResult = await S.callLLM embedParams, debugLlm
    embedding = embedResult?.embedding ? null
    embeddingError = "embed returned no .embedding" unless embedding?
  catch err
    embeddingError = String(err?.message ? err)
    console.error "[oracle_ask_sqlite] embed failed: #{embeddingError}"

  genOpts = buildGenerateOpts llmConfig
  genParams =
    op:       'generate'
    modelDir: modelDir
    prompt:   prompt
    raw:      true                             # oracle prompt is already fully rendered
  genParams.adapterPath = adapterPath if adapterPath?
  for own k, v of genOpts
    genParams[k] = v

  genResult = await S.callLLM genParams, debugLlm
  raw = String(genResult?.rawText ? genResult?.text ? '')

  parsed = extractJSON raw
  filtered = filterEmotions parsed
  { raw, parsed, filtered, embedding, embeddingError }

STORY_PLACEHOLDER = '{{{STORY}}}'

renderPrompt = (template, text) ->
  throw new Error "oracle prompt_text must be a string" unless typeof template is 'string'
  unless template.indexOf(STORY_PLACEHOLDER) >= 0
    throw new Error "oracle prompt_text must contain the placeholder #{STORY_PLACEHOLDER} — that's where the story text gets substituted"
  # split-and-join replaces ALL occurrences (matches storacle's behavior).
  template.split(STORY_PLACEHOLDER).join(String(text ? ''))

splitParagraphs = (text) ->
  rawParts = String(text ? '').split /\n\s*\n/
  parts = []
  for rawPart in rawParts
    part = String(rawPart ? '').replace(/\s+/g, ' ').trim()
    continue unless part.length
    parts.push part
  parts

pad3 = (value) ->
  text = String(Number(value) ? 0)
  while text.length < 3
    text = "0#{text}"
  text

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

buildRetryChunks = (text, maxChars = 1024) ->
  paragraphs = splitParagraphs text
  return [] unless paragraphs.length

  chunks = []
  startIndex = 0

  while startIndex < paragraphs.length
    chosenCount = 0
    chosenText = null

    for count in [3, 2]
      selected = paragraphs.slice startIndex, startIndex + count
      continue unless selected.length is count
      chunkText = selected.join "\n\n"
      continue unless chunkText.length <= maxChars
      chosenCount = count
      chosenText = chunkText
      break

    if chosenCount is 0
      chosenCount = 1
      chosenText = paragraphs[startIndex]

    chunks.push
      start_index: startIndex
      paragraph_count: chosenCount
      text: chosenText

    startIndex += chosenCount

  chunks

mergeEmotionLists = (rows) ->
  merged = {}
  return merged unless Array.isArray rows

  for row in rows
    continue unless row? and typeof row is 'object'
    for own key, value of row
      emotionKey = toEmotionKey key, Object.keys(merged).length + 1
      emotionText = cleanFragment value
      continue unless emotionText.length
      continue if Object::hasOwnProperty.call(merged, emotionKey)
      merged[emotionKey] = emotionText

  filterEmotions merged

# ── Exports for probes (writer/test/oracle_probe.coffee) ─────────
# All read-only helpers, no behavior change.
@normalizeRaw                  = normalizeRaw
@REJECT_PATTERNS               = REJECT_PATTERNS
@ALLOWED_EMOTION_KEYWORDS      = ALLOWED_EMOTION_KEYWORDS
@cleanFragment                 = cleanFragment
@normalizeAllowedEmotionKeyword = normalizeAllowedEmotionKeyword
@extractJSON                   = extractJSON
@extractTiers                  = extractTiers
@filterEmotions                = filterEmotions
@renderPrompt                  = renderPrompt
@buildStoryGroups              = buildStoryGroups
@buildRetryChunks              = buildRetryChunks

# Explain why a single (key, value) pair either passes or fails the
# emotion filter. Mirrors the probe's explainRejection — used inline
# by the action so live runs surface WHY the filter dropped anything.
explainKeyVerdict = (key, value) ->
  emotionKey = normalizeAllowedEmotionKeyword(key) ? normalizeAllowedEmotionKeyword(value)
  unless emotionKey?
    return {status: 'rejected', rule: 'not_in_allowed_keywords'}
  emotionText = cleanFragment value
  unless emotionText.length
    return {status: 'rejected', rule: 'empty_after_clean'}
  for p in REJECT_PATTERNS
    if p.re.test(emotionKey) or p.re.test(emotionText)
      return {status: 'rejected', rule: p.name, matched_on: (if p.re.test(emotionKey) then 'key' else 'value')}
  {status: 'accepted', emotion: emotionKey, headline: emotionText}

# Dump raw + parse tiers + precedence + per-key filter verdicts +
# final filtered to STDERR. One block per LLM call. This is what makes
# it possible to see WHY the filter freaks out on a given chunk.
LOG_RAW_CAP = 800
logGroupOutcome = (label, raw, filtered) ->
  console.error ""
  console.error "── #{label} ──────────────────────────────────────────"
  rawSnippet = if raw.length > LOG_RAW_CAP then raw.slice(0, LOG_RAW_CAP) + " …[+#{raw.length - LOG_RAW_CAP} chars]" else raw
  console.error "raw reply (#{raw.length} chars):"
  for line in rawSnippet.split '\n'
    console.error "  | #{line}"
  tiers = extractTiers raw
  hKeys = Object.keys tiers.headlined
  bKeys = Object.keys tiers.bare
  console.error "parse tiers: headlined=#{hKeys.length}  bare=#{bKeys.length}"
  if hKeys.length
    console.error "  headlined:"
    for own k, v of tiers.headlined
      console.error "    - #{k}: '#{String(v).slice(0, 100)}#{if String(v).length > 100 then '…' else ''}'"
  if bKeys.length
    console.error "  bare (dropped if any headlined survive):"
    for own k, v of tiers.bare
      console.error "    - #{k}: '#{String(v).slice(0, 100)}#{if String(v).length > 100 then '…' else ''}'"
  parsed = if hKeys.length > 0 then tiers.headlined else tiers.bare
  precedence = if hKeys.length > 0 then 'headlined' else 'bare'
  console.error "precedence: winner=#{precedence}, kept=#{Object.keys(parsed).length}"
  for own k, v of parsed
    verdict = explainKeyVerdict k, v
    status = verdict.status.toUpperCase()
    rule = if verdict.rule then " (#{verdict.rule})" else ''
    console.error "  #{status}#{rule}: #{k} → '#{String(v).slice(0, 100)}#{if String(v).length > 100 then '…' else ''}'"
  filteredCount = Object.keys(filtered ? {}).length
  console.error "filtered: #{filteredCount} usable"
  for own k, v of (filtered ? {})
    console.error "  ✓ #{k}: #{String(v).slice(0, 100)}#{if String(v).length > 100 then '…' else ''}"

@explainKeyVerdict = explainKeyVerdict
@logGroupOutcome   = logGroupOutcome

@step =
  desc: "Classify sqlite-backed stories with the emotion oracle"

  action: (S) ->
    promptText = S.param 'prompt_text'
    batchSzRaw = S.param 'batch_size'
    batchSz = Number(batchSzRaw)
    throw new Error "[oracle_ask_sqlite] batch_size must be a positive integer" unless Number.isFinite(batchSz) and batchSz > 0 and Math.floor(batchSz) is batchSz
    # Read the `llm:` block (new-door convention). Legacy `mlx:` blocks
    # from unmigrated overrides are still accepted; the buildGenerateOpts
    # mapper converts their kebab-case keys to camelCase and drops
    # session-level keys (max-kv-size) that don't apply here.
    llmConfig = S.param('llm', null) ? S.param('mlx', null)
    throw new Error "[oracle_ask_sqlite] llm/mlx block must be an object when provided" if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))
    quantizedModelMemoKey = S.param 'quantized_model_memo_key', 'quantizedModelDir'
    adapterPath = S.param 'adapter_path', null
    modelDir = S.theLowdown(quantizedModelMemoKey)?.value ? S.param('model_dir') ? S.theLowdown('modelDir')?.value
    throw new Error "[oracle_ask_sqlite] Missing model_dir/quantized model path" unless modelDir?

    pendingStories = S.theLowdown('storiesMissingKag.jsonl')?.value
    throw new Error "[#{S.stepName}] storiesMissingKag.jsonl must be an array" unless Array.isArray pendingStories

    pending = pendingStories.slice 0, batchSz
    rejectRows = await S.peek 'kag_rejects', []
    rejectRows = [] unless Array.isArray rejectRows

    console.log "[oracle_ask_sqlite] pending:", pending.length
    remainingAfterBatch = Math.max(pendingStories.length - pending.length, 0)
    console.log "[oracle_ask_sqlite] stories left after this batch:", remainingAfterBatch
    S.make 'kag_viewed', pending

    newStoryIds = []

    if pending.length is 0
      S.saveThis 'pipeline:shutdown',
        by: S.stepName
        reason: 'all stories have already been passed to the sqlite oracle'
        timestamp: new Date().toISOString()
      S.make 'new_story_ids', newStoryIds
      S.make 'oracle_remaining_count', 0
      S.make 'kag_rejects', rejectRows
      S.done()
      return

    outRejects = rejectRows.slice()

    for story in pending
      storyID = story?.story_id
      title = story?.title ? storyID
      text = story?.text ? ''
      continue unless storyID?

      newStoryIds.push storyID

      storyGroups = buildStoryGroups text
      entries = []
      keywords = []
      storyRetryAttempts = []

      for group in storyGroups
        groupPrompt = renderPrompt promptText, group.text
        attempt1 = await runOracleOnce S, modelDir, groupPrompt, adapterPath, llmConfig
        logGroupOutcome "#{storyID} · group #{group.group_index} (paras #{group.start_paragraph}-#{group.end_paragraph})", attempt1.raw, attempt1.filtered
        finalAttempt = attempt1
        retryAttempts = []

        unless isUsableEmotionList(attempt1.filtered)
          console.error "[oracle_ask_sqlite] retrying #{storyID} group #{group.group_index} after filter rejection"
          retryChunks = buildRetryChunks group.text, 1024
          successfulChunkFilters = []

          for chunk, cIdx in retryChunks
            chunkPrompt = renderPrompt promptText, chunk.text
            attempt2 = await runOracleOnce S, modelDir, chunkPrompt, adapterPath, llmConfig, true
            logGroupOutcome "#{storyID} · group #{group.group_index} · retry chunk #{cIdx+1}/#{retryChunks.length}", attempt2.raw, attempt2.filtered
            usable = isUsableEmotionList(attempt2.filtered)
            retryAttempts.push
              group_index: group.group_index
              group_start_paragraph: group.start_paragraph
              group_end_paragraph: group.end_paragraph
              start_index: chunk.start_index
              paragraph_count: chunk.paragraph_count
              chunk_text: chunk.text
              raw: attempt2.raw
              parsed: attempt2.parsed
              filtered: attempt2.filtered
              usable: usable

            if usable
              console.log "[oracle_ask_sqlite] retry usable for #{storyID} group #{group.group_index}"
              successfulChunkFilters.push attempt2.filtered

          if successfulChunkFilters.length > 0
            mergedFiltered = mergeEmotionLists successfulChunkFilters
            if isUsableEmotionList mergedFiltered
              finalAttempt =
                raw: retryAttempts.map((row) -> row.raw).join "\n\n==========\n\n"
                parsed: successfulChunkFilters
                filtered: mergedFiltered

        for retryAttempt in retryAttempts
          storyRetryAttempts.push retryAttempt

        continue unless isUsableEmotionList finalAttempt.filtered

        # Persist the chunk's embedding (one row per story+chunk) — the
        # first attempt's cache embedding is the canonical one (the cache
        # for the full unmodified chunk; retry attempts use sub-chunks
        # which are noisier voice signal).
        if attempt1.embedding?
          try
            S.saveThis "kagEmbeddingRegister{#{storyID}|#{group.group_index}}.json",
              story_id: storyID
              chunk_index: group.group_index
              dim: attempt1.embedding.length
              source: 'cache_prompt/last_v_meanpool'
              embedding: S.tools.embedding_blob.floatArrayToBlob attempt1.embedding
          catch err
            console.error "[oracle_ask_sqlite] could not persist embedding for #{storyID}/#{group.group_index}: #{err?.message ? err}"
        else if attempt1.embeddingError?
          console.error "[oracle_ask_sqlite] no embedding for #{storyID}/#{group.group_index} (#{attempt1.embeddingError})"

        paragraphLabel = if group.start_paragraph is group.end_paragraph
          pad3 group.start_paragraph
        else
          "#{pad3(group.start_paragraph)}-#{pad3(group.end_paragraph)}"

        for own keyword, headline of finalAttempt.filtered
          entries.push
            chunk_index: group.group_index
            meta:
              doc_id: storyID
              paragraph_index: paragraphLabel
              title: title
              chunk_index: group.group_index
              group_index: group.group_index
            keyword: keyword
            headline: headline
          keywords.push keyword

      unless entries.length > 0
        console.error "[oracle_ask_sqlite] FAILED #{storyID} oracle did not produce a usable filtered emotion list after retry"
        failureReason = 'oracle did not produce a usable filtered emotion list after retry'
        S.saveThis "oracleFailureFor{#{storyID}}.json",
          story_id: storyID
          last_failed_at: new Date().toISOString()
          last_error: failureReason
        outRejects.push
          story_id: storyID
          title: title
          fail_count: (story?.fail_count ? 0) + 1
          group_count: storyGroups.length
          retry_attempts: storyRetryAttempts
          reason: failureReason
        continue

      S.saveThis "kagFor{#{storyID}}.json",
        story_id: storyID
        entries: entries
        keywords: keywords

      S.saveThis "oracleFailureFor{#{storyID}}.json",
        reset: true

      console.log "[oracle_ask_sqlite] tagged #{storyID}"

    S.make 'new_story_ids', newStoryIds
    S.make 'oracle_remaining_count', remainingAfterBatch
    S.make 'kag_rejects', outRejects
    S.done()
    return
