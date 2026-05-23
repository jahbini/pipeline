Step: `generate_diary_without_adapter_ite`
Recipe: `diary_ite`

Purpose:
- generate final diary text without the adapter

Inputs:
- artifact `story_parts`
- artifact `diary_prompt_text`
- param `quantized_model_dir`

Outputs:
- artifacts `diary_base_raw`, `diary_base_meta`, `diary_base_text`
- optional file save `diary/diary_HH_MM.txt`

Invariants:
- this step is optional by operator choice, but not an upstream producer for the adapter run
- changing its `depends_on` must not be confused with prompt production

Known pitfall:
- valid YAML can still encode an invalid graph, for example `depends_on: [never]`
