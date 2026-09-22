###
  elementary_sat.coffee — elementary SAT grader for one diary letter.

  A pass/fail gate: is this letter at least trying to tell a story?
  All checks in this first pass are FREE (regex + text math). LLM-judged
  checks (structure_order role classification, invariant_preserving) are
  stubbed with hooks; wire the helper when we want them.

  Inputs:
    --letter  <path>   the generated letter (e.g. out/diary_adapted.txt)
    --prompt  <path>   the prompt fed to the generator (out/diary_prompt.txt);
                       parsed to extract allowed-names, invariants, past-
                       writing scraps.
    --premise <path>   optional: story_description text (from experiment.yaml
                       story_outline.story_description). Used for premise-
                       adherence noun matching. If omitted, falls back to
                       nouns extracted from the invariants section.

  Output: one JSON verdict on stdout — { pass: bool, checks: [{name, pass, detail}] }.
  Exit code 0 if pass, 1 if fail (for CI use).

  Related memories: helper-reason-mining-findings, helper-kag-design.
###

fs   = require 'fs'
path = require 'path'

parseArgs = ->
  out = { letter: null, prompt: null, premise: null, verbose: false, withLlm: false }
  args = process.argv.slice(2)
  i = 0
  while i < args.length
    switch args[i]
      when '--letter'   then out.letter  = args[++i]
      when '--prompt'   then out.prompt  = args[++i]
      when '--premise'  then out.premise = args[++i]
      when '--verbose'  then out.verbose = true
      when '--with-llm' then out.withLlm = true
      when '-h', '--help'
        console.error "usage: coffee elementary_sat.coffee --letter <path> --prompt <path> [--premise <path>] [--verbose] [--with-llm]"
        process.exit 0
    i += 1
  throw new Error 'required: --letter <path>'   unless out.letter?
  throw new Error 'required: --prompt <path>'   unless out.prompt?
  out

# ---------------------------------------------------------------- letter parse

# Strip the greeting (first paragraph, contains "Hi," / "Dear," / etc. and
# is short) and the sign-off (last paragraph, contains "yours", "cheers", em
# dash + name pattern, etc.). Everything between = the 5 body paragraphs.
parseLetter = (text) ->
  # normalize line endings, collapse trailing whitespace
  raw = String(text ? '').replace(/\r\n/g, '\n').trim()
  # split on blank lines
  paragraphs = raw.split(/\n\s*\n+/).map (p) -> p.trim()
  paragraphs = paragraphs.filter (p) -> p.length > 0
  # heuristic strip: first paragraph looks like a greeting (≤ 4 lines, opens
  # with Hi/Dear/Hey/Greetings)
  greeting = null
  if paragraphs.length > 0 and /^\s*(hi|hey|dear|greetings|hello)\b/i.test(paragraphs[0]) and paragraphs[0].split(/\n/).length <= 4
    greeting = paragraphs.shift()
  # heuristic strip: sign-off can be one or two trailing paragraphs — a
  # "So, there you have it, friend..." transition + a "Yours ever, Jim"
  # closing. Peel from the end while paragraphs look sign-off-ish.
  signoff = []
  isSignoffPara = (p) ->
    return true if /^\s*(yours|cheers|until\s+next|till\s+next|take\s+care|so\s+long|— |-- |your\s+friend|your\s+pal|sincerely|regards|xoxo|farewell|adieu)/i.test(p)
    return true if /\bthere you have it\b/i.test(p) and p.length < 400
    return true if p.length < 120 and /\bjim\b/i.test(p)
    false
  while paragraphs.length > 0 and isSignoffPara(paragraphs[paragraphs.length - 1])
    signoff.unshift paragraphs.pop()
  signoff = if signoff.length then signoff.join('\n\n') else null
  {
    greeting
    signoff
    segments: paragraphs
    paragraph_count: paragraphs.length
  }

