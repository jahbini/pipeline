###
  sat_story_ite.coffee  —  Fixed-spine story ablation (generator + grader)
  ========================================================================
  Third-tier SAT: "given a locked story spine, can the model produce a
  short story that respects the invariants, uses only allowed characters,
  and reads as a coherent narrative?"

  Self-contained: generates the story AND grades it, since the story
  grader is not shared with any other recipe (unlike the diary grader,
  which is elementary_sat_ite).

  Reads:
    sat_fixed_spine_json    same shape as sat_diary_ite consumes.

  Writes:
    sat_story_text          the generated story
    sat_story_prompt_text   the prompt used
    sat_story_verdict       {
      pass, bucket, checks: {
        character_lock:    {pass, offenders},
        invariant_check:   {pass, per_invariant:[{status,note}]},
        coherence_check:   {pass, score, note},
        length_check:      {pass, word_count, min, max}
      }, knobs
    }

  Knobs:
    model_dir           generator (fallback: quantized_model_dir)
    adapter_dir         optional LoRA
    temperature         default 0.8
    top_p               default 0.9
    max_tokens          default 1400
    min_words           default 300
    max_words           default 1200
    grader_model_dir    LLM judge (fallback: model_dir)
    grader_temperature  default 0.1

  Bucket:
    can_story    — character_lock + invariant_check + length_check all
                   pass AND coherence_check.score ≥ 3 (of 5).
    cannot_story — otherwise.
###

# ---------------------------------------------------------------- helpers

stripJson = (rawText) ->
  s = String(rawText ? '')
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  s = m[1] if m
  s = s.replace(/<\|im_end\|>[\s\S]*$/, '')
  brace = s.indexOf '{'
  return null if brace < 0
  depth = 0
  for i in [brace..s.length - 1]
    switch s[i]
      when '{' then depth += 1
      when '}'
        depth -= 1
        return s.slice brace, i + 1 if depth is 0
  null

stripText = (rawText) ->
  s = String(rawText ? '')
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  s = m[1] if m
  s.replace(/<\|im_end\|>[\s\S]*$/, '').trim()

# Thinking-budget rescue — see sat_diary_ite.coffee for the pattern.
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

tokenize = (s) -> String(s ? '').toLowerCase().match(/[a-z0-9']+/g) ? []

BUILTIN_STOP = new Set 'A The It He She They We You I My Mine Our Ours Their Theirs Her Hers His His Him Them Us Yes No Maybe But And Or So Also Then Now Today Tomorrow Yesterday Sunday Monday Tuesday Wednesday Thursday Friday Saturday January February March April May June July August September October November December God Lord Christ Sir Madam Mister Missus Mrs'.split(/\s+/)
COMMON_ADVERBS = new Set 'Finally Anyway Meanwhile Later Sometimes Sometime Suddenly Eventually Instead Also Yet Still However Perhaps Maybe Certainly Surely Really Only Even Just Well Actually Basically Frankly Honestly Unfortunately Fortunately Interestingly Curiously Strangely Naturally Obviously Clearly Somehow Anyhow Somewhere Somewhat Someone Something Somebody Everyone Everything Everybody Nobody Nothing Anywhere Anyone Anything Anybody Nowhere Whenever Whatever Whoever Wherever'.split(/\s+/)
# Geographic + generic-place tokens the check should ignore. Includes
# the trailing halves of compound place names ("Willamette River",
# "Broadway Bridge") so the second word isn't flagged as an unlisted
# proper noun when the first is a known place.
COMMON_PLACES = new Set 'Portland Oregon Willamette Lombard Broadway River Rivers Bridge Street Avenue Road Boulevard City Park County District'.split(/\s+/).map (s) -> s.toLowerCase()

# ---------------------------------------------------------------- prompt build

buildStoryPrompt = (spine, task) ->
  names   = spine.allowed_names ? []
  invs    = spine.invariants ? []
  premise = String(spine.premise ? '')
  nameLines = names.map (a) ->
    if a?.slug then "- #{a.display} (id: #{a.slug})" else "- #{a?.display ? a}"
  invLines = invs.map (s) -> "- #{s}"
  """
    You are writing a short story. Third person, past tense. Coherent
    beginning, middle, and end. No lists, no headings, no author's note.

    Characters (use only these named people; unnamed background figures OK):
    #{nameLines.join('\n')}

    Things that must stay true:
    #{invLines.join('\n')}

    Premise:
    #{premise}

    Your task:
    #{task}
  """

# ---------------------------------------------------------------- checks

## Blank out quoted spans so words inside quotes don't trigger
## character-lock. Preserves length so sentence-start positions
## computed downstream still align.
maskQuotedSpans = (s) ->
  # Includes markdown italic/bold since Qwen italicizes engravings.
  patterns = [
    /“[^”\n]*”/g
    /"[^"\n]*"/g
    /‘[^’\n]*’/g
    /'[^'\n]{2,}?'/g
    /\*\*[^\*\n]{2,}?\*\*/g
    /\*[^\*\n]{2,}?\*/g
  ]
  out = s
  for re in patterns
    out = out.replace re, (m) -> ' '.repeat(m.length)
  out

