###
  elementary_ite.coffee  —  ELEMENTARY reading-comprehension SAT
  ==============================================================
  The lowest tier: "can this model read a short story and answer
  basic questions about it, plus produce a short summary?"

  Reads:
    elementary_story_text        the story text
    elementary_qa_json           { questions: [{q, expected_keywords: [...]}],
                                    summary_keywords: [...],
                                    max_summary_words: 60 }

  Writes:
    elementary_answers_json      the model's raw answers + summary
    elementary_verdict           { pass, bucket: "can_read" | "cannot_read",
                                    per_question: [...], summary: {...} }

  Knobs (all via L.param so overrides can sweep):
    model_dir           the generation model (quantized_model_dir default)
    adapter_dir         optional LoRA adapter to inject
    temperature         default 0.2 (comprehension wants low creativity)
    top_p               default 0.8
    max_answer_tokens   default 120
    max_summary_tokens  default 200
    grader_model_dir    for the LLM judge (falls back to model_dir)
    grader_temperature  default 0.1
    min_keywords_hit    min keywords per answer to count as correct (default 1)
    min_summary_hits    min summary_keywords covered (default 3)

  Bucket assignment:
    can_read   — ≥ ceil(0.75 × questions) answered correctly AND
                 summary hits ≥ min_summary_hits.
    cannot_read — otherwise.
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

