Tool: `tools/cache_embedding.coffee`  (reached as `S.tools.cache_embedding`)
Used by: `scripts/kag_oracle_ite/oracle_ask_sqlite.coffee`,
         `scripts/eval_ite/voice_similarity_ite.coffee`

Purpose:
- read MLX `cache_prompt` safetensors output without writing any
  Python; extract a 1024-dim Float32 embedding via mean-pool of the
  last-layer V tensor; convert to/from SQLite-friendly BLOB; do
  cosine similarity arithmetic in pure CoffeeScript.

Why it exists:
- the JS/Node side of the pipeline needs to read mlx_lm's safetensors
  output (per the conventions, we cannot author Python). The
  safetensors format is simple enough that a ~30-line custom reader
  beats pulling in a dependency
- both producers (oracle, writing embeddings into kag_embeddings) and
  consumers (voice_similarity, comparing completion embeddings to a
  centroid) need the same primitives. Centralizing them here keeps
  the byte-level concerns out of the step scripts

Location and naming:
- canonical file sits at `tools/cache_embedding.coffee` at the repo
  root (the `EXEC` tier — `node_modules/@jahbini/pipeline/tools/...`
  when the runner is installed as a package).
- step scripts never name the path. They reach the tool through the
  per-step ledger:
  `S.tools.cache_embedding.embeddingFromCacheFile(path)` (or
  `L.tools.cache_embedding.…` if the script binds the ledger as `L`).
- the runner's `createToolsProxy` resolves the tool name with
  CWD↠BASE↠EXEC shadowing on first reference, then caches the loaded
  module within that step. To override the tool for a single pipe,
  drop `tools/cache_embedding.coffee` into that pipe's CWD; it wins
  for that pipe alone without forking the runner or the step.
- migration: was originally at `scripts/_helpers/cache_embedding.coffee`
  with `require '../_helpers/...'` from each consumer (June 22 2026).
  Moved to `tools/` + `S.tools` access on June 26 2026 to satisfy the
  "step scripts are location-anonymous" rule (see
  `GPT/CONVENTIONS.md` § "Tools").

Surface:

| function | what it does |
|---|---|
| `readSafetensors(filepath)` | returns `{header, blob}` — JSON header parsed, binary blob as a Buffer view of the data section |
| `sliceTensorBytes(parsed, name)` | bytes of one named tensor via `header[name].data_offsets` |
| `bf16BufferToFloat32(buf)` | converts a BF16 buffer to a Float32Array. `bf16 << 16 >>> 0` reinterpret — BF16 is the top 16 bits of an IEEE 754 Float32 |
| `lastLayerIndex(parsed)` | largest integer prefix of any tensor name (cache_prompt names tensors `<layer>.0` for keys, `<layer>.1` for values) |
| `extractLastLayerV(parsed)` | returns `{values: Float32Array, shape: [1, kv_heads, seq_len, head_dim]}` |
| `meanPoolLastLayerV(tensor)` | mean across `seq_len`; returns `Float32Array` of length `kv_heads × head_dim` |
| `embeddingFromCacheFile(path)` | full pipeline: file path → 1024-dim Float32Array |
| `floatArrayToBlob(arr)` | `Buffer` view of the Float32Array's bytes — store as SQLite BLOB |
| `blobToFloatArray(buf)` | inverse — alignment-safe (copies into a fresh ArrayBuffer to guarantee 4-byte alignment) |
| `cosineSimilarity(a, b)` | scalar in `[-1, 1]` |
| `meanOfFloatArrays(arrs)` | per-position mean → centroid |

Safetensors layout (verified by `test.sh`'s `cache_prompt_probe`):
- first 8 bytes: little-endian u64 = JSON header length N
- next N bytes: JSON header, mapping tensor name → `{dtype, shape, data_offsets: [start, end]}`
- remaining bytes: binary blob, offsets are relative to the start of
  this blob (NOT the file)
- cache_prompt produces 2 tensors per layer: `<layer>.0` (K) and
  `<layer>.1` (V). For Qwen3-4B: 36 layers → 72 tensors. Each shape
  `[1, 8, seq_len, 128]`, dtype `BF16`

Embedding choice (why last-layer V, why mean-pool):
- V is the "content" projection of attention; per the QKV intuition
  it's what gets retrieved when something attends to a position. K
  is the "find me by this signature" projection — closer to a
  retrieval index. For document-level voice similarity, V is the
  more natural choice
- last layer carries the most semantic information; intermediate
  layers carry more syntactic/positional structure
- mean across seq_len pools per-position vectors into one
  document vector. Last-token-pool is the other common choice (the
  last position has accumulated info from everything before it in a
  causal model); for our chunk-level voice scoring the mean is more
  stable across different chunk lengths
- per-head dimensions are flattened (kv_heads × head_dim) rather than
  averaged; preserves per-head specialization information that
  cosine can exploit

Invariants:
- everything in pure CoffeeScript with `require 'fs'` only. No npm
  dependency beyond what's already in the runner's `package.json`
- bit-exact roundtrip through `floatArrayToBlob` / `blobToFloatArray`
  (verified by yesterday's helper smoke)
- cosine is order-invariant in its arguments (cos(a,b) == cos(b,a))
  and returns 0 for either-zero vector

Known pitfalls:
- F16 dtype is not yet supported. If MLX ever switches the cache to
  F16 by default, add a small `f16BufferToFloat32` (the half-float
  arithmetic is in `Math.fround` family but needs explicit
  exponent/mantissa handling — ~15 lines)
- F32 dtype IS supported (rare, but cache_prompt has flags that could
  produce it)
- BF16 conversion uses `>>> 0` to force unsigned shift; without it
  the high bit flips negative in JS's 32-bit signed integer semantics
  and the resulting float is wrong
- `Buffer.from(arr.buffer, byteOffset, byteLength)` aliases memory —
  do not mutate the source `Float32Array` after handing the buffer
  to SQLite, or the row's value mutates with it. `blobToFloatArray`
  COPIES into a fresh ArrayBuffer to dodge an analogous concern on
  the read side
- the `lastLayerIndex` helper assumes tensor names start with `<int>.`
  — true for cache_prompt output, not necessarily true for other
  safetensors files. If you ever want to read mlx_lm checkpoints,
  use a different layer-pick strategy
