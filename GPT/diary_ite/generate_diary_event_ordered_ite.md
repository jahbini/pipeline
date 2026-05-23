Step: `generate_diary_event_ordered_ite`
Recipes:
- `diary_ite`
- used under the existing step names `generate_diary_with_adapter_ite` and `generate_diary_without_adapter_ite`

Purpose:
- generate the diary one event at a time in story order

Inputs:
- artifact `story_parts`
- artifact `diary_kag`
- params `quantized_model_dir`
- optional `adapter_path`
- optional `mlx`

Outputs:
- when called as `generate_diary_with_adapter_ite`:
  - `diary_adapted_raw`
  - `diary_adapted_meta`
  - `diary_adapted_text`
- when called as `generate_diary_without_adapter_ite`:
  - `diary_base_raw`
  - `diary_base_meta`
  - `diary_base_text`

Current behavior:
- generates sections in this order:
  - `scene`
  - `arrival`
  - `disturbance`
  - `reflection`
  - `realization`
- uses `diary_kag.events.<kind>.matches` when present
- falls back to scoring flat `diary_kag.entries` only if event matches are absent

Prompt/voice notes:
- surreal ornament is desired in this project
- the main quality risk is not surrealism itself, but repetitive reflective scaffolding driven by prompt pressure
- if sections keep recurring on abstractions like silence, signal, proof, listening, or quiet, inspect the prompt before blaming adapter depth

Adapter-specific rule:
- for sections after the first, add:
  - `Transition naturally from the previous diary section into this event`

Known pitfalls:
- clean generated text must strip MLX fence lines like `==========`
- adapter path is better at local voice than global continuity; this step exists to reduce that structural drift