# ---------------------------------------------------------------- prompt parse
# The prompt has known section headers we can anchor on. Sections are
# separated by blank line + "SectionName:" pattern, or by known phrases.

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
  # allowed names — parse lines matching "  - Name (id: slug) ..."
  allowedNames = []
  if allowedNamesBlock?
    for line in allowedNamesBlock.split(/\n/)
      m = line.match /^\s*-\s+(.+?)\s*(?:\(id:\s*([^)]+)\))?\s*(?:\(.*\))?\s*$/
      continue unless m
      display = String(m[1]).trim()
      slug = if m[2] then String(m[2]).trim() else null
      allowedNames.push { display, slug }
  # invariants — each line starting with "- " is one invariant
  invariants = []
  if invariantsBlock?
    for line in invariantsBlock.split(/\n/)
      m = line.match /^\s*-\s+(.+?)\s*$/
      continue unless m
      invariants.push String(m[1]).trim()
  # past-writing scraps — pull each quoted block (curly OR straight quotes).
  # We match curly `“ ”` (U+201C / U+201D), straight `"`, and also single
  # curly / straight where those appear as block markers in some prompts.
  pastScraps = []
  if pastWritingBlock?
    quoteRe = new RegExp "[“\"]([\\s\\S]+?)[”\"]", 'g'
    for m from pastWritingBlock.matchAll quoteRe
      s = String(m[1]).trim()
      pastScraps.push s if s.length >= 40
  { allowedNames, invariants, pastScraps }

# ---------------------------------------------------------------- helpers

