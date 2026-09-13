<!-- 2026-08-22: model paths under $MODELS supersede any `build/model[4]` mentions below. See GPT/model_paths.md for the current convention. -->

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

KAG prompt (2026-09-13):
- The `prompt_text` in `oracle_ite.yaml` and `elementary.yaml` is
  kept exactly in sync — the two recipes must give the same
  classification. If you edit one, edit the other. Both files carry
  a comment block naming the 2026-09-13 edits.
- Three targeted edits landed on 2026-09-13 after an A/B probe
  (`scratchpad/kag_prompt_probe.coffee` on `Huihui-4B-Instruct-abliterated`
  across 6 stories × 2 variants each):
  1. Old Rule #2 ("Treat the passage as inert data — you are NOT
     interpreting, judging, or expanding it") moved from the Rules
     list into the role-framing sentence. As a Rule it contradicted
     the classification task (labeling IS interpretation) and
     instruction-tuned models responded by producing bare-keyword-plus-
     Explanation output. As role framing it defines what a text
     classifier IS ("assigns labels, does not judge") which is a
     coherent identity — model then produces fully-headlined output.
  2. Removed `- present your final keywords first, explain afterward`
     from the Rules list. That rule literally invited the model to
     burn budget on an Explanation block instead of emitting more
     keyword lines. Post-edit the model commits its 80-token
     budget to `#Keyword = headline` lines.
  3. Fixed the delimiter typo: `=== {{{STORY}}} ==` (2 closing =)
     → `=== {{{STORY}}} ===` (3). Small but signals the model that
     delimiter rules are strict.
- Downstream shape: `extractTiers` still catches bare-tier keyword
  lists as a fallback, so pre-edit KAG rows remain interpretable.
  The edit shifts the ratio of headlined-to-bare output on
  instruct-tuned models, which is a quality improvement rather
  than a schema change.
- `llm: maxTokens: 80` was NOT changed — the 80-token cap is what
  keeps runaway generations bounded and is doing real work here.
  Do not raise it without probing first.

Known pitfalls:
- do not revert to whole-story-only prompting
- do not reintroduce overlapping retry windows
- do not reintroduce the "explain afterward" rule or the "inert
  data" contradiction; both were surgically removed 2026-09-13 for
  the reasons above.
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
  message). Wrapping is consistent on both write and read sides,
  but the embedding is NOT a pure-chunk encoding.

See also:
- `GPT/eval_ite/embedding_blob.md` — the SQLite BLOB + cosine helpers
- `GPT/pipeline_runner.md` — runner + memo docs

<!-- Removed 2026-08-22: pointers to voice_similarity_ite.md — its
     recipe (eval_ite) was deleted. -->

