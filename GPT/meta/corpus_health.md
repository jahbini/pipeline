Meta request: `corpusHealth.json`
Schema home: `meta/sqlite.coffee` (search `name: 'corpusHealth'`)
Producer: read-only — computed from `stories`, `kag_entries`,
`kag_embeddings`, `runs`, `evaluations` at read time.

## Purpose

Single-object summary of "is the corpus in a state worth evaluating
against?" The advice loop's first read each turn — answers the
preconditions for every downstream recommendation:

- Is voice_similarity trustworthy? (`kag_embeddings_total` and
  `kag_chunks_without_embedding` together tell you what fraction of
  the corpus has voice signal.)
- Is oracle behind? (`stories_missing_kag > 0` means there's work to
  do before scoring is honest.)
- Is the emotion mix skewed? (`per_emotion_chunk_count` reveals
  whether the centroid is dominated by one keyword.)
- Is there history to reason from? (`evaluations_total == 0` means
  no prior runs — any recommendation is a guess.)

## Shape

```json
{
  "as_of":                       "2026-06-26T10:30:00.000Z",
  "stories_total":               169,
  "stories_with_kag":            158,
  "stories_missing_kag":         11,
  "kag_entries_total":           754,
  "kag_chunks_distinct":         620,
  "kag_embeddings_total":        598,
  "kag_chunks_without_embedding": 22,
  "per_emotion_chunk_count":     {"Joy": 312, "Sadness": 87, ...},
  "embedding_dim":               1024,
  "embedding_source":            "cache_prompt/last_v_meanpool",
  "evaluations_total":           14,
  "runs_total":                  19
}
```

| field | meaning |
|---|---|
| `as_of` | ISO timestamp at read time (the table values are point-in-time aggregations; this is when they were computed) |
| `stories_total` | `COUNT(*) FROM stories` |
| `stories_with_kag` | `COUNT(DISTINCT story_id) FROM kag_entries` |
| `stories_missing_kag` | `stories_total − stories_with_kag` |
| `kag_entries_total` | `COUNT(*) FROM kag_entries` — every individual emotion row |
| `kag_chunks_distinct` | `COUNT(DISTINCT story_id || '|' || chunk_index) FROM kag_entries WHERE chunk_index IS NOT NULL` — how many unique chunks the oracle has processed |
| `kag_embeddings_total` | `COUNT(*) FROM kag_embeddings` |
| `kag_chunks_without_embedding` | distinct chunks present in `kag_entries` but with no matching row in `kag_embeddings` — usually 0 after a clean run, > 0 only when oracle re-ran without `cache_prompt` (older code path) |
| `per_emotion_chunk_count` | `{keyword: count, ...}` from `GROUP BY keyword`, sorted by count desc |
| `embedding_dim`, `embedding_source` | sampled from one row of `kag_embeddings`; null when the table is empty |
| `evaluations_total`, `runs_total` | row counts for the agent-surface tables |

## How the advice loop uses it

Suggested flow (status-1 Claude, first read each turn):

1. `corpusHealth.json` → decide whether voice signal is reliable
   (`kag_embeddings_total / kag_chunks_distinct ≥ 0.95`).
2. `evaluationLatest.json` → get the most recent verdict.
3. `evaluationsByPromptHash{<latest.eval_prompts_hash>}.jsonl` →
   pull comparable history.
4. Reason; write recommendation to `GPT/advice/<date>.md`.

If step 1 fails (insufficient embedding coverage), the recommendation
is "re-run oracle to populate embeddings before tuning anything else"
— not a hyperparam tweak.

## Cost

A handful of `COUNT(*)` queries plus one `GROUP BY keyword`. With the
WAL we enabled this session, the read is non-blocking and cheap
(~ms even on large corpora). Safe to call every turn.

## Known caveats

- Counts are point-in-time. If something else is mid-write (extremely
  unlikely with the runner's single-writer pattern) you may see a
  snapshot mid-transaction. WAL means you're reading the last committed
  snapshot, so the values are always consistent — just possibly stale
  by a few seconds.
- `embedding_dim` is sampled from one row. If you ever ran two oracle
  passes with different model sizes (producing different dims), the
  sample is one of them at random. Realistically the corpus dim is
  fixed per project, so this is a non-issue.
- `per_emotion_chunk_count` counts ENTRIES not CHUNKS — one chunk can
  have multiple keyword entries (joy + neutral, say). If you want
  chunk-level emotion coverage, that needs a different request.
