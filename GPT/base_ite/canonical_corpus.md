# canonical_corpus.sqlite — the frozen model-agnostic corpus annotations

**File**: `writer/data/canonical_corpus.sqlite` (both machines; keep equal).
**Importer**: `importCanonicalCorpus{force?}` meta request (`meta/sqlite.coffee`),
driven by `base_ite/import_canonical_corpus_ite.coffee` — elementary's first step
AND (since 2026-11-09) newborn's seed step (`config/newborn.yaml` replaced the
stale `seed_story_sqlite`/`data/stories.md` ingest with it). The import resolves
`<BASE>/data/canonical_corpus.sqlite` then `~/writer/data/canonical_corpus.sqlite`
— no per-pipe `data/` symlink needed. Lifecycle context: `writer/GPT/story/certificate.md`.

## Tables (as of 2026-11-07)

| table | rows | role |
|---|---|---|
| `stories` | 169 | jim.md stories (fill-if-missing on import) |
| `kag_entries` | 4371 | keyword/headline per chunk (wholesale replace) |
| `story_simplifications` | 169 | whole-story plain retellings (replace) |
| `chunk_simplifications` | 821 | per-CHUNK plain retellings (replace) — **the PROMPT half of LoRA training rows** (`build_lora_dataset_ite`) |

`corpus_meta.corpus_version` = `jim:<md5>|src:<donor pipe>|…` — ANY change
to the string triggers per-pipe reimport (pipes stamp `imported_version` in
`corpus_import_meta`; `{force}` overrides).

## The 2026-11-07 gap incident (why chunk_simplifications is called out)

The original 2026-11-06 canonical build captured story_simplifications but
NOT chunk_simplifications. First pipe through the canonical path with no
legacy local rows (8b-base) → `build_lora_dataset_ite` skipped all 169
stories ("no chunk_simplifications rows yet") → **zero training rows**, and
run_lora_train_ite started loading the model anyway. Fixed same day:
copied the table from the donor pipe named in corpus_meta
(`hf__qwen__qwen3-4b-instruct-2507`, 821 rows), bumped the version
(`|chunk_simpl:821`), extended the importer (guarded — a pre-fix canonical
file without the table still imports the rest). Verified live on 8b-base
via `/api/sqlite/importCanonicalCorpus.json`.

## Rebuild guidance

When jim.md changes: rebuild on the big model once — and the build MUST
produce all FOUR tables (the oracle pass yields kag_entries AND
chunk_simplifications; the simplify pass yields story_simplifications).
Set `corpus_meta.corpus_version` to a new string. Copy the file to both
machines. Pipes reimport automatically on their next elementary.
