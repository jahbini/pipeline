# Legacy pipeline (`~/development/pipeline`) — inventory

The pre-`_ite` pipeline that the current `@jahbini/pipeline` package
descended from. Last meaningful activity was March 2026; sits idle now
but contains evaluation machinery that **we do not yet have in the
modern package** and want to bring forward.

## Historical workflow

> One test per day. After several days pass, the evaluator picks the
> best one.

```
~/development/pipeline/daily/2026-01-04/
  experiment.yaml             # full recipe snapshot for that day
  out/                        # generations + ablations
  eval_out/                   # analysis.json, summaries
  build/adapter/              # the day's trained adapter
~/development/pipeline/daily/2026-01-05/
  ...same shape...
```

After N days, run `judging_finalizer.coffee daily/` →
- iterates each subdirectory
- runs `pipeline_evaluator.coffee` inside it (the "eval recipe")
- reads `eval_out/analysis.json`
- scores via `(distinct2_mean × 100) − (mem_sub_rate × 50)`
- ranks runs, picks a 🏆 Champion, writes `final_scores.json` +
  `final_report.md` at the root of `daily/`.

The granularity: **one adapter per day, evaluated as a whole**.
In our modern pipeline this maps to **one evaluation per training-cycle**
(per `lora_training_runs.run_id`), and the "after several days" step
becomes a separate `champion_ite` recipe that ranks across rows in a
new `evaluations` SQLite table.

## File map

### Top-level

| file | purpose |
|---|---|
| `pipeline_runner.coffee` | precursor to our current runner; older Memo class, fewer features |
| `pipeline_evaluator.coffee` | sibling runner for the eval recipe; "courtroom mode" iterates run subdirs; aggregates `ablation_generations_summary.csv` into `judgement_summary.json` |
| `judging_finalizer.coffee` | calls evaluator across `daily/<date>/` subdirs, scores via `(distinct2 × 100) − (mem_sub × 50)`, picks Champion, writes `final_scores.json` + `final_report.md` |
| `new_pipeline.coffee` | mid-evolution attempt at a cleaner runner |
| `notebook_step_extractor_with_io.coffee` | Oct 2025 era; the notebook → pipeline extraction tool that produced the original `_ite` steps |
| `Full-Provenance.md` | design doc: every script writes a `<output>.meta.json` sidecar with `{script, git_commit, timestamp, config_keys}`; UUID temp files for parallel safety; `dry_run` config flag; JSON-Schema input/output validation |
| `filter_hf.coffee` | standalone HuggingFace dataset filter |

### `config/`

Recipes (older style — recipe wires are by inferred topo, not explicit
`depends_on:`):

| file | what it runs |
|---|---|
| `full.yaml` | the omnibus: prepare_experiments → manifest → register → prepare_data → prepare_prompts → entropy → crawl_for_voice → sanity → examination → fuse → train. Single-model mode, varies on `seeds: [11, 22, 33]`. |
| `kag.yaml` | KAG extraction (pre-SQLite) |
| `kag_oracle.yaml` | oracle-driven KAG extraction (precursor of current `oracle_ite`) |
| `test.yaml` | smoke tests |

### `scripts/full/`  ← **the evaluation suite**

| file | desc | matters for porting? |
|---|---|---|
| **`examination.coffee`** | "Run regeneration ablations using MLX via M.callMLX" — generates completions across an artifact registry (quantized / fused / base+adapter) × prompt variants (plain / directive / fewshot) × N prompts | **YES — core eval generator** |
| **`entropy.coffee`** | "Compute per-token entropy from MLX stream_generate (memo-native)" — reads policy + prompts + artifacts, writes `entropy_tokens.jsonl` + `entropy_summary.csv` | **YES — but requires our `callMLX` to expose stream_generate / logprobs; verify before porting** |
| **`sanity.coffee`** | "Aggregate and summarize ablation results (memo-native)" — empty-rate, sentence-ending %, word-count avg/median, grouped by `model_id × artifact × prompt_variant` | **YES — but does NOT compute `distinct2_mean` or `mem_sub_rate`; those metrics are referenced by the scoring formula but their computation is missing from the repo** |
| `crawl_for_voice.coffee` | crawls celarien.com for voice training data, memo-resident | maybe later |
| `fetch_hf_dataset.coffee` | HuggingFace dataset → train/valid memo arrays | maybe later |
| `fuse.coffee` | fuses LoRA adapters + quantizes (memo-native MLX) | likely useful — we don't have an equivalent today |
| `manifest.coffee` / `register.coffee` | artifact bookkeeping; produces the `out/artifacts.json` registry (a `runs: []` array of `{model_id, quantized_dir, fused_dir, adapter_dir}`) | precursor of our `runs` table; the registry concept is now in SQLite |
| `prepare_data.coffee` | validate dataset files → `data_report.json` | low priority |
| `prepare_experiments.coffee` | materialize `experiments.csv` for LoRA training | superseded by our config + override mechanism |
| `prepare_outmd_kag.coffee` | markdown → KAG-style JSONL | pre-SQLite version of seed_story_sqlite |
| `prepare_prompts.coffee` | produce a prompt-formatting policy JSON | low priority |
| `snapshot.coffee` | prompt snapshots via MLX (memo-only) | sometimes useful |
| `train.coffee` | LoRA training driver from `experiments.csv` | superseded by `run_lora_train_ite` |

### `scripts/kag_oracle/`

Largely overlaps with our current `kag_oracle_ite/`. Differences worth knowing:

