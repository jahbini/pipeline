Step: `oracle_ask_sqlite`
Recipe: `oracle_ite`

Purpose:
- classify SQLite-backed story text into KAG emotion entries
- ALSO populate per-chunk voice embeddings into `kag_embeddings`
  via the in-process `L.callLLM({op:'embed'})` forward pass (July
  2026 port; see "Embedding pipeline" below)

Inputs:
- meta read `storiesMissingKag.jsonl`
- params `prompt_text`, `batch_size`, `model_dir`
- optional `adapter_path`
- optional `llm` object (or legacy `mlx` fallback), passed through
  to `L.callLLM({op:'generate'})` — kebab-case keys from the legacy
  `mlx:` shape get mapped to camelCase by `buildGenerateOpts`

Outputs:
- artifact `new_story_ids`
- artifact `oracle_remaining_count`
- artifact `kag_rejects`
- artifact `kag_viewed`
- meta write `kagFor{story_id}.json` (emotion entries)
- meta write `kagEmbeddingRegister{story_id|chunk_index}.json`
  (1024-dim Float32 embedding per chunk, as SQLite BLOB)
- meta write `oracleFailureFor{story_id}.json`

Current segmentation:
- process story text in 5 paragraph groups when paragraph count >= 5
- if paragraph count < 5, use one full group containing all paragraphs

Retry behavior:
- if a group-level full prompt fails, retry that group in smaller paragraph chunks
- chunk retry is sequential, not sliding
- prefer 3 paragraphs under 1024 chars, then 2, then 1 whole paragraph

Embedding pipeline (2026-07-24 port):
- `runOracleOnce` makes two `L.callLLM` calls per chunk, both
  in-process (no Python spawn, no temp files):
  1. `L.callLLM({op:'embed', modelDir, prompt, adapterPath?})` runs
     the prompt through the model once, extracts last-layer V from
     `llm.kvCache`, mean-pools across `seq_len` → 1024-dim
     `Float32Array` for the chunk. Returns `{embedding, promptTokens, dim}`.
  2. `L.callLLM({op:'generate', modelDir, prompt, raw:true, adapterPath?, ...llmOpts})`
     produces the emotion classification text.
- both calls are cold-KV per chunk (session_api.embed disposes the
  cache before and after; generate then re-prefills fresh). This is
  the human-directed isolation rule: no cross-story context.
- the embedding is persisted via
  `kagEmbeddingRegister{<story_id>|<chunk_index>}.json` at the same
  point the kag entries are saved, serialized via
  `S.tools.embedding_blob.floatArrayToBlob`
- only the FIRST attempt's embedding is canonical. Retry attempts
  use sub-chunks (noisier voice signal) and don't write embeddings
- if embedding extraction fails for any reason, oracle generation
  still proceeds — the failure is logged but does NOT abort the run

`llm:` (or legacy `mlx:`) block handling:
- the step reads `L.param('llm', null) ? L.param('mlx', null)` — the
  new-door name is preferred; the old kebab-case `mlx:` shape is
  accepted for unmigrated overrides
- `buildGenerateOpts` maps kebab keys to camelCase (`max-tokens` →
  `maxTokens`, `temp` → `temperature`, etc.) and silently drops
  session-level keys that don't apply per-call (e.g. `max-kv-size`
  — session KV cap is set via `mx.setCacheLimit` in `session_api`,
  not per generate)
- the mlx-cli flag whitelist that used to live in the runner (cmdType-
  aware `mlxAllowedFlags`) is not part of this path — `callLLM` params
  are typed, not argv-shaped, and unknown keys just get passed through
  to `session.generate(gopts)`

Invariants:
- `batch_size` must be present and a positive integer
- recipe `llm:` limits reach every generate call directly (no
  argv-translation layer to lose them)
- failures should increment oracle fail count so hard stories move to the end
- success should reset oracle fail count for that story
- embedding persistence is best-effort: a missing/failing
  `kag_embeddings` write does not affect kag-entry correctness

KAG shape:
- entries now carry `chunk_index`
- paragraph range is stored in `paragraph_index`

`kag_embeddings` shape (new table):
- `(story_id, chunk_index)` primary key
- `dim` (1024 for Qwen3-4B), `source`
  (post-port: whatever the step sets; typically `'callLLM/embed/last_v_meanpool'`),
  `embedding` (Float32 BLOB), `created_at`
- INSERT/UPDATE/DELETE triggers populate `_change_log` so the agent
  surface's `/api/sqlite/diff?since=<run_id>` sees population events
- read via `kagAllEmbeddings.jsonl` (returns base64-encoded blobs;
  caller decodes via `S.tools.embedding_blob.blobToFloatArray`)

Known pitfalls:
- do not revert to whole-story-only prompting
- do not reintroduce overlapping retry windows
- if oracle OOM appears after a rebuild, inspect `base_ite`
  quantization first; a convert-only `build/model4` can look valid
  but be far too large
- the in-process embed path holds one prompt's KV cache in RAM
  during the forward pass; `session_api.embed` disposes it before
  and after. If a chunk is huge, GPU memory can spike briefly
  during prefill — this is the same working-set that generation
  would use, so if generate works on the chunk, embed will too.
- backfilling embeddings on an existing corpus that already has
  kag_entries: the missing-KAG query won't surface those stories,
  so re-running oracle_ite does nothing. Two paths exist (neither
  shipped yet): delete the story's kag_entries to force re-extraction
  (see test.sh's `oracle_one_story` probe), or write a separate
  `backfill_kag_embeddings` step that walks existing kag_entries and
  only runs the embed op for each chunk. The second is cheaper but
  is future work.
- voice signal in the embedding inherits the ChatML wrapping
  `session_api.embed` applies (the chunk becomes a `<|im_start|>user`
  message). For voice-similarity comparisons this is consistent —
  the eval side wraps the same way via `raw:true` on the same prompt
  — but the embedding is NOT a pure-chunk encoding. See
  `GPT/eval_ite/voice_similarity_ite.md`.

See also:
- `GPT/eval_ite/embedding_blob.md` — the SQLite BLOB + cosine helpers
- `GPT/eval_ite/voice_similarity_ite.md` — the consumer that uses
  these embeddings to build the Jim centroid + score completions
- `GPT/pipeline_runner.md` — runner + memo docs
