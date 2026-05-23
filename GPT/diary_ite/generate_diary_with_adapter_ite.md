Step: `generate_diary_with_adapter_ite`
Recipe: `diary_ite`

Purpose:
- generate final diary text with the trained adapter

Inputs:
- artifact `story_parts`
- artifact `diary_prompt_text`
- params `quantized_model_dir`, `adapter_path`

Outputs:
- artifacts `diary_adapted_raw`, `diary_adapted_meta`, `diary_adapted_text`
- optional file save `diary/diary_HH_MM.adapter.txt`

Invariants:
- this step does not depend on `generate_diary_without_adapter_ite`
- both diary generators are sibling consumers of `build_diary_prompt_ite`

Error reporting:
- when `diary_prompt_text` is invalid, report the actual resolved values and sources
- do not hide graph/config errors behind a bare type check