checkCharacterLock = (storyText, spine) ->
  allowed = new Set()
  for a in (spine.allowed_names ? [])
    allowed.add String(a?.display ? a).toLowerCase()
    allowed.add String(a.slug).toLowerCase() if a?.slug
  padded = ' ' + maskQuotedSpans(storyText)
  sentStarts = new Set([0])
  # Broadened terminator class: markdown emphasis markers + closing
  # quote/parens count as sentence-endings, so "Her" after `.*` or
  # ".\"" doesn't get mistaken for a mid-sentence proper noun.
  for m from padded.matchAll /[.!?]["'”)*_]*\s+/g
    sentStarts.add(m.index + m[0].length)
  offenders = []
  seen = new Set()
  for m from padded.matchAll /\b([A-Z][a-zA-Z']{2,})\b/g
    word = m[1]
    continue if /'(s|m|d|t|ll|ve|re)$/i.test word
    continue if sentStarts.has m.index
    continue if BUILTIN_STOP.has word
    continue if COMMON_ADVERBS.has word
    lc = word.toLowerCase()
    continue if allowed.has(lc)
    continue if COMMON_PLACES.has(lc)
    continue if seen.has(lc)
    seen.add lc
    offenders.push word
  { name: 'character_lock', pass: offenders.length is 0, offenders }

checkLength = (storyText, minW, maxW) ->
  n = tokenize(storyText).length
  { name: 'length_check', pass: (minW <= n <= maxW), word_count: n, min: minW, max: maxW }

# LLM judge — invariant preservation across the whole story
checkInvariants = (L, storyText, spine, opts) ->
  invs = spine.invariants ? []
  return { name: 'invariant_check', pass: true, per_invariant: [] } if invs.length is 0
  invList = invs.map((s, i) -> "  #{i + 1}. #{s}").join('\n')
  prompt = """
    You are grading a short story's fidelity to a list of invariants — facts
    that must stay true. For each invariant decide:
      preserved   — the story honors it (may paraphrase; fact holds).
      absent      — the story never touches it (silent, not contradicted).
      contradicted — the story says the opposite.

    Overall: preserved (all preserved), partial (some preserved, none
    contradicted), broken (any contradicted OR none preserved).

    Reply with exactly one JSON object, one line, no prose, no code fences.
    Shape:
      {"overall":"<preserved|partial|broken>",
       "per_invariant":[{"invariant":"<verbatim>","status":"<preserved|absent|contradicted>","note":"<short>"}]}

    Invariants:
    #{invList}

    Story:
    #{storyText}

    Output:
  """
  resp = await opts.judge prompt, { maxTokens: 900 }
  jt = stripJson(resp?.rawText ? resp?.text ? '')
  parsed = null
  try
    parsed = if jt then JSON.parse(jt) else null
  catch
    parsed = null
  return { name: 'invariant_check', pass: false, error: 'judge unparsable', per_invariant: [] } unless parsed?
  overall = String(parsed.overall ? 'broken').toLowerCase()
  { name: 'invariant_check', pass: overall is 'preserved', overall, per_invariant: parsed.per_invariant ? [] }

# LLM judge — coherence 1..5
checkCoherence = (L, storyText, opts) ->
  prompt = """
    Rate the coherence of this short story on a 1–5 scale, where:
      5 — clear arc, cause-and-effect, satisfying ending
      4 — mostly coherent, one weak seam
      3 — recognizable structure, several rough patches
      2 — fragmented; hard to follow
      1 — incoherent

    Reply with exactly one JSON object, no prose, no code fences.
    Shape: {"score":<1|2|3|4|5>,"note":"<one sentence>"}

    Story:
    #{storyText}

    Output:
  """
  resp = await opts.judge prompt, { maxTokens: 200 }
  jt = stripJson(resp?.rawText ? resp?.text ? '')
  parsed = null
  try
    parsed = if jt then JSON.parse(jt) else null
  catch
    parsed = null
  score = Number(parsed?.score ? 0)
  { name: 'coherence_check', pass: score >= 3, score, note: parsed?.note ? '(no note)' }

# ---------------------------------------------------------------- step

@step =
  desc: "Fixed-spine story SAT — generate a story from a locked spine and grade it"

  action: (L) ->
    spineRaw = await L.need 'sat_fixed_spine_json'
    spine = if typeof spineRaw is 'string' then JSON.parse(spineRaw) else spineRaw

    modelDir = L.param 'model_dir', L.param('quantized_model_dir', null)
    throw new Error "[#{L.stepName}] model_dir (or quantized_model_dir) required" unless modelDir?
    adapter  = L.param 'adapter_dir', null
    temp     = Number L.param('temperature', 0.8)
    topP     = Number L.param('top_p', 0.9)
    # Big budget so a full think + narrative fits without rescue; the
    # rescue fires only when the model runs long deliberating.
    maxTok   = Number L.param('max_tokens', 5000)
    minW     = Number L.param('min_words', 300)
    maxW     = Number L.param('max_words', 1200)
    graderModel = L.param('grader_model_dir', modelDir)
    graderTemp  = Number L.param('grader_temperature', 0.1)

    defaultTask = "Write a complete short story (roughly #{minW}–#{maxW} words). One narrative arc; end it cleanly."
    task = String(spine?.task ? L.param('task', defaultTask))

    promptText = buildStoryPrompt spine, task

    fullPrompt = "<|im_start|>user\n#{promptText}<|im_end|>\n<|im_start|>assistant\n"
    llmArgs =
      op:          'generate'
      modelDir:    modelDir
      prompt:      fullPrompt
      maxTokens:   maxTok
      temperature: temp
      topP:        topP
      raw:         true
    llmArgs.adapterPath = adapter if adapter?

    rawStory = await callWithThinkRescue L, llmArgs
    storyText = stripText rawStory

    L.make 'sat_story_prompt_text', promptText
    L.make 'sat_story_text',        storyText

    # judge closure — reused by both LLM checks
    judge = (p, opts = {}) ->
      args =
        op:          'generate'
        modelDir:    graderModel
        prompt:      "<|im_start|>user\n#{p}<|im_end|>\n<|im_start|>assistant\n"
        maxTokens:   opts.maxTokens ? 1200
        temperature: graderTemp
        topP:        0.8
        raw:         true
      raw = await callWithThinkRescue L, args
      { rawText: raw }

    charLock  = checkCharacterLock storyText, spine
    lenCheck  = checkLength storyText, minW, maxW
    invCheck  = await checkInvariants L, storyText, spine, { judge }
    cohCheck  = await checkCoherence  L, storyText, { judge }

    overall = charLock.pass and lenCheck.pass and invCheck.pass and cohCheck.pass
    bucket  = if overall then 'can_story' else 'cannot_story'

    verdict =
      pass:   overall
      bucket: bucket
      checks:
        character_lock:  charLock
        length_check:    lenCheck
        invariant_check: invCheck
        coherence_check: cohCheck
      knobs:
        temperature: temp
        top_p:       topP
        adapter_dir: adapter
        min_words:   minW
        max_words:   maxW

    console.log "[sat_story_ite] bucket=#{bucket} charLock=#{charLock.pass} length=#{lenCheck.pass}(#{lenCheck.word_count}w) invariants=#{invCheck.pass}(#{invCheck.overall ? '?'}) coherence=#{cohCheck.pass}(score=#{cohCheck.score})"

    L.make 'sat_story_verdict', verdict
    L.done()
    return
