Step: `oracle_ask_sqlite`
Recipe: `oracle_ite`

Purpose:
- classify SQLite-backed story text into KAG emotion entries
- ALSO populate per-chunk voice embeddings into `kag_embeddings`
  via the cache_prompt forward pass (June 2026; see "Embedding
  pipeline" below)

Inputs:
- meta read `storiesMissingKag.jsonl`
- params `prompt_text`, `batch_size`, `model_dir`
- optional `adapter_path`
- optional `mlx` object, which is passed through to MLX (with a
  cmdType-aware whitelist — see "MLX flag whitelisting")

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

Embedding pipeline (June 2026):
- `runOracleOnce` no longer calls `mlx_lm generate` directly. It now
  does a two-step dance per chunk:
  1. `S.tools.tmp_file.make 'oracle_cache', 'safetensors'` mints a
     unique tempdir path, then `L.callMLX 'cache_prompt'` writes the
     prompt's K/V cache to it
  2. `S.tools.cache_embedding.embeddingFromCacheFile cacheFile` reads
     that file, extracts last-layer V, mean-pools across `seq_len` →
     1024-dim Float32 embedding for the chunk
  3. `L.callMLX 'generate'` with `--prompt-cache-file <same file>`
     continues from the cached K/V to produce the emotion output —
     one forward-pass cost for both outputs
- the embedding is persisted via
  `kagEmbeddingRegister{<story_id>|<chunk_index>}.json` at the same
  point the kag entries are saved
- only the FIRST attempt's embedding is canonical. Retry attempts
  use sub-chunks (noisier voice signal) and don't write embeddings
- temp safetensors files are deleted after read (`fs.unlinkSync` in
  try/catch; stragglers in `/tmp` are harmless)
- if embedding extraction fails for any reason, oracle generation
  still proceeds — the failure is logged but does NOT abort the run

MLX flag whitelisting:
- `cache_prompt` does NOT accept `--max-tokens`, `--temp`, etc. —
  it's a no-generation pass. The runner's `mlxAllowedFlags[cmdType]`
  filter (see `GPT/pipeline_runner.md`) intercepts the step's `mlx:`
  block and only forwards flags `cache_prompt` accepts:
  `max-kv-size, kv-bits, kv-group-size, quantized-kv-start,
  trust-remote-code, eos-token, adapter-path`
- `generate` continues to receive the full `mlx:` block (no
  whitelist entry = pass everything)
- adding a new MLX subcommand to a step's `mlx:` block requires
  updating `mlxAllowedFlags` for that cmdType if it's pickier than
  generate

Invariants:
- `batch_size` must be present and a positive integer
- recipe `mlx` limits actually reach every generate call (preserved
  by the cmdType-aware whitelist)
- failures should increment oracle fail count so hard stories move to the end
- success should reset oracle fail count for that story
- embedding persistence is best-effort: a missing/failing
  `kag_embeddings` write does not affect kag-entry correctness

KAG shape:
- entries now carry `chunk_index`
- paragraph range is stored in `paragraph_index`

`kag_embeddings` shape (new table):
- `(story_id, chunk_index)` primary key
- `dim` (1024 for Qwen3-4B), `source` (`'cache_prompt/last_v_meanpool'`),
  `embedding` (Float32 BLOB), `created_at`
- INSERT/UPDATE/DELETE triggers populate `_change_log` so the agent
  surface's `/api/sqlite/diff?since=<run_id>` sees population events
- read via `kagAllEmbeddings.jsonl` (returns base64-encoded blobs;
  caller decodes via `S.tools.cache_embedding.blobToFloatArray`)

Known pitfalls:
- do not revert to whole-story-only prompting
- do not reintroduce overlapping retry windows
- if oracle OOM appears after a rebuild, inspect `base_ite`
  quantization first; a convert-only `build/model4` can look valid
  but be far too large
- the per-chunk forward pass produces a `~7 MB` safetensors temp
  file (Qwen3-4B's full K/V cache for a typical chunk). Only the
  pooled 4 KB embedding lands in SQLite; the cache file itself is
  ephemeral. Don't try to store the whole cache file — at scale
  (169 stories × 5 chunks) that's gigabytes
- backfilling embeddings on an existing corpus that already has
  kag_entries: the missing-KAG query won't surface those stories,
  so re-running oracle_ite does nothing. Two paths exist (neither
  shipped yet): delete the story's kag_entries to force re-extraction
  (see test.sh's `oracle_one_story` probe), or write a separate
  `backfill_kag_embeddings` step that walks existing kag_entries and
  only runs cache_prompt for each chunk. The second is cheaper but
  is future work
- voice signal in the embedding inherits the chat-template wrapping
  cache_prompt applies (the chunk becomes a `<|im_start|>user`
  message). For voice-similarity comparisons this is consistent —
  the eval side wraps the same way — but the embedding is NOT a
  pure-chunk encoding. See `GPT/eval_ite/voice_similarity_ite.md`

See also:
- `GPT/eval_ite/cache_embedding.md` — the safetensors+pool helper
- `GPT/eval_ite/voice_similarity_ite.md` — the consumer that uses
  these embeddings to build the Jim centroid + score completions
- `GPT/pipeline_runner.md` § "Stable run IDs + the SQLite `runs`
  table" — the cmdType-aware mlx flag whitelist lives there
