###
  sat_diary_ite.coffee  —  Fixed-spine diary ablation (generator)
  ================================================================
  Second-tier SAT: "given a locked story spine, can the model produce
  a diary letter that survives elementary_sat_ite's six checks?"

  This step ONLY generates. Chain elementary_sat_ite after it in the
  recipe to grade the letter and produce the pass/fail bucket. That
  keeps the grader single-sourced.

  Reads:
    sat_fixed_spine_json    canonical, human-authored spine:
                             { allowed_names: [{display,slug?}],
                               invariants:    ["..."],
                               past_scraps:   ["..."],
                               premise:       "one-paragraph what-happened",
                               emotional_cues:"optional",
                               task:          "optional; default 5-para diary" }

  Writes (matches the keys elementary_sat_ite already consumes):
    diary_prompt_text        the prompt built from the spine
    diary_<side>_text        the generated diary letter, where side comes
                             from the `side` param (default 'adapted').

  Knobs:
    side               'adapted' | 'base' (default 'adapted'). Chooses which
                       artifact key the generation lands under so an ablation
                       run can produce both by scheduling two steps with
                       different `side` overrides.
    model_dir          generator model (fallback: quantized_model_dir).
    adapter_dir        optional LoRA adapter (typically set for side='adapted',
                       unset for side='base').
    temperature        default 0.75 (creative diary voice).
    top_p              default 0.9
    max_tokens         default 900
    system_prompt      optional override; default is the standard
                       diary-generator system message.

  See writer/GPT/sat/elementary_sat.md for the check contract.
###

# ---------------------------------------------------------------- helpers

stripText = (rawText) ->
  s = String(rawText ? '')
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  s = m[1] if m
  s.replace(/<\|im_end\|>[\s\S]*$/, '').trim()

# Thinking-budget rescue. Run L.callLLM once; if the model never
# emitted </think>, take what it wrote so far, append a "time's up"
# clause + </think>, and continue generation from there. Mirrors the
# rescueInsideThink pattern in ~/pipeline/mlx/helper_llm.coffee — the
# thinking span is closed by us, forcing the model to answer with
# whatever partial reasoning it accrued.
callWithThinkRescue = (L, llmArgs) ->
  resp = await L.callLLM llmArgs
  raw = String(resp?.rawText ? resp?.text ? '')
  return raw if raw.indexOf('</think>') >= 0
  rescueClause = "\n\nOK, time is up. Answering now.\n</think>\n\n"
  rescueArgs = Object.assign {}, llmArgs,
    prompt:    llmArgs.prompt + raw + rescueClause
    maxTokens: Math.max(200, Math.floor((llmArgs.maxTokens ? 512) / 2))
  resp2 = await L.callLLM rescueArgs
  raw2 = String(resp2?.rawText ? resp2?.text ? '')
  raw + rescueClause + raw2

# SEGMENT_ORDER — matches elementary_sat_ite's EXPECTED_ROLES.
# Used to walk emotional_arc when include_kag/include_chunks is set.
SEGMENT_ORDER = ['scene', 'arrival', 'disturbance', 'reflection', 'realization']

# Fetch corpus rows matching an emotion label via the meta layer's
# kagByKeyword{X}.jsonl request. Returns an array (may be empty).
# The request was added to meta/sqlite.coffee 2026-06-26; see
# `pipeline/GPT/tools/*` and collect_diary_kag_ite.coffee for the
# established consumer pattern.
fetchByEmotion = (L, emotion, limit) ->
  key = "kagByKeyword{#{emotion}}.jsonl"
  try
    rows = L.theLowdown(key)?.value ? []
  catch
    rows = []
  # theLowdown may return either a parsed array or a raw JSONL string
  # depending on meta device state. Normalize.
  if typeof rows is 'string'
    parsed = []
    for line in rows.split(/\n/)
      trimmed = line.trim()
      continue unless trimmed.length
      try
        parsed.push JSON.parse(trimmed)
      catch _err
        null
    rows = parsed
  rows = [] unless Array.isArray(rows)
  rows.slice(0, limit)