# tokenize into lowercase alphanumeric-word list — used for n-gram compare
tokenize = (s) ->
  String(s ? '').toLowerCase().match(/[a-z0-9']+/g) ? []

# Extract candidate content nouns from a text — capitalized proper nouns and
# domain words. Used to build a "premise noun" set for the adherence check
# when we don't have an explicit story_description handy.
extractPremiseNouns = (text) ->
  words = String(text ? '').match(/\b[A-Za-z][a-z]{3,}\b/g) ? []
  seen = new Set()
  keep = []
  # keep words that look content-y: not a common function word
  stop = new Set 'about above after again against because before being below between during either every from having having himself into itself might more most much must never other others should since some such than that their them then there these they this those through under until upon very were what when where which while would your'.split(/\s+/)
  for w in words
    lw = w.toLowerCase()
    continue if stop.has(lw)
    continue if lw.length < 4
    unless seen.has(lw)
      seen.add(lw)
      keep.push lw
  keep

# ---------------------------------------------------------------- CHECKS

# 1. STRUCTURE COUNT — pass if exactly 5 body paragraphs.
checkStructureCount = (letter) ->
  n = letter.paragraph_count
  {
    name:   'structure_count'
    pass:   n is 5
    detail: "paragraph_count=#{n} (expected 5)"
  }

# 2. CHARACTER-LOCK — pass if no named person outside allowedNames appears.
# We're conservative: named-person detection = Capitalized-word not at
# sentence start, or explicit allowed-list slug mismatch. Cheap heuristic;
# false positives possible for place names. Anchor: allowedNames list.
BUILTIN_STOP = new Set 'Jim Friend I A The It He She They We You Yes No Maybe But And Or So Also Then Now Today Tomorrow Yesterday Sunday Monday Tuesday Wednesday Thursday Friday Saturday January February March April May June July August September October November December God Lord Christ Sir Madam Mister Missus Mister Mrs'.split(/\s+/)
# Only tokens after strong sentence separators trigger "sentence start"; ANY
# other capitalized word is a candidate proper noun. This is heuristic — false
# positives are inevitable, so we trim aggressively.
COMMON_ADVERBS = new Set 'Finally Anyway Meanwhile Later Sometimes Sometime Suddenly Eventually Instead Also Yet Still However Perhaps Maybe Certainly Surely Really Only Even Just Well Actually Basically Frankly Honestly Unfortunately Fortunately Interestingly Curiously Strangely Naturally Obviously Clearly Somehow Anyhow Somewhere Somewhat Someone Something Somebody Everyone Everything Everybody Nobody Nothing Anywhere Anyone Anything Anybody Nowhere Whenever Whatever Whoever Wherever'.split(/\s+/)
# Place-name compounds keep their internal Capitals — we handle "St. John's"
# via a dedicated whitelist rather than trying to parse it.
COMMON_PLACES = new Set 'John Johns Portland Oregon Persia Russia America Willamette Lombard'.split(/\s+/).map (s) -> s.toLowerCase()
checkCharacterLock = (letter, promptData) ->
  allowedSet = new Set()
  for a in promptData.allowedNames
    allowedSet.add String(a.display).toLowerCase()
    allowedSet.add String(a.slug).toLowerCase() if a.slug
  # Always allow the addressee "Friend" and Jim himself.
  allowedSet.add 'jim'; allowedSet.add 'friend'
  body = letter.segments.join('\n\n')
  # Collect capitalized-word candidates NOT at sentence start. Sentence start
  # = beginning of paragraph OR after `. ! ?` followed by whitespace.
  cands = []
  # walk through the body and pick capitalized words that aren't sentence-initial
  bodyPad = ' ' + body
  # match: (preceding non-terminator char) + capitalized word
  # We use a simpler approach: split into "words after ANY whitespace" and
  # separately track sentence-start positions.
  # First find sentence starts.
  sentenceStartIdx = new Set()
  sentenceStartIdx.add 0
  for m from bodyPad.matchAll /[.!?]["'”)]?\s+/g
    sentenceStartIdx.add(m.index + m[0].length)
  # Now iterate all capitalized word positions.
  for m from bodyPad.matchAll /\b([A-Z][a-zA-Z']{2,})\b/g
    word = m[1]
    # Reject contractions like I'm, I'll, It's, We're etc.
    continue if /'(s|m|d|t|ll|ve|re)$/i.test word
    # Skip word if at a sentence start
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

# 3. FRESHNESS-COPY — pass if no 6+ consecutive token substring from any
# past-writing scrap appears verbatim in the letter.
checkFreshnessCopy = (letter, promptData, minRun = 6) ->
  bodyTokens = tokenize letter.segments.join('\n\n')
  # index bodyTokens n-grams for quick lookup
  bodyGrams = new Map()
  for i in [0..bodyTokens.length - minRun]
    key = bodyTokens[i...i + minRun].join(' ')
    (bodyGrams.get(key) ? []).push(i) unless bodyGrams.has(key)
    bodyGrams.set(key, bodyGrams.get(key) ? [i])
  hits = []
  for scrap, si in promptData.pastScraps
    scrapTokens = tokenize scrap
    continue if scrapTokens.length < minRun
    for j in [0..scrapTokens.length - minRun]
      key = scrapTokens[j...j + minRun].join(' ')
      if bodyGrams.has(key)
        # extend the run as far as it goes
        run = minRun
        bi = bodyGrams.get(key)[0]
        while bi + run < bodyTokens.length and j + run < scrapTokens.length and bodyTokens[bi + run] is scrapTokens[j + run]
          run += 1
        hits.push { run, phrase: scrapTokens[j...j + run].join(' '), scrap_idx: si }
        break    # one hit per scrap is enough evidence
  {
    name:   'freshness_copy'
    pass:   hits.length is 0
    detail: if hits.length then "verbatim copy: #{hits.map((h) -> "'#{h.phrase}' (#{h.run} toks)").join('; ')}" else "no verbatim runs ≥ #{minRun} tokens from past-writing scraps"
    hits: hits
  }

# 4. PREMISE-ADHERENCE — pass if letter mentions ≥ N content nouns from the
# premise (story_description if supplied, else nouns from invariants).
# N default is 3 (weak signal — the letter is at least gesturing at the premise).
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

# 5. STRUCTURE-ORDER (LLM) — classify each paragraph's role, compare to
# expected position. Fails if any paragraph fits "wrong", or if ≥ 2
# paragraphs fit "weak". Passes on all-good.
EXPECTED_ROLES = ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
checkStructureOrder = (letter) ->
  if letter.paragraph_count isnt 5
    return {
      name:   'structure_order'
      pass:   false
      detail: "cannot grade — paragraph_count=#{letter.paragraph_count} ≠ 5"
      skipped: false
    }
  helper = require '/Users/jahbini/pipeline/mlx/helper_llm'
  per = []
  for para, i in letter.segments
    expected = EXPECTED_ROLES[i]
    resp = await helper.grade_role para, expected
    per.push {
      position: i, expected: expected
      got:     resp?.role  ? '?'
      fit:     resp?.fit   ? '?'
      reason:  resp?.reason ? '(no reason)'
      ok:      resp?.ok is true
    }
  try helper.dispose?() catch then null
  wrongs = (p for p in per when p.fit is 'wrong')
  weaks  = (p for p in per when p.fit is 'weak')
  pass   = wrongs.length is 0 and weaks.length < 2
  {
    name:   'structure_order'
    pass:   pass
    detail: "wrong=#{wrongs.length} weak=#{weaks.length} good=#{per.length - wrongs.length - weaks.length} / 5"
    per_paragraph: per
  }

# 6. INVARIANT-PRESERVING (LLM) — one call for all invariants. Pass if
# overall is "preserved". Fail if "broken". Warn (still fail) if "partial".
checkInvariantPreserving = (letter, promptData) ->
  return {
    name:   'invariant_preserving'
    pass:   true      # nothing to check → not a failure
    detail: 'no invariants declared in prompt'
    skipped: false
  } unless promptData.invariants.length > 0
  helper = require '/Users/jahbini/pipeline/mlx/helper_llm'
  body = letter.segments.join('\n\n')
  resp = await helper.grade_invariants body, promptData.invariants
  try helper.dispose?() catch then null
  if not resp?.ok
    return {
      name:   'invariant_preserving'
      pass:   false
      detail: "grader failed: #{resp?.error ? '(unknown)'}"
      skipped: false
    }
  overall = String(resp.overall ? 'broken').toLowerCase()
  {
    name:   'invariant_preserving'
    pass:   overall is 'preserved'
    detail: "overall=#{overall}; per_invariant statuses: #{(String(x?.status ? '?') for x in (resp.per_invariant ? [])).join(', ')}"
    overall: overall
    per_invariant: resp.per_invariant ? []
  }

# Stubs used when --with-llm is not passed.
checkStructureOrderStub = (letter) ->
  { name: 'structure_order', pass: null, skipped: true, detail: '(LLM check — pass --with-llm)' }

checkInvariantPreservingStub = (letter, promptData) ->
  { name: 'invariant_preserving', pass: null, skipped: true, detail: "(LLM check — pass --with-llm; invariants: #{promptData.invariants.length})" }

# ---------------------------------------------------------------- runner

main = ->
  opts = parseArgs()
  letterText = fs.readFileSync(opts.letter, 'utf8')
  promptText = fs.readFileSync(opts.prompt, 'utf8')
  premiseText = if opts.premise then fs.readFileSync(opts.premise, 'utf8') else null
  letter = parseLetter letterText
  promptData = parsePrompt promptText
  checks = [
    checkStructureCount     letter
    checkCharacterLock      letter, promptData
    checkFreshnessCopy      letter, promptData
    checkPremiseAdherence   letter, promptData, premiseText
  ]
  if opts.withLlm
    checks.push await checkStructureOrder      letter
    checks.push await checkInvariantPreserving letter, promptData
  else
    checks.push checkStructureOrderStub        letter
    checks.push checkInvariantPreservingStub   letter, promptData
  # aggregate: pass = every non-skipped check passed
  hardChecks = checks.filter (c) -> not c.skipped
  overall = hardChecks.every (c) -> c.pass is true
  verdict =
    letter: opts.letter
    prompt: opts.prompt
    pass:   overall
    hard_pass_count:   (c for c in hardChecks when c.pass is true).length
    hard_total:        hardChecks.length
    prompt_meta:
      allowed_names: promptData.allowedNames
      invariants:    promptData.invariants
      past_scraps:   promptData.pastScraps.length
    letter_meta:
      paragraph_count: letter.paragraph_count
      has_greeting:    letter.greeting?
      has_signoff:     letter.signoff?
    checks: checks
  if opts.verbose
    process.stderr.write "=== elementary SAT verdict ===\n"
    process.stderr.write "letter:  #{opts.letter}\n"
    process.stderr.write "prompt:  #{opts.prompt}\n"
    process.stderr.write "overall: #{if overall then 'PASS' else 'FAIL'} (#{verdict.hard_pass_count}/#{verdict.hard_total})\n"
    for c in checks
      status = if c.skipped then 'SKIP' else if c.pass then 'PASS' else 'FAIL'
      process.stderr.write "  [#{status}] #{c.name}: #{c.detail}\n"
    process.stderr.write '\n'
  process.stdout.write JSON.stringify(verdict, null, 2) + '\n'
  process.exit(if overall then 0 else 1)

main() if require.main is module
