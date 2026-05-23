Step: `oracle_ask_sqlite`
Recipe: `oracle_ite`

Purpose:
- classify SQLite-backed story text into KAG emotion entries

Inputs:
- meta read `storiesMissingKag.jsonl`
- params `prompt_text`, `batch_size`, `model_dir`
- optional `adapter_path`
- optional `mlx` object, which must be passed through to MLX generate

Outputs:
- artifact `new_story_ids`
- artifact `oracle_remaining_count`
- artifact `kag_rejects`
- artifact `kag_viewed`
- meta write `kagFor{story_id}.json`
- meta write `oracleFailureFor{story_id}.json`

Current segmentation:
- process story text in 5 paragraph groups when paragraph count >= 5
- if paragraph count < 5, use one full group containing all paragraphs

Retry behavior:
- if a group-level full prompt fails, retry that group in smaller paragraph chunks
- chunk retry is sequential, not sliding
- prefer 3 paragraphs under 1024 chars, then 2, then 1 whole paragraph

Invariants:
- `batch_size` must be present and a positive integer
- recipe `mlx` limits must actually be passed into every generate call
- failures should increment oracle fail count so hard stories move to the end
- success should reset oracle fail count for that story

KAG shape:
- entries now carry `chunk_index`
- paragraph range is stored in `paragraph_index`

Known pitfalls:
- do not revert to whole-story-only prompting
- do not reintroduce overlapping retry windows
- if oracle OOM appears after a rebuild, inspect `base_ite` quantization first; a convert-only `build/model4` can look valid but be far too large
