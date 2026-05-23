Step: `collect_diary_kag_ite`
Recipe: `diary_ite`

Purpose:
- collect DB-backed KAG chunk matches for the chosen diary event emotions

Inputs:
- artifact `story_parts`
- params:
  - `scene_emotion`
  - `arrival_emotion`
  - `disturbance_emotion`
  - `reflection_emotion`
  - `realization_emotion`
  - `per_event_match_limit`

Outputs:
- artifact `diary_kag`

Current matching mode:
- SQLite is authoritative for KAG matching
- match by `kag_entries.keyword`
- use DB-returned `story_id` and `chunk_index`
- use DB-returned `chunk_text`, `start_paragraph`, and `end_paragraph` when present
- fall back to local regrouping only for legacy rows that do not yet have stored chunk text
- each contributing source `story_id` may appear at most once across the whole diary prompt

Important KAG fields:
- `keyword`
- `headline`
- `chunk_index`
- `paragraph_index`
- `start_paragraph`
- `end_paragraph`
- `chunk_text`

Why `chunk_index` matters:
- diary prompts must use the exact DB-chosen chunk, not a heuristic substitute

Current payload shape:
- `diary_kag.events.<kind>.selected_emotion`
- `diary_kag.events.<kind>.matches[]`
- flat `diary_kag.entries` remains as a compatibility summary

Known pitfalls:
- do not require `story_parts.story_id`; diary selection is now driven by explicit event keys, not a legacy preset story id
- do not reintroduce `pretend_story_ids`
- do not invent chunk identity outside the DB KAG rows
- if diary chunk text looks inconsistent with oracle indexing, rerun oracle so legacy rows are rewritten with stored chunk data
