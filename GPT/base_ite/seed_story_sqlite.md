Step: `seed_story_sqlite`
Recipe: `base_ite`

Purpose:
- seed SQLite `stories` from `data/jim.md`

Inputs:
- artifact `stories_md`

Outputs:
- artifact `story_seed_ids`
- meta writes `storyByID{story_id}.json`

Canonical text filter:
- `clean()` in `scripts/kag_oracle_ite/seed_story_sqlite.coffee`
- HEY GPT: this older `md2segments`-style cleaner is the canonical markdown-to-plain-text filter for training-quality story ingress

Invariants:
- must work on a virgin DB
- missing `allStories.jsonl` materialization must be treated like `[]`
- story headings come from markdown lines starting with `# `
- assumes the SQLite handle is already open in the runner; upstream reset must clear tables, not unlink `runtime.sqlite`
- in current `base_ite`, this step runs after quantization; story seeding is intentionally downstream of all base-model preparation

Downstream consumers:
- `oracle_ite`
- `lora_ite`
- `diary_ite` indirectly through SQLite

Known pitfalls:
- do not add brittle pre-checks that block fresh DB seeding
- do not silently replace this filter with a broader or different cleaner
- if `base_ite` removes `runtime.sqlite` after startup, later writes can appear to run while the DB is unusable

Canonical source (2026-09-08):
- **`~/writer/data/jim.md` is the single source of truth** for the
  6,800-line jim-story corpus (171 stories, including
  `anna-played-piana-md`). Per-pipe `pipes/<pipe>/data/jim.md` should be
  a symlink to that file so a corpus update propagates automatically:
  `ln -sf ~/writer/data/jim.md pipes/<pipe>/data/jim.md`.
- Do NOT treat any `pipes/<pipe>/data/jim.md` (in particular
  `pipes/story/data/jim.md`) as authoritative — those are downstream
  copies. This bit me on 2026-09-08 when I copied from the story pipe
  into q35_4 (accidentally propagating stale content).
- If a pipe reports 0 stories after reset, first check that its
  `data/jim.md` resolves (and does not point at a 5-line stub — one was
  accidentally written on 2026-09-07 during ad-hoc debugging).
