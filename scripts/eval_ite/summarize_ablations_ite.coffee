###
  summarize_ablations_ite.coffee  —  EVAL_ITE pipeline step
  =====================================================
  Port of `~/development/pipeline/scripts/full/sanity.coffee`, with the
  ADDITION of `distinct2_mean` and `mem_sub_rate` metrics (referenced by
  the legacy scoring formula but never implemented in the legacy repo —
  see `GPT/legacy_pipeline.md` § "The missing pieces").

  Reads the `ablations` artifact (rows from generate_ablations_ite),
  groups by variant ('base' / 'with_adapter'), and computes per-variant:

    - n                     — number of completions
    - empty_rate            — fraction that are empty after cleaning
    - sentence_ending_rate  — fraction ending in . ! ? …
    - word_count_mean       — average word count
    - word_count_median     — median word count
    - distinct2_mean        — |unique bigrams| / |total bigrams|
                              (lexical diversity; higher = less repetitive)
    - mem_sub_rate          — fraction of completions containing any
                              contiguous substring of length
                              `mem_substring_length` from the training
                              corpus (memorization; higher = worse)

  The training corpus is read from the same SQLite request key the
  agent surface uses (`allStories.jsonl`) — so the memorization check
  always reflects the current corpus, not a stale snapshot.
###
@step =
  desc: "Aggregate ablation rows into per-variant metrics (incl. distinct2 + mem_sub)"

  action: (L) ->
    ablations = await L.need 'ablations'
    throw new Error "[#{L.stepName}] ablations must be an array" unless Array.isArray(ablations)
    throw new Error "[#{L.stepName}] ablations is empty" if ablations.length is 0

    memSubLen = L.param 'mem_substring_length', 40
    memSubLen = Number(memSubLen)
    throw new Error "[#{L.stepName}] mem_substring_length must be a positive integer" unless Number.isFinite(memSubLen) and memSubLen > 0

    # Load training corpus via the sqlite meta — the same surface the
    # agent uses (`/api/sqlite/allStories.jsonl`). If sqlite isn't
    # loaded or the table is empty, mem_sub_rate falls back to 0 with
    # a `corpus_chars: 0` note in the summary.
    corpusEntry = L.theLowdown 'allStories.jsonl'
    corpusRows = corpusEntry?.value ? []
    corpusText = (String(r?.text ? '') for r in corpusRows).join('\n').replace(/\s+/g, ' ')
    console.log "[#{L.stepName}] corpus     : #{corpusRows.length} stories, #{corpusText.length} chars"
    console.log "[#{L.stepName}] mem_substr : #{memSubLen} chars"

    # Group ablation rows by variant.
    byVariant = {}
    for row in ablations
      v = String(row?.variant ? 'unknown')
      byVariant[v] ?= []
      byVariant[v].push row

    summary = {}
    for own variant, rows of byVariant
      summary[variant] = computeMetrics rows, corpusText, memSubLen
      m = summary[variant]
      console.log "[#{L.stepName}] variant=#{variant.padEnd(14)} n=#{m.n} empty=#{(m.empty_rate*100).toFixed(1)}% sent=#{(m.sentence_ending_rate*100).toFixed(1)}% wc=#{m.word_count_mean.toFixed(1)} distinct2=#{m.distinct2_mean.toFixed(3)} mem_sub=#{(m.mem_sub_rate*100).toFixed(1)}%"

    L.make 'ablation_summary',
      by_variant: summary
      variants: Object.keys(byVariant)
      total_rows: ablations.length
      corpus_stories: corpusRows.length
      corpus_chars: corpusText.length
      mem_substring_length: memSubLen
      summarized_at: new Date().toISOString()
    L.done()
    return

# --- metrics helpers --------------------------------------------------

endsSentence = (s) -> /[.!?…"'’”]\s*$/.test String(s).trim()

bigramsOf = (text) ->
  words = String(text ? '').split(/\s+/).filter (w) -> w.length > 0
  return [] if words.length < 2
  ("#{words[i]} #{words[i + 1]}" for i in [0...words.length - 1])

# Substring-match detection. Scans the completion (normalized to single-
# space whitespace) for any contiguous run of `k` chars that also appears
# in the corpus. Linear in completion length × corpus length worst case,
# but mostly short-circuits on the first match.
hasMemSubstring = (completion, corpus, k) ->
  return false if not corpus? or corpus.length < k
  c = String(completion ? '').replace(/\s+/g, ' ').trim()
  return false if c.length < k
  for i in [0..c.length - k]
    sub = c.slice(i, i + k)
    return true if corpus.indexOf(sub) isnt -1
  false

median = (xs) ->
  return 0 unless xs.length
  sorted = xs.slice().sort (a, b) -> a - b
  mid = Math.floor sorted.length / 2
  if sorted.length % 2 then sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2

computeMetrics = (rows, corpusText, memSubLen) ->
  n          = rows.length
  emptyN     = 0
  sentEndN   = 0
  memHitsN   = 0
  wordCounts = []
  allBigrams = []
  uniqueBigrams = new Set()

  for row in rows
    text = String(row?.completion ? '').trim()
    if text.length is 0
      emptyN += 1
      wordCounts.push 0
      continue
    sentEndN += 1 if endsSentence text
    wc = text.split(/\s+/).length
    wordCounts.push wc
    bigrams = bigramsOf text
    allBigrams = allBigrams.concat bigrams
    uniqueBigrams.add b for b in bigrams
    memHitsN += 1 if hasMemSubstring(text, corpusText, memSubLen)

  totalBigrams = allBigrams.length

  {
    n:                    n
    empty_rate:           if n then emptyN / n else 0
    sentence_ending_rate: if n then sentEndN / n else 0
    word_count_mean:      if n then (wordCounts.reduce(((a, b) -> a + b), 0) / n) else 0
    word_count_median:    median(wordCounts)
    distinct2_mean:       if totalBigrams then uniqueBigrams.size / totalBigrams else 0
    mem_sub_rate:         if n then memHitsN / n else 0
  }
