Step: `generate_prompt_ite`
Recipe: `prompt_ite`

Purpose:
- take a freeform prompt from the UI and run one MLX generation
- write the result into `out/` without involving story, KAG, or adapter machinery

Inputs:
- param `prompt_text`
- param `quantized_model_dir`
- optional param object `mlx`
- optional param `output_file_prefix`

Outputs:
- artifact `prompt_generate_raw`
- artifact `prompt_generate_meta`
- artifact `prompt_generate_text`
- run-tagged saved file `out/prompt_generate_HH_MM.txt`

Current behavior:
- uses the prepared quantized model in `build/model4`
- does not use an adapter
- strips echoed prompt text and MLX fence/timing lines from the cleaned output

UI contract:
- `prompt_ite` exposes `prompt_text` as `UI_textarea`
- the prompt is supplied through normal recipe UI fields, then written into `control_override.yaml`

Known pitfalls:
- `prompt_text` must be non-empty
- this recipe depends on `base_ite` having already prepared `build/model4`
- do not add ad hoc prompt endpoints when `UI_textarea` already covers the need
