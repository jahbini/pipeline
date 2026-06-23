Step: `generate_ablations_ite`
Recipe: `eval_ite`

Purpose:
- generate "ablation" completions for the eval prompt set: each prompt
  run through both the base model and the model+adapter, so downstream
  steps can compute relative quality metrics

Inputs:
- params `quantized_model_dir`, `adapter_path` (both required, support
  `{BASE}` brace substitution)
- params `eval_prompts` (non-empty array), `max_tokens`, `temp`
- no needs (this is a leaf step)

Outputs:
- artifact `ablations` — array of rows, two per prompt
  - `{prompt_index, prompt, variant: 'base'|'with_adapter', completion}`

Generation pattern:
- one `L.callMLX 'generate'` per (prompt × variant)
- `--adapter-path` is set only on the `with_adapter` variant
- result text is post-processed by `cleanGeneratedText` to strip MLX
  subprocess scaffolding (`====`, `Prompt: N tokens`, `Generation: N
  tokens`, `Peak memory: ...`)
- if the raw output starts with the prompt verbatim (Qwen behavior at
  some sampling settings), the prompt prefix is stripped

Origins:
- port of `~/development/pipeline/scripts/full/examination.coffee`,
  simplified from a 3-D ablation cube (artifact × prompt-variant ×
  prompt) to a 2-variant matrix (base / with_adapter × prompt)
- legacy "artifact" axis is collapsed: in current writediary use the
  only artifact registry has one entry (the current adapter), so the
  axis is just base-vs-adapter

Invariants:
- exactly `2 × len(eval_prompts)` rows produced
- `variant` is always one of `'base'` or `'with_adapter'`
- completions are stripped of trailing/leading whitespace
- warning printed (not failure) when `adapter_path` does not exist on
  disk — the with_adapter variant will fail at MLX call time and the
  failure will be informative

Known pitfalls:
- `max_tokens` too low causes truncated mid-sentence completions; the
  default `160` shows ~20% sentence-ending rate for base prompts
  (rambling fantasy gets cut off) vs ~60-80% for adapter prompts
  (adapter is more concise). Bumping to 240-320 is reasonable for
  prose evaluation
- 5 default prompts is small — score variance per-eval is ±3-5 points;
  N=20 is the rough threshold for stable comparisons
- default prompts are deliberately generic ("Tell me a story in the
  voice you know best") so the recipe runs out-of-the-box; for
  meaningful voice scoring, override per pipe with prompts matched to
  the training corpus's domain
- this step spawns 2N MLX subprocesses; on Apple Silicon each is
  ~5-15 s. A 5-prompt eval takes ~1-3 min before the downstream metric
  steps. 20-prompt eval ~4-10 min
