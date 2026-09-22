###
  elementary_sat_ite.coffee  —  DIARY_ITE elementary SAT step
  =====================================================
  Grades ONE diary letter against the elementary SAT rubric:
      1. structure_count    — 5 body paragraphs between greeting/signoff
      2. character_lock     — only allowed-list names appear
      3. freshness_copy     — no ≥ 6-token verbatim runs from past-writing scraps
      4. premise_adherence  — letter mentions ≥ N nouns from the premise
      5. structure_order    — LLM: each paragraph fits its expected role
      6. invariant_preserving — LLM: "must stay true" facts survive

  Params:
    side:            'adapted' | 'base'    which diary text to grade
    with_llm:        true|false            run the two LLM checks (default true)
    min_premise:     3                     min noun matches for premise_adherence
    min_freshness_run: 6                    min tokens for a verbatim-copy hit

  Reads:
    diary_<side>_text     the generated letter
    diary_prompt_text     the prompt fed to the generator (for allowed-names,
                          invariants, past-writing scraps)
    story_spine_json      optional; supplies protected_facts if the prompt's
                          invariants block is absent

  Writes:
    sat_verdict_<side>   { pass, checks: [...], letter_meta, prompt_meta }

  See memory: elementary-sat, helper-reason-mining-findings.
###

# ---------------------------------------------------------------- pure parsers

parseLetter = (text) ->
  raw = String(text ? '').replace(/\r\n/g, '\n').trim()
  paragraphs = raw.split(/\n\s*\n+/).map (p) -> p.trim()
  paragraphs = paragraphs.filter (p) -> p.length > 0
  greeting = null
  if paragraphs.length > 0 and /^\s*(hi|hey|dear|greetings|hello)\b/i.test(paragraphs[0]) and paragraphs[0].split(/\n/).length <= 4
    greeting = paragraphs.shift()
  signoff = []
  isSignoffPara = (p) ->
    return true if /^\s*(yours|cheers|until\s+next|till\s+next|take\s+care|so\s+long|— |-- |your\s+friend|your\s+pal|sincerely|regards|xoxo|farewell|adieu)/i.test(p)
    return true if /\bthere you have it\b/i.test(p) and p.length < 400
    return true if p.length < 120 and /\bjim\b/i.test(p)
    false
  while paragraphs.length > 0 and isSignoffPara(paragraphs[paragraphs.length - 1])
    signoff.unshift paragraphs.pop()
  {
    greeting: greeting
    signoff:  if signoff.length then signoff.join('\n\n') else null
    segments: paragraphs
    paragraph_count: paragraphs.length
  }

extractSection = (promptText, startMarker, endMarkers) ->
  s = promptText.indexOf startMarker
  return null if s < 0
  start = s + startMarker.length
  end = promptText.length
  for m in endMarkers
    i = promptText.indexOf(m, start)
    end = i if i > 0 and i < end
  promptText.slice(start, end).trim()

parsePrompt = (text) ->
  raw = String(text ? '')
  allowedNamesBlock = extractSection raw,
    'People in the story (the only named characters you may use):',
    ['Things that must stay true', 'What happened:', 'Emotional cues', 'Your task:']
  invariantsBlock = extractSection raw,
    'Things that must stay true (from the premise):',
    ['What happened:', 'Emotional cues', 'Your task:']
  pastWritingBlock = extractSection raw,
    "Some scraps of your own past writing",
    ['People in the story', 'Things that must stay true']
  allowedNames = []
  if allowedNamesBlock?
    for line in allowedNamesBlock.split(/\n/)
      m = line.match /^\s*-\s+(.+?)\s*(?:\(id:\s*([^)]+)\))?\s*(?:\(.*\))?\s*$/
      continue unless m
      display = String(m[1]).trim()
      slug = if m[2] then String(m[2]).trim() else null
      allowedNames.push { display, slug }
  invariants = []
  if invariantsBlock?
    for line in invariantsBlock.split(/\n/)
      m = line.match /^\s*-\s+(.+?)\s*$/
      continue unless m
      invariants.push String(m[1]).trim()
  pastScraps = []
  if pastWritingBlock?
    quoteRe = new RegExp "[“\"]([\\s\\S]+?)[”\"]", 'g'
    for m from pastWritingBlock.matchAll quoteRe
      s = String(m[1]).trim()
      pastScraps.push s if s.length >= 40
  { allowedNames, invariants, pastScraps }

