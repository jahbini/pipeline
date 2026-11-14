###
  import_canonical_corpus_ite.coffee — reuse the frozen canonical corpus.

  Replaces oracle_ask_sqlite + simplify_stories_ite in elementary. Instead of
  recomputing the emotion/keyword KAG tags and plain-language simplifications
  per pipe with THAT pipe's (often small) model, this step copies the
  model-agnostic annotations — stories + kag_entries + story/chunk simplifications —
  from data/canonical_corpus.sqlite into this pipe's runtime.sqlite.

  All sqlite I/O lives in the meta layer: the `importCanonicalCorpus{force?}`
  request (meta/sqlite.coffee) ATTACHes the canonical file, version-checks a
  per-pipe marker, and does the copy. This step is a thin, idempotent trigger —
  NO LLM, NO direct db handle. Model-SPECIFIC artifacts (embeddings, the LoRA
  adapter) are untouched and still computed per pipe downstream.

  Idempotent: re-running is a no-op unless the canonical corpus_version changed
  (or `force_corpus_reimport: true`). So it's safe under resume + continuous.
###

@step =
  desc: "Import the frozen canonical corpus (kag + simplifications) — no LLM, no per-pipe recompute"
  action: (L) ->
    force = if L.param('force_corpus_reimport', false) is true then 'force' else ''
    res = L.theLowdown("importCanonicalCorpus{#{force}}.json")?.value
    unless res? and res.ok
      throw new Error "[import_canonical_corpus_ite] canonical import failed: #{JSON.stringify(res)}"
    if res.skipped
      console.log "[import_canonical_corpus_ite] pipe already at canonical corpus v=#{res.version} — nothing to import"
    else
      console.log "[import_canonical_corpus_ite] imported canonical corpus v=#{res.version}: #{res.stories} stories, #{res.kag_entries} kag_entries, #{res.simplifications} story-simpl, #{res.chunk_simplifications ? 0} chunk-simpl"
    L.make 'canonical_corpus_import', res
    L.done()
    return
