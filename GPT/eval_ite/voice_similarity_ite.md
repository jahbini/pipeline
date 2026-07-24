Step: `voice_similarity_ite`
Recipe: `eval_ite`

Purpose:
- direct measure of voice fidelity: cosine similarity between each
  completion's hidden-state embedding and the Jim centroid (mean of
  `kag_embeddings` rows). Replaces `distinct2` as the primary signal
  for "is this in Jim's voice?"

Inputs:
- artifact `ablations`
- meta read `kagAllEmbeddings.jsonl` (the corpus-side embeddings,
  populated by `oracle_ask_sqlite` at oracle time)
- params `quantized_model_dir`, `adapter_path` (only read on the
  non-empty-corpus path; deliberately deferred so the empty-corpus
  path can short-circuit without requiring them)

Outputs:
- artifact `voice_similarity`. Two shapes:
  - empty-corpus / no centroid:
    ```
    available: false
    reason: "<why>"
    summarized_at
    ```
  - normal:
    ```
    available: true
    centroid: { dim, source_chunks }
    by_variant:
      <variant>:
        n
        cosine_mean
        cosine_median
        per_completion: [{prompt_index, cosine}, ...]
    summarized_at
    ```

Encoding pattern (2026-07-24 port):
- one `L.callLLM({op:'embed', modelDir, prompt: completion, raw:true, adapterPath?})`
  per completion. Runs prompt through the model in-process, extracts
  last-layer V from `llm.kvCache`, mean-pools across `seq_len` →
  1024-dim `Float32Array` (for Qwen3-4B's 8 KV-heads × 128 head-dim).
- no temp files, no Python spawn — `session_api.embed` disposes the
  KV cache before and after so each completion is scored in isolation.
- cosine vs centroid is plain dot/sqrt-norm arithmetic via
  `L.tools.embedding_blob.cosineSimilarity`.

Centroid construction:
- read every `kagAllEmbeddings` row
- decode base64 → Buffer → Float32Array via
  `L.tools.embedding_blob.blobToFloatArray`
- skip rows whose dim doesn't match the first row's dim (log + drop)
- mean across all surviving rows via
  `L.tools.embedding_blob.meanOfFloatArrays` = the Jim centroid

Origins:
- new step (no legacy ancestor — the legacy `entropy.coffee` measured
  per-token entropy, not similarity; cosine-against-centroid is a
  modern reformulation)
- the architecture grew out of the June 22 design conversation: cache
  the chunk once at oracle time, mean-pool the prompt cache's
  last-layer V into a 1024-dim vector, reuse the same encoder at
  eval time on each completion. See `GPT/ui/agent_surface.md` step 5
  for the change-log surface that lets the agent watch this populate

Invariants:
- graceful empty-corpus path: if `kagAllEmbeddings` is empty (oracle
  hasn't been re-run since the kag_embeddings table was added), emits
  a placeholder `{available: false, reason: ...}` and exits cleanly.
  Does NOT throw. `judge_run_ite` detects the missing `by_variant`
  and falls back to distinct2
- all kept embeddings must have the same dim; dim mismatches are
  logged with the offending `story_id/chunk_index` and dropped
- empty completions get `cosine = 0` (no encoding attempted; saves
  the MLX call)
- per-completion failures (cache_prompt error, decode error) get
  `cosine = 0` plus an `error` field on that row's `per_completion`
  entry — the step continues; one bad row doesn't abort the eval

Known pitfalls:
- one cache_prompt MLX call per completion. For 5 prompts × 2 variants
  = 10 calls, ~15-30 s each on Apple Silicon → ~2-5 min added to
  every eval run. Linear in completion count
- the encoder model is the BASE quantized model regardless of which
  variant produced the text. We're measuring "does this READ as Jim"
  in the base model's representation space, not "does the adapter
  produce something similar to its own training trajectory." If you
  want the latter signal (adapter-encoded comparison), set
  `adapter_path: '{BASE}/build/adapter'` in the override — but be
  aware the centroid was built without an adapter, so the cosine
  geometry shifts
- centroid quality is bounded by corpus coverage. Yesterday's probe
  populated 5 embeddings for 1 story; the full writediary corpus
  (~850 chunks across 169 stories) gives a stable centroid. Below
  ~50 chunks the centroid wobbles
- temp cache file path uses `process.pid + i` to avoid collisions
  across concurrent runs; safe in practice. If multiple processes
  share `/tmp` aggressively, add a uuid
- the chat-template wrapping that `cache_prompt` applies (user-role
  markers) means the embedding is "the chunk-as-a-user-message," not
  the chunk in isolation. Identical wrapping on the eval side keeps
  cosines comparable. The geometry is consistent, not pure