# Build a per-segment injection block for KAG examples or chunks.
# `mode` controls the framing text so the model reads the same rows
# differently in KAG-mode ("voice examples") vs chunks-mode
# ("story passages for grounding").
buildPerSegmentBlock = (L, spine, mode) ->
  arc = spine.emotional_arc ? {}
  emap = spine.kag_emotion_map ? {}
  perSeg = if mode is 'kag'
    Number(spine.kag_examples_per_segment ? 3)
  else
    Number(spine.chunks_per_segment ? 2)
  header = if mode is 'kag'
    "For each segment, voice-hint examples from the corpus (do not copy verbatim):"
  else
    "For each segment, story passages that match its emotional mood (background grounding, do not copy verbatim):"
  segLines = []
  for seg in SEGMENT_ORDER
    emotion = arc[seg]
    continue unless emotion?
    labels = emap[emotion] ? [emotion]
    rowsForSeg = []
    for label in labels
      break if rowsForSeg.length >= perSeg
      more = fetchByEmotion L, label, perSeg - rowsForSeg.length
      rowsForSeg = rowsForSeg.concat(more)
    segLines.push "  #{seg} (#{emotion}):"
    if rowsForSeg.length is 0
      segLines.push "    (no corpus rows matched labels #{labels.join('/')})"
    else
      for row in rowsForSeg
        # Row shape from kagByKeyword: try common fields, fall back
        # to the whole row stringified. Keep each entry short.
        text = String(row?.chunk_text ? row?.text ? row?.summary ? row?.explanation ? JSON.stringify(row)).replace(/\s+/g, ' ').trim()
        text = text.slice(0, 240) + (if text.length > 240 then '…' else '')
        segLines.push "    - #{text}"
  return null if segLines.length is 0
  "#{header}\n" + segLines.join('\n')

# Build the diary prompt in the shape elementary_sat_ite's parsePrompt
# already understands (the "People in the story", "Things that must
# stay true", "Some scraps of your own past writing", "What happened",
# "Emotional cues", "Your task" headings match exactly for the
# grader's parsePrompt to extract allowed-names/invariants/scraps).
#
# KAG and chunks blocks (when present) are added AFTER the past_scraps
# block and BEFORE "What happened" so the grader's parser still
# terminates the scraps section at the right place — the grader
# stops scraps at "People in the story" / "Things that must stay
# true" / "What happened" (see elementary_sat_ite.coffee parsePrompt).
buildDiaryPrompt = (spine, task, cues, kagBlock, chunksBlock) ->
  names = spine.allowed_names ? []
  invs  = spine.invariants ? []
  scraps = spine.past_scraps ? []
  premise = String(spine.premise ? '')

  nameLines = names.map (a) ->
    if a?.slug then "- #{a.display} (id: #{a.slug})" else "- #{a?.display ? a}"
  invLines = invs.map (s) -> "- #{s}"
  scrapLines = scraps.map (s) -> "  “#{s}”"

  # Assemble the optional context blocks after past_scraps. If both
  # KAG and chunks are supplied they stack in that order.
  contextBlocks = []
  contextBlocks.push kagBlock if kagBlock
  contextBlocks.push chunksBlock if chunksBlock
  contextSection = if contextBlocks.length then '\n\n' + contextBlocks.join('\n\n') + '\n' else ''

  """
    You are Jim writing a private letter to a close friend. Write it as five
    paragraphs in fixed order: scene, arrival, disturbance, reflection,
    realization. No headings; each paragraph is prose. Sign off as Jim.

    People in the story (the only named characters you may use):
    #{nameLines.join('\n')}

    Things that must stay true (from the premise):
    #{invLines.join('\n')}

    Some scraps of your own past writing (voice hints, do not copy verbatim):
    #{scrapLines.join('\n')}#{contextSection}

    What happened:
    #{premise}

    Emotional cues:
    #{cues}

    Your task:
    #{task}
  """

# ---------------------------------------------------------------- step

