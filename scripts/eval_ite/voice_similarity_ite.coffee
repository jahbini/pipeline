###
  voice_similarity_ite.coffee  —  EVAL_ITE pipeline step
  =====================================================
  Replaces the legacy `distinct2_mean` proxy with a direct measure of
  voice fidelity: the cosine similarity between each completion's
  embedding and the Jim centroid (mean of all kag_embeddings rows).

  Embeddings are produced by the same `mlx_lm cache_prompt` path the
  oracle step uses — for the corpus these are read from SQLite where
  the oracle step persisted them; for completions we run cache_prompt
  inline here and pool to a single vector.

  Output `voice_similarity` artifact shape:
    {
      centroid:
        dim: <int>
        source_chunks: <int>           # how many kag_embeddings rows averaged
      by_variant:
        <variant_name>:
          n: <int>
          cosine_mean: <0..1>
          cosine_median: <0..1>
          per_completion: [{prompt_index, cosine}...]
      summarized_at: <ISO>
    }
###
# Temp safetensors files for `cache_prompt` go through
# `L.tools.tmp_file` (mint a path + best-effort unlink).
# cache_embedding is reached as `L.tools.cache_embedding.<fn>(...)`.
# The tool's location on disk is opaque to this step — the runner
# resolves it BASE↠CWD↠EXEC. See GPT/CONVENTIONS.md § "Tools".

@step =
  desc: "Compute voice-similarity cosine for each completion against the Jim centroid"

  action: (L) ->
    ablations = await L.need 'ablations'
    throw new Error "[#{L.stepName}] ablations must be an array" unless Array.isArray(ablations)
    throw new Error "[#{L.stepName}] ablations is empty" if ablations.length is 0

    # 1. Build Jim centroid from kag_embeddings via the sqlite meta.
    # If the corpus has no embeddings yet (e.g., oracle hasn't been re-run
    # with the new code on this DB), don't block the pipeline — emit a
    # placeholder artifact and exit cleanly. judge_run_ite's fallback
    # kicks in and the recipe still produces an eval_score.
    rowsEntry = L.theLowdown 'kagAllEmbeddings.jsonl'
    rows = rowsEntry?.value ? []
    if rows.length is 0
      console.error "[#{L.stepName}] kag_embeddings is empty — skipping voice-similarity (judge will fall back to distinct2)"
      console.error "[#{L.stepName}] to enable: re-run oracle_ite on this corpus with the new code so kag_embeddings populates"
      L.make 'voice_similarity',
        available: false
        reason: 'kag_embeddings table is empty; oracle has not populated embeddings on this corpus'
        summarized_at: new Date().toISOString()
      L.done()
      return

    floatArrays = []
    expectedDim = null
    for row in rows
      buf = Buffer.from row.embedding_b64, 'base64'
      arr = L.tools.cache_embedding.blobToFloatArray buf
      expectedDim ?= arr.length
      if arr.length isnt expectedDim
        console.error "[#{L.stepName}] embedding dim mismatch for #{row.story_id}/#{row.chunk_index}: got #{arr.length}, expected #{expectedDim} — skipping"
        continue
      floatArrays.push arr

    centroid = L.tools.cache_embedding.meanOfFloatArrays floatArrays
    unless centroid?
      console.error "[#{L.stepName}] could not build centroid (no valid embeddings) — emitting placeholder"
      L.make 'voice_similarity',
        available: false
        reason: 'could not build centroid from kag_embeddings rows'
        summarized_at: new Date().toISOString()
      L.done()
      return

    # 2. Encoder model needed only now — defer validation until here so
    # the empty-corpus path above can short-circuit even if model_dir
    # isn't configured.
    quantizedModelDir = L.param 'quantized_model_dir'
    adapterPath       = L.param 'adapter_path', null
    throw new Error "[#{L.stepName}] quantized_model_dir must be a string" unless typeof quantizedModelDir is 'string' and quantizedModelDir.length

    console.log "[#{L.stepName}] centroid    : dim=#{centroid.length}  built from #{floatArrays.length} kag chunks"
    console.log "[#{L.stepName}] model       : #{quantizedModelDir}"
    console.log "[#{L.stepName}] ablations   : #{ablations.length} rows"

    # 2. For each completion: cache_prompt → extract embedding → cosine.
    byVariant = {}
    for row, i in ablations
      variant = String(row?.variant ? 'unknown')
      completion = String(row?.completion ? '').trim()
      byVariant[variant] ?= { cosines: [], per_completion: [] }

      if completion.length is 0
        # Empty completions get cosine=0 (rather than throwing).
        byVariant[variant].cosines.push 0
        byVariant[variant].per_completion.push
          prompt_index: row.prompt_index
          cosine: 0
          empty: true
        continue

      cacheFile = L.tools.tmp_file.make 'voice_eval', 'safetensors'
      try
        cacheArgs =
          model: quantizedModelDir
          prompt: completion
          'prompt-cache-file': cacheFile
        cacheArgs['adapter-path'] = adapterPath if adapterPath?
        L.callMLX 'cache_prompt', cacheArgs
        emb = L.tools.cache_embedding.embeddingFromCacheFile cacheFile
        cos = L.tools.cache_embedding.cosineSimilarity emb, centroid
        byVariant[variant].cosines.push cos
        byVariant[variant].per_completion.push
          prompt_index: row.prompt_index
          cosine: Math.round(cos * 10000) / 10000
        console.log "[#{L.stepName}] row #{i + 1}/#{ablations.length}  #{variant.padEnd(14)}  cosine=#{cos.toFixed(4)}"
      catch err
        console.error "[#{L.stepName}] row #{i} failed: #{err?.message ? err}"
        byVariant[variant].cosines.push 0
        byVariant[variant].per_completion.push
          prompt_index: row.prompt_index
          cosine: 0
          error: String(err?.message ? err)
      finally
        L.tools.tmp_file.remove cacheFile

    # 3. Aggregate per-variant statistics.
    median = (xs) ->
      return 0 unless xs.length
      sorted = xs.slice().sort (a, b) -> a - b
      mid = Math.floor sorted.length / 2
      if sorted.length % 2 then sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2

    summary = {}
    for own variant, data of byVariant
      cosines = data.cosines
      n = cosines.length
      mean = if n then (cosines.reduce(((a, b) -> a + b), 0) / n) else 0
      summary[variant] =
        n: n
        cosine_mean: Math.round(mean * 10000) / 10000
        cosine_median: Math.round(median(cosines) * 10000) / 10000
        per_completion: data.per_completion

    for own variant, m of summary
      console.log "[#{L.stepName}] variant=#{variant.padEnd(14)} n=#{m.n} mean=#{m.cosine_mean.toFixed(4)} median=#{m.cosine_median.toFixed(4)}"

    L.make 'voice_similarity',
      available: true
      centroid:
        dim: centroid.length
        source_chunks: floatArrays.length
      by_variant: summary
      summarized_at: new Date().toISOString()
    L.done()
    return