# ---------------------------------------------------------------- helpers

tokenize = (s) ->
  String(s ? '').toLowerCase().match(/[a-z0-9']+/g) ? []

STOP_NOUNS = new Set 'about above after again against because before being below between during either every from having himself into itself might more most much must never other others should since some such than that their them then there these they this those through under until upon very were what when where which while would your'.split(/\s+/)

extractPremiseNouns = (text) ->
  words = String(text ? '').match(/\b[A-Za-z][a-z]{3,}\b/g) ? []
  seen = new Set()
  keep = []
  for w in words
    lw = w.toLowerCase()
    continue if STOP_NOUNS.has(lw)
    continue if lw.length < 4
    unless seen.has(lw)
      seen.add lw
      keep.push lw
  keep

BUILTIN_STOP = new Set 'Jim Friend I A The It He She They We You Yes No Maybe But And Or So Also Then Now Today Tomorrow Yesterday Sunday Monday Tuesday Wednesday Thursday Friday Saturday January February March April May June July August September October November December God Lord Christ Sir Madam Mister Missus Mrs'.split(/\s+/)
COMMON_ADVERBS = new Set 'Finally Anyway Meanwhile Later Sometimes Sometime Suddenly Eventually Instead Also Yet Still However Perhaps Maybe Certainly Surely Really Only Even Just Well Actually Basically Frankly Honestly Unfortunately Fortunately Interestingly Curiously Strangely Naturally Obviously Clearly Somehow Anyhow Somewhere Somewhat Someone Something Somebody Everyone Everything Everybody Nobody Nothing Anywhere Anyone Anything Anybody Nowhere Whenever Whatever Whoever Wherever'.split(/\s+/)
COMMON_PLACES = new Set 'John Johns Portland Oregon Persia Russia America Willamette Lombard River Rivers Bridge Street Avenue Road Boulevard City Park County'.split(/\s+/).map (s) -> s.toLowerCase()

# ---------------------------------------------------------------- FREE CHECKS

checkStructureCount = (letter) ->
  n = letter.paragraph_count
  { name: 'structure_count', pass: (n is 5), detail: "paragraph_count=#{n} (expected 5)" }

## Blank out quoted spans (double/single, straight/curly) so words
## inside quotes don't trigger character-lock. Preserves length so
## sentence-start indices computed on the padded body still line up.
maskQuotedSpans = (s) ->
  # Order matters: double before single so "he said 'no'" doesn't
  # mask "no". Curly variants first so their partner isn't consumed
  # by the straight-quote pass. Non-greedy, single-line only (a
  # missing close quote on a line shouldn't devour the paragraph).
  # Also masks markdown italic/bold spans (`*…*` / `**…**`) — Qwen
  # loves italicizing inscriptions and quoted lines, which slipped
  # past the quote-only pass.
  patterns = [
    /“[^”\n]*”/g
    /"[^"\n]*"/g
    /‘[^’\n]*’/g
    /'[^'\n]{2,}?'/g          # skip apostrophe-in-word (≥2 chars)
    /\*\*[^\*\n]{2,}?\*\*/g    # bold
    /\*[^\*\n]{2,}?\*/g        # italic
  ]
  out = s
  for re in patterns
    out = out.replace re, (m) -> ' '.repeat(m.length)
  out

