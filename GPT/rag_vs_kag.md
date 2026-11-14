# Chunking (RAG) ELIMINATED — KAG is the retrieval mechanism

**jahbini directive, 2026-11-07**: the chunk/RAG machinery was invented by
a past Claude session, not by his directive; it brings no advantage over
KAG and its per-model compute cost is not worth it. "Please remove
chunking." Removed completely — scripts, recipes, meta keys, and the
generation-time options.

## The analysis that preceded the ruling (same day)

- The chunks were per-chunk vectors made by EACH pipe's own model
  (mean-pooled last-layer V from the KV cache) — hours of forward passes
  per model (`reembed_chunks_clean` inside `elementary.yaml`; the 8B case
  needed 16GB and saturated the mini on 2026-11-06).
- The expensive `kag_embeddings_clean` table had NO always-on consumer:
  storacle's `use_chunks` defaulted FALSE; `generate_prompt_llm`'s
  `rag_top_k` defaulted 0; eval's voice_cosine uses the OTHER table
  (`kag_embeddings`, the oracle's byproduct) and is untouched.
- KAG rows (keyword, headline per chunk — LLM-curated, now canonical via
  `data/canonical_corpus.sqlite`) already provide curated retrieval; the
  homebrew embedding's marginal recall was never validated.
- Architectural note kept for the record: RAG never REQUIRED per-model
  embeddings — that was an implementation coupling (embedder = generator).
  If semantic retrieval is ever wanted again, the right shape is ONE fixed
  small embedder, corpus embedded ONCE canonically, query embedded with
  the same small model at ask-time. Do NOT resurrect the per-model form.

## What was removed (2026-11-07, all compile/yaml-checked)

**Deleted files:**
- `pipeline/scripts/prompt_llm/reembed_chunks_clean.coffee`
- `writer/config/reembed_clean.yaml`
- `puppeteer/config/reembed_scan.yaml`
- `puppeteer/scripts/reembed_queue_gen.coffee`

**Edited:**
- `pipeline/config/elementary.yaml` — reembed step + artifact gone;
  `select_lora_stories_ite` now depends on `import_canonical_corpus_ite`.
- `pipeline/scripts/storacle/storacle.coffee` + `config/storacle.yaml` —
  `use_chunks`/`rag_top_k`/retrievePassages gone; `use_kag` stays.
- `pipeline/scripts/prompt_llm/generate_prompt_llm.coffee` +
  `writer/config/prompt_llm.yaml` — the whole RAG path gone.
- `pipeline/meta/sqlite.coffee` — request keys `kagEmbeddingCleanRegister`,
  `kagAllCleanEmbeddings`, `storiesMissingCleanEmbeddings` gone (table DDL
  + reset DELETEs KEPT for schema compatibility with existing DBs).
- `pipeline/ui/pipe_inventory.coffee` — reembed/emb_clean sqlite queries
  gone; TSV columns kept as `-`/`0` placeholders (position stability).
- `puppeteer/scripts/sat_queue_gen.coffee` — SAT elementary = 6 entries
  (baseline/kag/adapter × B,D); `adapter_chunks` config gone.
- `puppeteer/scripts/hf_queue_gen_ite.coffee` — legacy chain is
  reset → oracle_ite → train_lora; reembed probe/skip-map gone.
- `puppeteer/scripts/queue_run_ite.coffee` — reembed verifier + straggler
  check gone.
- `puppeteer/config/run_queue.yaml` (queue entry), `sat_scan.yaml`
  (rag_top_k) — gone.

**Deliberately kept:**
- `kag_embeddings` (oracle byproduct) + `kagAllEmbeddings` key +
  voice_cosine eval — a DIFFERENT feature (same-model voice scoring),
  not retrieval. Flag: with KAG canonical, new pipes may not populate it;
  voice_cosine degrades to null gracefully.
- Existing `kag_embeddings_clean` DATA in pipe sqlites — inert, not
  dropped (no destructive data deletion); reclaim space manually if ever
  desired.
- `writer/ui/project.coffee` storacle_observations columns + the
  `chunks(top-N)` badge in plugin.js — HISTORY display for old runs; new
  runs write use_chunks=0 naturally.
- `elementary.yaml.pre-canonical.bak` — historical reference.

## Sync status
Laptop-only at removal time (mini off-limits). At mini cutover: sync the
edited files AND `rm` the four deleted ones on the mini (rsync won't
delete them). List mirrored in `~/claude_zone/nov_7/MEMORY_KNOWLEDGE.md`.
