###
  compare_adapters_ite.coffee  —  adapter-ranking eval harness (writediary)
  =========================================================================
  Ranks a LIST of LoRA adapters (including the base model) on a FROZEN,
  held-out prompt set with PINNED sampling, so two adapters can be RANKED
  rather than eyeballed. Self-contained: reads its prompt+sampling spec
  from disk, generates greedily (temperature 0 = deterministic argmax —
  see @frost-beta/llm base.js sample(); topP is bypassed, no seed needed),
  and scores the dimensions the training-fix changes target:

    - termination_rate  fraction of completions that STOPPED on their own
                        (generated_tokens < max_tokens  =>  emitted EOS).
                        runaway_rate = 1 - termination_rate.  ← Change 1 target
    - repetition        distinct2 / distinct4 (higher = less repetitive) and
                        top4_repeat (max count of any single 4-gram; a loop
                        shows as a large value).
    - voice_cosine      mean cosine of each completion's embedding vs the Jim
                        centroid (mean of kag_embeddings) — the same voice-
                        fidelity signal judge_run_ite ranks on.
    - shape             sentence_ending_rate, word_count_mean.

  Writes the `adapter_comparison` artifact (ranked table + per-prompt
  completions) to disk.

  MEMORY: L.callLLM caches one loaded model per modelDir::adapter
  (mlx/llm_dispatch.coffee getSession). Comparing base + N adapters keeps
  N+1 quantized models resident. Keep `compare_adapters` small (2-3) on
  memory-constrained machines.

  fs is used to read the frozen eval spec — a legitimate config read for an
  eval-infra step (the spec is a pinned asset, like model/*), not scratch.
###
fs = require 'fs'

wordsOf = (t) -> String(t ? '').split(/\s+/).filter (w) -> w.length > 0

ngramsOf = (words, n) ->
  return [] if words.length < n
  (words[i...i + n].join(' ') for i in [0..words.length - n])

distinctN = (words, n) ->
  gs = ngramsOf words, n
  return 1 if gs.length is 0
  (new Set(gs)).size / gs.length

topRepeat = (words, n) ->
  gs = ngramsOf words, n
  return 0 if gs.length is 0
  counts = {}
  best = 0
  for g in gs
    counts[g] = (counts[g] ? 0) + 1
    best = counts[g] if counts[g] > best
  best

endsSentence = (s) -> /[.!?…"'’”]\s*$/.test String(s ? '').trim()

mean = (xs) -> if xs.length then (xs.reduce ((a, b) -> a + b), 0) / xs.length else 0

@step =
  desc: "Rank a list of adapters on a frozen held-out prompt set (termination / repetition / voice)"

  action: (L) ->
    specPath          = L.param 'eval_spec_path'
    quantizedModelDir = L.param 'quantized_model_dir'
    adapters          = L.param 'compare_adapters'

    throw new Error "[#{L.stepName}] eval_spec_path must be a string"        unless typeof specPath is 'string' and specPath.length
    throw new Error "[#{L.stepName}] quantized_model_dir must be a string"   unless typeof quantizedModelDir is 'string' and quantizedModelDir.length
    throw new Error "[#{L.stepName}] compare_adapters must be a non-empty array" unless Array.isArray(adapters) and adapters.length > 0
    throw new Error "[#{L.stepName}] eval spec not found: #{specPath}"        unless fs.existsSync specPath

    spec = JSON.parse fs.readFileSync(specPath, 'utf8')
    prompts = spec.prompts
    throw new Error "[#{L.stepName}] eval spec has no non-empty prompts[]" unless Array.isArray(prompts) and prompts.length > 0
    temperature = spec.sampling?.temperature ? 0
    maxTokens   = spec.sampling?.max_tokens ? 256

    console.log "[#{L.stepName}] spec        : #{specPath}"
    console.log "[#{L.stepName}] prompts     : #{prompts.length}   sampling: temp=#{temperature} max_tokens=#{maxTokens}"
    console.log "[#{L.stepName}] adapters    : #{(a.label for a in adapters).join(', ')}"

    # --- Jim centroid from kag_embeddings (same source as voice_similarity_ite)
    rowsEntry = L.theLowdown 'kagAllEmbeddings.jsonl'
    embRows = rowsEntry?.value ? []
    centroid = null
    if embRows.length > 0
      floatArrays = []
      expectedDim = null
      for r in embRows
        arr = L.tools.embedding_blob.blobToFloatArray Buffer.from(r.embedding_b64, 'base64')
        expectedDim ?= arr.length
        continue unless arr.length is expectedDim
        floatArrays.push arr
      centroid = L.tools.embedding_blob.meanOfFloatArrays floatArrays
      console.log "[#{L.stepName}] centroid    : dim=#{centroid?.length ? 0} from #{floatArrays.length} kag chunks"
    else
      console.error "[#{L.stepName}] kag_embeddings empty — voice_cosine will be null (termination/repetition still computed)"

    # Voice is best-effort: if the embed op is unavailable on this stack, we
    # disable it after the FIRST failure (one clean message, no per-prompt
    # spam) and still report termination + repetition, which are what Changes
    # 1-3 target. Starts enabled only if we actually built a centroid.
    voiceEnabled = centroid?

    # --- generate + score per adapter ---------------------------------------
    results = []
    for adapter in adapters
      label       = String(adapter?.label ? 'unlabeled')
      adapterPath = adapter?.adapter_path ? null
      console.log "[#{L.stepName}] === #{label} (#{adapterPath ? 'base, no adapter'}) ==="

      perPrompt = []
      for prompt, pi in prompts
        genParams =
          op: 'generate'
          modelDir: quantizedModelDir
          prompt: prompt
          raw: true
          maxTokens: maxTokens
          temperature: temperature
        genParams.adapterPath = adapterPath if adapterPath?
        res = await L.callLLM genParams
        completion = String(res?.text ? res?.rawText ? '')
        genTokens  = Number(res?.generatedTokens ? 0)
        words = wordsOf completion

        cosine = null
        if voiceEnabled and completion.trim().length > 0
          try
            emb = (await L.callLLM {op: 'embed', modelDir: quantizedModelDir, prompt: completion, raw: true})?.embedding
            cosine = Math.round((L.tools.embedding_blob.cosineSimilarity emb, centroid) * 10000) / 10000 if emb?
          catch err
            voiceEnabled = false
            console.error "[#{L.stepName}] voice DISABLED for this run — embed unavailable: #{err?.message ? err}"
            console.error "[#{L.stepName}] (termination + repetition metrics are unaffected)"

        row =
          prompt_index:     pi
          generated_tokens: genTokens
          terminated:       genTokens < maxTokens   # stopped on EOS vs hitting the cap
          word_count:       words.length
          ends_sentence:    endsSentence completion
          distinct2:        Math.round(distinctN(words, 2) * 10000) / 10000
          distinct4:        Math.round(distinctN(words, 4) * 10000) / 10000
          top4_repeat:      topRepeat words, 4
          voice_cosine:     cosine
          completion:       completion
        perPrompt.push row
        console.log "[#{L.stepName}]   p#{pi}: tok=#{genTokens}#{if row.terminated then ' EOS' else ' RUNAWAY'} wc=#{row.word_count} d2=#{row.distinct2} top4=#{row.top4_repeat} cos=#{cosine ? 'n/a'}"

      cosines  = (p.voice_cosine for p in perPrompt when p.voice_cosine?)
      termN    = (p for p in perPrompt when p.terminated).length
      sentN    = (p for p in perPrompt when p.ends_sentence).length
      nP       = perPrompt.length
      top4vals = (p.top4_repeat for p in perPrompt)
      metrics =
        n:                    nP
        termination_rate:     Math.round(termN / nP * 10000) / 10000
        runaway_rate:         Math.round((nP - termN) / nP * 10000) / 10000
        distinct2_mean:       Math.round(mean(p.distinct2 for p in perPrompt) * 10000) / 10000
        distinct4_mean:       Math.round(mean(p.distinct4 for p in perPrompt) * 10000) / 10000
        top4_repeat_max:      (if top4vals.length then Math.max(top4vals...) else 0)
        sentence_ending_rate: Math.round(sentN / nP * 10000) / 10000
        word_count_mean:      Math.round(mean(p.word_count for p in perPrompt))
        voice_cosine_mean:    (if cosines.length then Math.round(mean(cosines) * 10000) / 10000 else null)
      results.push {label, adapter_path: adapterPath, metrics, per_prompt: perPrompt}

    # --- rank: primary voice_cosine_mean desc, tie-break termination_rate ----
    ranked = results.slice().sort (a, b) ->
      av = a.metrics.voice_cosine_mean ? -1
      bv = b.metrics.voice_cosine_mean ? -1
      return bv - av if bv isnt av
      b.metrics.termination_rate - a.metrics.termination_rate

    console.log "[#{L.stepName}] ---- RANK (by voice_cosine_mean, then termination) ----"
    for r, i in ranked
      m = r.metrics
      console.log "[#{L.stepName}] #{i + 1}. #{r.label.padEnd(16)} voice=#{m.voice_cosine_mean ? 'n/a'}  term=#{(m.termination_rate * 100).toFixed(0)}%  d2=#{m.distinct2_mean.toFixed(3)}  top4max=#{m.top4_repeat_max}  wc=#{m.word_count_mean}"

    L.make 'adapter_comparison',
      spec_path:       specPath
      sampling:        {temperature, max_tokens: maxTokens}
      prompt_count:    prompts.length
      centroid_chunks: (if centroid? then embRows.length else 0)
      ranked_labels:   (r.label for r in ranked)
      results:         results
      compared_at:     new Date().toISOString()
    L.done()
    return