- **`direct_merge.coffee`**, **`reply_merge.coffee`**, **`rotate_merged.coffee`** — three distinct adapter-merging strategies. We don't have any of these.
- **`talk_story.coffee`** — inference-time generation against a merged model.
- The rest mirrors what's in current `kag_oracle_ite/`.

### `scripts/kagnam/` & `scripts/test/`

`kagnam/` is an experimental branch. `test/` is the teaching pipeline,
already ported into our current package's `scripts/test/`.

## Idiom differences (legacy → modern)

| concern | legacy | modern |
|---|---|---|
| ledger API | `M.theLowdown`, `M.saveThis`, `M.getStepParam stepName, "key"` (2-arg form) | `L.need`, `L.make`, `L.peek`, `L.param 'key'` (compat shim still accepts the old form) |
| step params | `(M.theLowdown "params/#{stepName}.json").value` then deconstruct | `L.param 'key'` with brace-substitution of `{BASE}/{EXEC}/{CWD}` |
| dependencies | implicit topo sort (some steps lack `depends_on:` entirely) | explicit `depends_on: [...]` required |
| artifact tracking | one big `out/artifacts.json` registry: `runs: [{model_id, quantized_dir, fused_dir, adapter_dir, ...}]`; every consumer step reads it via `M.getStepParam stepName, "artifacts"` | declared artifact keys with `target:` files + the `runs` and `lora_training_runs` SQLite tables |
| provenance | spec exists in `Full-Provenance.md` but not implemented in code | not implemented; agent surface step 5's `_change_log` provides per-row history instead |
| persistence | filesystem only; the Memo class has `enableFilePersistence` that listens for `.json`/`.csv` keys | SQLite is the long-term store, filesystem is for artifact targets, change log captures every write |

## What's in the evaluation suite that we should bring forward

The minimum useful port (the user's stated goal: bring evaluation into the
modern pipeline) needs three step scripts + two recipes + a small SQLite
schema addition:

### Step scripts (new in our package)

1. **`generate_ablations_ite.coffee`** — adapted from `examination.coffee`.
   `L.callMLX 'generate'` across `(adapter × prompt_variant × prompt)`.
   Produces `eval_out/ablations.jsonl` artifact.
2. **`summarize_ablations_ite.coffee`** — adapted from `sanity.coffee`.
   Plus newly-written computation of `distinct2_mean` and `mem_sub_rate`
   (the legacy repo references them but does not implement them).
   Produces `eval_out/ablation_summary.json`.
3. **`judge_run_ite.coffee`** — adapted from `judging_finalizer.coffee`'s
   `scoreRun`. Reads summary, applies `score = distinct2 × 100 − mem_sub × 50`,
   writes one row into a new `evaluations` SQLite table tied to the eval's
   own `run_id` and the `lora_training_runs.run_id` it evaluated.

### Recipes

- **`eval_ite.yaml`** — runs the three steps above against the **current**
  adapter. One launch = one evaluation = one row in `evaluations`.
- **`champion_ite.yaml`** — separate recipe that scans `evaluations`,
  ranks by score, writes a champion report. Equivalent to the old
  `judging_finalizer.coffee`.

### SQLite schema

A new `evaluations` table joining `runs` ↔ `lora_training_runs`:

```sql
CREATE TABLE IF NOT EXISTS evaluations (
  eval_id          TEXT PRIMARY KEY,    -- the eval run's run_id (UUID)
  evaluated_run_id TEXT,                -- the lora_training_runs.run_id being scored
  adapter_path     TEXT,
  score            REAL,
  distinct2_mean   REAL,
  mem_sub_rate     REAL,
  prompts_count    INTEGER,
  details          TEXT,                -- JSON blob: per-variant breakdown
  evaluated_at     TEXT
);
```

Plus four new meta REQUESTs: `evalRegister{<id>}.json` (write),
`evalById{<id>}.json` (read), `evalHistory.jsonl` (read), and
`evalChampions.json` (read, ranked).

Triggers on `evaluations` go into `_change_log` so the agent's
`/api/sqlite/diff` picks up evaluation rows as they appear.

## The missing pieces (knowingly absent from legacy repo)

- **No `analysis.json` schema** is committed anywhere in the legacy
  repo. The `judging_finalizer.coffee` reads `eval_out/analysis.json`
  with keys `by_mode: [{distinct2_mean, mem_sub_rate}]` but no script
  in `scripts/full/` writes that file. Either (a) a step was written
  but never committed, (b) the computation was inline-prompted from a
  notebook, or (c) it was always intended as future work. We'll have
  to write the metric computations ourselves.
- **No sample `eval_out/` directory** in the repo. No live `analysis.json`
  to crib from.

Both metrics are well-known and quick to implement:

- **distinct-2**: |unique bigrams in completions| / |total bigrams|.
  Lexical diversity. Higher = less repetitive.
- **mem_sub_rate**: fraction of completions containing a contiguous
  substring of the training corpus above some threshold (typically
  30-50 chars). Memorization signal. Higher = worse.

## Pointer index

- Legacy entry: `~/development/pipeline/`
- Evaluation drivers: `pipeline_evaluator.coffee`, `judging_finalizer.coffee`
- Evaluation steps: `scripts/full/{examination,entropy,sanity}.coffee`
- Provenance design doc (not implemented): `Full-Provenance.md`
- Adapter merging variants we don't have: `scripts/kag_oracle/{direct_merge,reply_merge,rotate_merged}.coffee`
- Voice-data crawler we don't have: `scripts/full/crawl_for_voice.coffee`
- LoRA fusion we don't have: `scripts/full/fuse.coffee`
