Tool: `tools/embedding_blob.coffee`  (reached as `S.tools.embedding_blob`)
Used by: `scripts/kag_oracle_ite/oracle_ask_sqlite.coffee`,
         `scripts/eval_ite/voice_similarity_ite.coffee`

Purpose:
- SQLite BLOB glue and cosine math for the 1024-dim Float32 embeddings
  that `L.callLLM({op:'embed'})` produces. Four small helpers, all
  pure CoffeeScript, no npm dependency.

Why it exists:
- both producers (oracle, writing embeddings into `kag_embeddings`)
  and consumers (voice_similarity, comparing completion embeddings
  to a centroid) need the same primitives. Centralizing keeps the
  byte-level concerns out of the step scripts.

History (2026-07-24 rename):
- previously `tools/cache_embedding.coffee`, holding a full
  safetensors-reader chain (`readSafetensors`, `bf16BufferToFloat32`,
  `extractLastLayerV`, `meanPoolLastLayerV`, `embeddingFromCacheFile`)
  for pulling embeddings out of `mlx_lm cache_prompt` output files.
- All of that was dead-code'd when the oracle and eval steps moved
  to `L.callLLM({op:'embed'})`, which returns a `Float32Array`
  directly. The safetensors dance is gone from every hot path in
  this repo.
- The four surviving helpers were extracted into
  `tools/embedding_blob.coffee`; the old file (and its sibling
  `tools/tmp_file.coffee`, which minted the tmp safetensors paths)
  were deleted.

Location and naming:
- canonical file sits at `tools/embedding_blob.coffee` at the repo
  root (the `EXEC` tier — `node_modules/@jahbini/pipeline/tools/...`
  when the runner is installed as a package).
- step scripts never name the path. They reach the tool through the
  per-step ledger:
  `S.tools.embedding_blob.floatArrayToBlob(arr)` (or
  `L.tools.embedding_blob.…` if the script binds the ledger as `L`).
- the runner's `createToolsProxy` resolves the tool name with
  CWD↠BASE↠EXEC shadowing on first reference, then caches the loaded
  module within that step. To override the tool for a single pipe,
  drop `tools/embedding_blob.coffee` into that pipe's CWD; it wins
  for that pipe alone without forking the runner or the step.

Surface:

| function | what it does |
|---|---|
| `floatArrayToBlob(arr)` | `Buffer` view of the Float32Array's bytes — store as SQLite BLOB |
| `blobToFloatArray(buf)` | inverse — alignment-safe (copies into a fresh ArrayBuffer to guarantee 4-byte alignment) |
| `meanOfFloatArrays(arrs)` | per-position mean → centroid (voice fingerprint) |
| `cosineSimilarity(a, b)` | scalar in `[-1, 1]`, order-invariant, returns 0 on either-zero vector |

Where the embeddings come from now:
- **producer path**: `L.callLLM({op:'embed', modelDir, prompt, ...})`
  in `mlx/session_api.coffee` runs the prompt through the model once,
  extracts last-layer V from `llm.kvCache`, mean-pools across the
  prompt's `seq` axis, returns `{embedding: Float32Array(1024)}`.
  Same last-layer-V mean-pool shape the old safetensors path
  produced — in-process, no disk detour.
- **downstream storage**: oracle serializes via `floatArrayToBlob`
  into the `kagEmbeddingRegister{...}.json` request key which the
  sqlite meta writes as a BLOB column in `kag_embeddings`.
- **downstream retrieval**: voice_similarity_ite reads BLOBs from
  `kag_embeddings` via the `kagAllEmbeddings.jsonl` request key,
  decodes each with `blobToFloatArray`, averages them with
  `meanOfFloatArrays` to build the Jim centroid, then scores each
  completion's embedding against it with `cosineSimilarity`.

Invariants:
- everything in pure CoffeeScript, no npm dependency
- bit-exact roundtrip through `floatArrayToBlob` / `blobToFloatArray`
- cosine is order-invariant (`cos(a,b) == cos(b,a)`) and returns 0
  for either-zero vector

Known pitfalls:
- `Buffer.from(arr.buffer, byteOffset, byteLength)` aliases memory —
  do not mutate the source `Float32Array` after handing the buffer
  to SQLite, or the row's value mutates with it. `blobToFloatArray`
  COPIES into a fresh ArrayBuffer to dodge an analogous concern on
  the read side.
- centroid math assumes all input arrays are the same length; a
  dim mismatch throws.
