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

Determinism (verified 2026-09-07):
- `quantize_model` produces **bit-identical** output on repeat runs for
  the same source weights + same quant settings (bits=4, group_size=64).
  Verified on `Qwen/Qwen3.5-4B`: mlx4 built Aug-26 with mlx-lm 0.28.3
  and mlx-lm 0.31.2 have identical SHA-256
  (`73da816f506a347a5713953f9ff8d695c5ffe53378b509cb1bc7a790a64a5a3d`,
  5,487,481,485 bytes, same file list).
- Implication: a hospital pipe's failure is never explained by "the
  quant is stale" — if the safetensors bytes are on disk, they are what
  a fresh `quantize_model` would produce. Don't waste a Metal-GPU cycle
  requantizing when debugging load failures; the bug is in the model
  wrapper, the checkpoint layout, or the venv, not the weights.
- To force `quantize_model` to actually re-run (not short-circuit on
  cached `state/step-quantize_model.json`), delete that step file
  before relaunching. The runner only checks the step's cached "done"
  status, not the presence of the target directory.