tokenize = (s) -> String(s ? '').toLowerCase().match(/[a-z0-9']+/g) ? []

countKeywords = (text, keywords) ->
  toks = new Set tokenize(text)
  hits = []
  for kw in (keywords ? [])
    kws = String(kw).toLowerCase()
    if kws.split(/\s+/).length is 1
      hits.push kw if toks.has(kws)
    else
      hits.push kw if String(text).toLowerCase().indexOf(kws) >= 0
  hits

# One-shot chat-style LLM call. Returns {rawText, text}.
callLLM = (L, prompt, opts = {}) ->
  modelDir = opts.modelDir ? L.param('model_dir', L.param('quantized_model_dir', null))
  throw new Error "[#{L.stepName}] model_dir (or quantized_model_dir) required" unless modelDir?
  adapter = opts.adapterDir ? L.param('adapter_dir', null)
  llmArgs =
    op:          'generate'
    modelDir:    modelDir
    prompt:      "<|im_start|>user\n#{prompt}<|im_end|>\n<|im_start|>assistant\n"
    maxTokens:   opts.maxTokens   ? 1200
    temperature: opts.temperature ? 0.2
    topP:        opts.topP        ? 0.8
    raw:         true
  llmArgs.adapterPath = adapter if adapter?
  raw = await callWithThinkRescue L, llmArgs
  { rawText: raw }

# Thinking-budget rescue — same shape as helper_llm's runCapability.
# Run once; if </think> never closed, prepend a "time's up" clause
# and continue generation from that point.
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

# ---------------------------------------------------------------- step

@step =
  desc: "Elementary reading SAT — can the model read a short story and answer factual Q + summarize?"

  action: (L) ->
    storyText = await L.need 'elementary_story_text'
    qaRaw     = await L.need 'elementary_qa_json'
    qa        = if typeof qaRaw is 'string' then JSON.parse(qaRaw) else qaRaw
    questions = qa?.questions ? []
    summaryKw = qa?.summary_keywords ? []
    maxSumW   = Number(qa?.max_summary_words ? 60)

    temp        = Number L.param('temperature', 0.2)
    topP        = Number L.param('top_p', 0.8)
    # Thinking-mode models need room for a full think block before the
    # answer; rescue fires only when the model runs long deliberating.
    maxAnsTok   = Number L.param('max_answer_tokens', 1200)
    maxSumTok   = Number L.param('max_summary_tokens', 1600)
    minKwHit    = Number L.param('min_keywords_hit', 1)
    minSumHits  = Number L.param('min_summary_hits', 3)
    graderModel = L.param('grader_model_dir', L.param('quantized_model_dir', null))
    graderTemp  = Number L.param('grader_temperature', 0.1)

    # -------- answer each question
    perQuestion = []
    for q, i in questions
      qText = q?.q ? q?.question ? ''
      expected = q?.expected_keywords ? []
      prompt = """
        Read the story below and answer the question in one or two sentences.
        Use only facts from the story. Do not add opinions.

        Story:
        #{storyText}

        Question: #{qText}

        Answer:
      """
      resp = await callLLM L, prompt, { temperature: temp, topP: topP, maxTokens: maxAnsTok }
      answer = stripText(resp?.rawText ? resp?.text ? '')
      hits = countKeywords answer, expected
      perQuestion.push {
        idx:   i
        q:     qText
        answer:  answer
        expected_keywords: expected
        keywords_hit:      hits
        keyword_pass:      hits.length >= minKwHit
      }

    # -------- summary
    sumPrompt = """
      Read the story below and write a summary of at most #{maxSumW} words.
      Focus on who did what and how it ended. No opinions.

      Story:
      #{storyText}

      Summary:
    """
    sumResp = await callLLM L, sumPrompt, { temperature: temp, topP: topP, maxTokens: maxSumTok }
    summaryText = stripText(sumResp?.rawText ? sumResp?.text ? '')
    sumHits = countKeywords summaryText, summaryKw
    summaryWordCount = tokenize(summaryText).length

    # -------- optional LLM judge on each answer (adversarial rigor)
    withJudge = L.param('with_judge', true) isnt false
    if withJudge and questions.length > 0
      for pq in perQuestion
        judgePrompt = """
          You are grading a reading-comprehension answer for accuracy against
          a short story. Reply with exactly one JSON object, no prose, no
          code fences.

          Shape: {"verdict":"<correct|partial|wrong>","reason":"<one sentence>"}

          Story:
          #{storyText}

          Question: #{pq.q}
          Answer:   #{pq.answer}

          Output:
        """
        jr = await callLLM L, judgePrompt,
          modelDir: graderModel
          temperature: graderTemp
          maxTokens: 1000
        jt = stripJson(jr?.rawText ? jr?.text ? '')
        try
          parsed = if jt then JSON.parse(jt) else null
        catch
          parsed = null
        pq.judge = parsed ? { verdict: '?', reason: '(judge unparsable)' }
        pq.judge_correct = parsed?.verdict is 'correct'

    # -------- verdict + bucket
    kwPassCount = (p for p in perQuestion when p.keyword_pass).length
    judgePassCount = (p for p in perQuestion when p.judge_correct is true).length
    total = perQuestion.length
    threshold = Math.ceil(0.75 * total)

    factsPass = if withJudge and total > 0
      judgePassCount >= threshold
    else
      kwPassCount >= threshold

    summaryPass = sumHits.length >= minSumHits and summaryWordCount <= (maxSumW + 20)

    overall = factsPass and summaryPass
    bucket = if overall then 'can_read' else 'cannot_read'

    L.make 'elementary_answers_json', {
      per_question: perQuestion
      summary:      summaryText
      summary_word_count: summaryWordCount
    }

    verdict =
      pass:    overall
      bucket:  bucket
      facts:
        total:           total
        keyword_pass:    kwPassCount
        judge_pass:      if withJudge then judgePassCount else null
        threshold:       threshold
        pass:            factsPass
      summary:
        keywords_hit:    sumHits
        keywords_needed: minSumHits
        word_count:      summaryWordCount
        word_limit:      maxSumW
        pass:            summaryPass
      knobs:
        temperature:  temp
        top_p:        topP
        adapter_dir:  L.param('adapter_dir', null)
        with_judge:   withJudge

    console.log "[elementary_ite] bucket=#{bucket} facts=#{if factsPass then 'PASS' else 'FAIL'} (#{if withJudge then judgePassCount else kwPassCount}/#{total}) summary=#{if summaryPass then 'PASS' else 'FAIL'} (#{sumHits.length}/#{minSumHits} kw, #{summaryWordCount}/#{maxSumW}w)"

    L.make 'elementary_verdict', verdict
    L.done()
    return
