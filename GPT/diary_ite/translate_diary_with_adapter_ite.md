Step: `translate_diary_with_adapter_ite`
Recipe: `diary_translate_ite`

Purpose:
- rewrite a completed base diary into Jim's voice with the adapter

Inputs:
- artifact `story_parts`
- artifact `diary_base_text`
- params:
  - `quantized_model_dir`
  - `adapter_path`
  - `translation_prompt_text`
  - optional `mlx`

Outputs:
- `diary_adapted_raw`
- `diary_adapted_meta`
- `diary_adapted_text`
- optional file save `diary/diary_HH_MM.adapter.txt`

Contract:
- preserve events, order, facts, and paragraph structure from the base diary
- adapter is used as a voice rewrite layer, not as the planner

Why this recipe exists:
- base model is stronger at full diary structure
- adapter is stronger at local Jim-like voice
- this split lets the base write first, then the adapter restyle