@step =
  desc: "Fixed-spine diary generator — both sides (adapted + base) in ONE step"

  # Why one step, not two: @frost-beta/mlx native session state
  # doesn't survive across pipeline_runner step boundaries. Two
  # consecutive session_api.generate calls in ONE step work (that's
  # what oracle_ask_sqlite does per batch); the same two calls
  # split across two steps crash the second one inside mx.core.tidy
  # ("Error converting 'this' to mx.array"). Keeping both sides
  # here dodges that entirely. Adapted runs first so the base
  # baseline is always compared against a known-good letter.

  action: (L) ->
    spineRaw = await L.need 'sat_fixed_spine_json'
    spine = if typeof spineRaw is 'string' then JSON.parse(spineRaw) else spineRaw

    modelDir = L.param 'model_dir', L.param('quantized_model_dir', null)
    throw new Error "[#{L.stepName}] model_dir (or quantized_model_dir) required" unless modelDir?
    adapter  = L.param 'adapter_dir', null
    temp     = Number L.param('temperature', 0.75)
    topP     = Number L.param('top_p', 0.9)
    maxTok   = Number L.param('max_tokens', 3000)

    # KAG/chunks ablation params — see writer/GPT/sat/emotional_arc_spine.md.
    # config_label names the ablation cell: 'baseline' | 'kag' |
    # 'chunks' | 'both'. It determines the artifact key suffix so
    # each aliased step-instance writes into its own slot.
    includeKag    = L.param('include_kag', false) is true
    includeChunks = L.param('include_chunks', false) is true
    configLabel = String(L.param('config_label', ''))
    if configLabel.length is 0
      configLabel =
        if includeKag and includeChunks then 'both'
        else if includeKag then 'kag'
        else if includeChunks then 'chunks'
        else 'baseline'

    defaultTask = "Write the letter. Five paragraphs. No lists, no headings, no summary at the end. Speak as Jim."
    task = String(spine?.task ? L.param('task', defaultTask))
    cues = String(spine?.emotional_cues ? L.param('emotional_cues', 'confessional, wry, tired but honest'))

    # Build the optional per-segment context blocks BEFORE the prompt
    # so they land in the right place. Empty blocks (no matching
    # corpus rows) still produce a small stub so the model sees the
    # emotional_arc labels even if the corpus is thin.
    kagBlock    = if includeKag    then buildPerSegmentBlock(L, spine, 'kag')    else null
    chunksBlock = if includeChunks then buildPerSegmentBlock(L, spine, 'chunks') else null

    promptText = buildDiaryPrompt spine, task, cues, kagBlock, chunksBlock

    sysPrompt = L.param 'system_prompt',
      "You are Jim, a middle-aged man writing a diary letter to a friend. Follow the structure exactly."

    fullPrompt = "<|im_start|>system\n#{sysPrompt}<|im_end|>\n<|im_start|>user\n#{promptText}<|im_end|>\n<|im_start|>assistant\n"

    genOne = (adapterDir) ->
      llmArgs =
        op:          'generate'
        modelDir:    modelDir
        prompt:      fullPrompt
        maxTokens:   maxTok
        temperature: temp
        topP:        topP
        raw:         true
      llmArgs.adapterPath = adapterDir if adapterDir?
      raw = await callWithThinkRescue L, llmArgs
      stripText raw

    # Prompt-text artifact is per-config so the grader (elementary_sat_ite)
    # reads back the exact prompt used by ITS side. If two configs
    # published to a shared 'diary_prompt_text' the last writer would
    # win and the grader would parse against the wrong prompt.
    promptKey  = "diary_#{configLabel}_prompt_text"
    adaptedKey = "diary_#{configLabel}_adapted_text"
    baseKey    = "diary_#{configLabel}_base_text"

    L.make promptKey, promptText

    adaptedText = await genOne(adapter)
    console.log "[sat_diary_ite] config=#{configLabel} side=adapted adapter=#{adapter ? '(none)'} temp=#{temp} kag=#{includeKag} chunks=#{includeChunks} chars=#{adaptedText.length}"
    L.make adaptedKey, adaptedText

    baseText = await genOne(null)
    console.log "[sat_diary_ite] config=#{configLabel} side=base    adapter=(none) temp=#{temp} kag=#{includeKag} chunks=#{includeChunks} chars=#{baseText.length}"
    L.make baseKey, baseText

    L.done()
    return