checkCharacterLock = (letter, promptData) ->
  allowedSet = new Set()
  for a in promptData.allowedNames
    allowedSet.add String(a.display).toLowerCase()
    allowedSet.add String(a.slug).toLowerCase() if a.slug
  allowedSet.add 'jim'; allowedSet.add 'friend'
  body = letter.segments.join('\n\n')
  body = maskQuotedSpans(body)
  bodyPad = ' ' + body
  sentenceStartIdx = new Set()
  sentenceStartIdx.add 0
  # Include markdown emphasis markers (`*`, `_`) and closing quotes in
  # the sentence-terminator class so ". *End of italic.* Her" or
  # `.\"Her` correctly marks "Her" as sentence-start.
  for m from bodyPad.matchAll /[.!?]["'”)*_]*\s+/g
    sentenceStartIdx.add(m.index + m[0].length)
  cands = []
  for m from bodyPad.matchAll /\b([A-Z][a-zA-Z']{2,})\b/g
    word = m[1]
    continue if /'(s|m|d|t|ll|ve|re)$/i.test word
    continue if sentenceStartIdx.has m.index
    cands.push word
  seen = new Set()
  violations = []
  for c in cands
    lc = c.toLowerCase()
    continue if seen.has(lc)
    seen.add lc
    continue if allowedSet.has(lc)
    continue if BUILTIN_STOP.has(c)
    continue if COMMON_ADVERBS.has(c)
    continue if COMMON_PLACES.has(lc)
    violations.push c
  {
    name:   'character_lock'
    pass:   violations.length is 0
    detail: if violations.length then "unlisted names: #{violations.join(', ')}" else 'no unlisted named entities'
    violations: violations
  }

checkFreshnessCopy = (letter, promptData, minRun = 6) ->
  bodyTokens = tokenize letter.segments.join('\n\n')
  return { name: 'freshness_copy', pass: true, detail: 'no past-writing scraps to compare against', hits: [] } if promptData.pastScraps.length is 0
  bodyGrams = new Map()
  for i in [0..bodyTokens.length - minRun]
    key = bodyTokens[i...i + minRun].join(' ')
    bodyGrams.set(key, i) unless bodyGrams.has(key)
  hits = []
  for scrap, si in promptData.pastScraps
    scrapTokens = tokenize scrap
    continue if scrapTokens.length < minRun
    for j in [0..scrapTokens.length - minRun]
      key = scrapTokens[j...j + minRun].join(' ')
      if bodyGrams.has(key)
        run = minRun
        bi = bodyGrams.get(key)
        while bi + run < bodyTokens.length and j + run < scrapTokens.length and bodyTokens[bi + run] is scrapTokens[j + run]
          run += 1
        hits.push { run, phrase: scrapTokens[j...j + run].join(' '), scrap_idx: si }
        break
  {
    name:   'freshness_copy'
    pass:   hits.length is 0
    detail: if hits.length then "verbatim copy: #{hits.map((h) -> "'#{h.phrase}' (#{h.run} toks)").join('; ')}" else "no verbatim runs ≥ #{minRun} tokens from past-writing scraps"
    hits: hits
  }

checkPremiseAdherence = (letter, promptData, premiseText, minMatch = 3) ->
  source = if premiseText and premiseText.trim().length > 0 then premiseText else promptData.invariants.join(' ')
  premiseNouns = extractPremiseNouns source
  return { name: 'premise_adherence', pass: false, detail: 'no premise source text', matched: [] } unless premiseNouns.length
  bodyTokens = new Set tokenize(letter.segments.join('\n\n'))
  matched = premiseNouns.filter (n) -> bodyTokens.has(n)
  {
    name:   'premise_adherence'
    pass:   matched.length >= minMatch
    detail: "matched #{matched.length}/#{premiseNouns.length} premise nouns (need ≥ #{minMatch}): #{matched.join(', ') or '(none)'}"
    matched: matched
    premise_nouns_total: premiseNouns.length
  }

# ---------------------------------------------------------------- LLM CHECKS

EXPECTED_ROLES = ['scene', 'arrival', 'disturbance', 'reflection', 'realization']

# Extract the first JSON object from a raw LLM response, tolerating leading
# <think> content and trailing im_end noise.
stripJson = (rawText) ->
  s = String(rawText ? '')
  # last </think> then tail
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  s = m[1] if m
  s = s.replace(/<\|im_end\|>[\s\S]*$/, '')
  brace = s.indexOf '{'
  return null if brace < 0
  # naive: find matching close by scanning depth
  depth = 0
  for i in [brace..s.length - 1]
    switch s[i]
      when '{' then depth += 1
      when '}'
        depth -= 1
        if depth is 0
          return s.slice brace, i + 1
  null

# Wrap L.callLLM for a "judge one thing" call. Returns a parsed object or null.
# Thinking-budget rescue — mirrors helper_llm.coffee's rescueInsideThink.
# Run once; if </think> never appeared, take what we got, append a
# "time's up" clause + </think>, and continue generation from there.
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

callJudge = (L, task, opts = {}) ->
  modelDir  = L.param 'grader_model_dir', L.param('quantized_model_dir', null)
  throw new Error "[#{L.stepName}] grader_model_dir (or quantized_model_dir) required for LLM checks" unless modelDir?
  # Wrap the task in ChatML for the raw-mode generator.
  prompt = "<|im_start|>user\n#{task}<|im_end|>\n<|im_start|>assistant\n"
  llmArgs =
    op:          'generate'
    modelDir:    modelDir
    prompt:      prompt
    maxTokens:   opts.maxTokens   ? 1500
    temperature: opts.temperature ? 0.15
    topP:        opts.topP        ? 0.8
    raw:         true
  rawOutput = await callWithThinkRescue L, llmArgs
  jsonText = stripJson rawOutput
  return { ok: false, raw: rawOutput, error: 'no JSON found' } unless jsonText?
  try
    parsed = JSON.parse jsonText
    return Object.assign({ ok: true }, parsed)
  catch err
    return { ok: false, raw: rawOutput, error: "parse: #{err.message}" }

checkStructureOrder = (L, letter) ->
  if letter.paragraph_count isnt 5
    return { name: 'structure_order', pass: false, detail: "cannot grade — paragraph_count=#{letter.paragraph_count} ≠ 5" }
  per = []
  for para, i in letter.segments
    expected = EXPECTED_ROLES[i]
    task = """
      You are grading a paragraph from a diary letter (Jim → Friend). The
      letter has five paragraphs in fixed order:
        1. scene   2. arrival   3. disturbance   4. reflection   5. realization

      Reply with exactly one JSON object on one line — no prose, no
      markdown, no code fences.

      Reply shape (all three keys required):
        {"role":"<scene|arrival|disturbance|reflection|realization>",
         "fit":"<good|weak|wrong>",
         "reason":"<one short sentence>"}

      Expected role for this paragraph's position: #{expected}

      Paragraph:
      #{para}

      Output:
    """
    resp = await callJudge L, task, { maxTokens: 1500 }
    per.push {
      position: i, expected: expected
      got:     resp?.role   ? '?'
      fit:     resp?.fit    ? '?'
      reason:  resp?.reason ? '(no reason)'
      ok:      resp?.ok is true
    }
  wrongs = (p for p in per when p.fit is 'wrong')
  weaks  = (p for p in per when p.fit is 'weak')
  {
    name:   'structure_order'
    pass:   wrongs.length is 0 and weaks.length < 2
    detail: "wrong=#{wrongs.length} weak=#{weaks.length} good=#{per.length - wrongs.length - weaks.length} / 5"
    per_paragraph: per
  }

checkInvariantPreserving = (L, letter, promptData) ->
  return { name: 'invariant_preserving', pass: true, detail: 'no invariants declared' } if promptData.invariants.length is 0
  body = letter.segments.join('\n\n')
  invList = promptData.invariants.map((s, i) -> "  #{i + 1}. #{String(s).trim()}").join('\n')
  task = """
    You are grading a diary letter's fidelity to a list of invariants —
    facts from the premise that must stay true. For each invariant decide:
      preserved   — the letter honors it (may paraphrase; the fact holds).
      absent      — the letter never touches it; the fact is neither
                    present nor contradicted. Prefer this over
                    "contradicted" when the letter is simply silent.
      contradicted — the letter says the opposite or a mutually
                    exclusive version. Do NOT flag "contradicted" just
                    because the letter is off-topic.
    Overall: preserved (all preserved), partial (at least one preserved,
    no contradictions), broken (any contradicted OR none preserved).

    Reply with exactly one JSON object on one line — no prose, no code fences.
    Shape:
      {"overall":"<preserved|partial|broken>",
       "per_invariant":[
         {"invariant":"<verbatim>","status":"<preserved|absent|contradicted>","note":"<one short sentence>"}
       ]}

    Invariants:
    #{invList}

    Letter:
    #{body}

    Output:
  """
  resp = await callJudge L, task, { maxTokens: 2500 }
  return { name: 'invariant_preserving', pass: false, detail: "grader failed: #{resp?.error ? '(unknown)'}" } unless resp?.ok
  overall = String(resp.overall ? 'broken').toLowerCase()
  {
    name:   'invariant_preserving'
    pass:   overall is 'preserved'
    detail: "overall=#{overall}"
    overall: overall
    per_invariant: resp.per_invariant ? []
  }

# ---------------------------------------------------------------- STEP

@step =
  desc: "Elementary SAT — pass/fail grade one diary letter (six checks)"

  action: (L) ->
    side = String(L.param('side', 'adapted')).toLowerCase()
    # KAG/chunks ablation grading — the diary artifacts are per-config
    # (baseline|kag|chunks|both), so the grader has to know which
    # config it's reading. Default 'baseline' preserves the pre-ablation
    # single-config behavior.
    configLabel = String(L.param('config_label', 'baseline')).toLowerCase()
    withLlm = L.param('with_llm', true) isnt false
    minPremise = Number(L.param('min_premise', 3))
    minFreshRun = Number(L.param('min_freshness_run', 6))

    diaryKey   = "diary_#{configLabel}_#{side}_text"
    promptKey  = "diary_#{configLabel}_prompt_text"
    verdictKey = "sat_verdict_#{configLabel}_#{side}"

    letterText = await L.need diaryKey
    promptText = await L.need promptKey

    # Premise source, best-effort: story_spine_json.story.protected_facts
    # joined as text, else empty (falls back to invariants text).
    premiseText = ''
    try
      spine = await L.need 'story_spine_json'
      spine = JSON.parse(spine) if typeof spine is 'string'
      pf = spine?.story?.protected_facts
      if Array.isArray(pf) and pf.length
        premiseText = pf.join(' ')
    catch _err
      premiseText = ''

    letter = parseLetter letterText
    promptData = parsePrompt promptText

    checks = [
      checkStructureCount     letter
      checkCharacterLock      letter, promptData
      checkFreshnessCopy      letter, promptData, minFreshRun
      checkPremiseAdherence   letter, promptData, premiseText, minPremise
    ]

    if withLlm
      checks.push await checkStructureOrder      L, letter
      checks.push await checkInvariantPreserving L, letter, promptData

    hardChecks = checks.filter (c) -> c.skipped isnt true and c.pass? and typeof c.pass is 'boolean'
    overall = hardChecks.length > 0 and hardChecks.every (c) -> c.pass is true

    verdict =
      side:         side
      config_label: configLabel
      pass:         overall
      hard_pass_count: (c for c in hardChecks when c.pass is true).length
      hard_total:      hardChecks.length
      letter_meta:
        paragraph_count: letter.paragraph_count
        has_greeting:    letter.greeting?
        has_signoff:     letter.signoff?
      prompt_meta:
        allowed_names: promptData.allowedNames
        invariants:    promptData.invariants
        past_scraps:   promptData.pastScraps.length
      checks: checks

    console.log "[elementary_sat_ite] config=#{configLabel} side=#{side} overall=#{if overall then 'PASS' else 'FAIL'} (#{verdict.hard_pass_count}/#{verdict.hard_total})"
    for c in checks
      status = if c.pass is true then 'PASS' else if c.pass is false then 'FAIL' else 'SKIP'
      console.log "  [#{status}] #{c.name}: #{c.detail}"

    L.make verdictKey, verdict
    L.done()
    return
