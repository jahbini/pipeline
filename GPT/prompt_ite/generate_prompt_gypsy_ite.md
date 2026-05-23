Step: `generate_prompt_gypsy_ite`
Recipe: `prompt_ite`

Purpose:
- take a freeform prompt from the UI and run one native MLX-Metal generation
  through the gypsy session API
- support optional LoRA adapter via `adapter_dir` (or `mlx.adapter_dir`)
- write the result into `out/` without involving story/KAG machinery

Inputs:
- param `prompt_text` (UI_textarea)
- param `quantized_model_dir` (default `build/model4`)
- optional param `tokenizer_dir` (defaults to `quantized_model_dir`)
- optional param `adapter_dir` (or `mlx.adapter_dir` / `mlx.adapter_path` /
  `mlx.adapter`)
- optional param `chat` (default `true`; native side applies Qwen chat
  formatting)
- optional param `system_prompt`
- optional param `output_file_prefix` (default `prompt_gypsy`)
- optional param object `mlx`:
  - `max-tokens` / `max_tokens` / `maxTokens` (default 1600; native ceiling
    is 4096 — raise `generation_token_ceiling` in
    `metal/metal_llm_node.cpp` if a use case needs more)
  - `temp` / `temperature` (default 0)
  - `top-k` / `top_k` / `topK` (default 40 when temp>0, else 0)
  - `top-p` / `top_p` / `topP` (default 1.0)
  - `seed` (default 1234)

Outputs:
- artifact `prompt_gypsy_raw` (full JSON record incl. token ids + timing)
- artifact `prompt_gypsy_meta` (timing, backend, controls, cleanup info)
- artifact `prompt_gypsy_text` (cleaned text)
- run-tagged saved files when `HH_MM` env var is set:
  `out/<prefix>_<HH_MM>.txt` and `diary/<prefix>_<HH_MM>.txt`

Backend:
- native addon at `metal/metal_llm.node` (built via `npx node-gyp rebuild`)
- gypsy session API at `gypsy/session_api.coffee`
- lifecycle = `loadModelResident` → `loadTokenizer` → optional `loadAdapter`
  → `createSession` → `warmSession` → `generate` → cleanup
- attention backend: `mlx_prealloc_kv` (preallocated expanded KV with
  `slice_update`)
- compute dtype: `bfloat16` for hidden states and KV cache
- MLX pool capped at 512 MB inside the native addon

Current behavior:
- targets the prepared quantized model at `build/model4`
- supports LoRA adapter via session opts
- uses Qwen chat fallback wrapper (no Jinja yet) when chat=true; the
  native side then applies its own formatting consistent with the test probe
- strips trailing `<|im_*|>` special tokens and MLX fence/timing lines from
  the cleaned output

Measured envelope (May 2026, M2, Qwen3-4B Instruct):
- ~9–10 tok/s at 64 tokens, ~16 s wall clock incl. model load
- ~1.9–2.0 GB peak resident

UI contract:
- `prompt_ite` exposes `prompt_text` as `UI_textarea`
- adapter is opt-in via `adapter_dir` (or `mlx.adapter_dir`); when absent the
  base quantized model is used without LoRA

Known pitfalls:
- `prompt_text` must be non-empty
- depends on `base_ite` having prepared `build/model4`
- output text at greedy temperature is the **bf16 variant** of MLX's output;
  it differs from a strict fp32 run while remaining coherent. Do not treat
  divergence from fp32-MLX as a bug (see `GPT/gypsy_strategy.md` standard
  S8)
- do not enable repeated full-logit summaries in the hot loop; they force a
  CPU readback of all 151936 logits per token and destroy throughput
- never rerun the rejected manual direct-Metal stack as a speed comparison
  (see `gypsy/STATUS.md` "Rejected Path")
