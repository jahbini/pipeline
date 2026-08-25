<!-- 2026-08-22: model paths under $MODELS supersede any `build/model[4]` mentions below. See GPT/model_paths.md for the current convention. -->

Step: `quantize_model`
Recipe: `base_ite`

Purpose:
- build the prepared quantized inference model in `build/model4` from the full base model in `build/model`

Inputs:
- params `source_model_dir`, `quantized_model_dir`, `quantized_model_memo_key`
- param object `mlx`

Outputs:
- meta write `quantizedModelDir`
- filesystem output `build/model4`

Current pipeline role:
- `base_ite` owns quantization now
- downstream inference recipes are expected to consume the prepared `build/model4`
- `oracle_ite` no longer downloads or quantizes on its own

Quantization contract:
- this step must perform real MLX quantization, not just format conversion
- active settings are:
  - `mlx.quantize: null`
  - `mlx.q-bits: 4`

Validation:
- if q-bits are requested, an existing target directory is only valid when `config.json` contains quantization metadata
- a converted-only `build/model4` must be rejected and rebuilt

Pre-quantized sources (2026-08-25):
- if `src_dir` itself is already an MLX quantized model (its `config.json`
  has a `quantization` block matching `q_bits` / `group_size`), the step
  symlinks `quantized_dir → src_dir` instead of re-quantizing. Common
  case: HF repos named `mlx-community/<name>-4bit`. Attempting to
  re-quantize packed uint32 weights fails with an MLX kernel error
  (`affine_quantize_uint32_t_gs_*_b_*`).

Known pitfalls:
- `--q` is ambiguous in the installed MLX CLI; use `--quantize`
- a converted-only `build/model4` can be much larger and can OOM inference
- multimodal Gemma 4 checkpoints such as `google/gemma-4-E2B-it` are not small on this local conversion path; local HF-to-MLX conversion can fail before quantization completes
- if inference recipes start redownloading or requantizing, that is architecture drift
