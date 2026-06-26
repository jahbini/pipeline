###
  generate_ablations_ite.coffee  —  EVAL_ITE pipeline step
  =====================================================
  Port of `~/development/pipeline/scripts/full/examination.coffee`,
  simplified to two variants per prompt (base / with_adapter) instead
  of the legacy `artifact × prompt_variant × prompt` cube.

  For each `eval_prompts` entry: spawn `mlx_lm generate` twice — once
  against the base quantized model, once with `--adapter-path` set to
  the adapter under evaluation. Both completions are recorded for the
  summarize step to compute distinct2 / mem_sub / sentence-ending /
  word-count / empty-rate metrics.

  Output rows shape:
    { prompt_index, prompt, variant: 'base'|'with_adapter', completion }
###
# Adapter presence is sniffed via `L.tools.adapter.exists` (see
# GPT/CONVENTIONS.md § "Tools"); no direct `fs` use needed here.

# Strip MLX subprocess scaffolding from the raw stdout so the completion
# is just the model's response. Mirrors the pattern in
# `scripts/diary_ite/generate_diary_without_adapter_ite.coffee`.
cleanGeneratedText = (prompt, rawOutput) ->
  text = String(rawOutput ? '').trim()
  return '' unless text.length

  if text.indexOf(prompt) is 0
    text = text.slice(prompt.length).trim()

  lines = text.split /\r?\n/
  lines = lines.filter (line) ->
    trimmed = line.trim()
    return false if /^=+$/.test trimmed
    return false if /^Prompt:\s+\d+\s+tokens/.test trimmed
    return false if /^Generation:\s+\d+\s+tokens/.test trimmed
    return false if /^Peak memory:\s+/.test trimmed
    true

  lines.join("\n").trim()

@step =
  desc: "Generate ablation completions (base vs with_adapter) for the eval prompt set"

  action: (L) ->
    quantizedModelDir = L.param 'quantized_model_dir'
    adapterPath       = L.param 'adapter_path'
    prompts           = L.param 'eval_prompts'
    maxTokens         = L.param 'max_tokens', 160
    temp              = L.param 'temp', 0.7

    throw new Error "[#{L.stepName}] quantized_model_dir must be a string" unless typeof quantizedModelDir is 'string' and quantizedModelDir.length
    throw new Error "[#{L.stepName}] adapter_path must be a string"        unless typeof adapterPath is 'string' and adapterPath.length
    throw new Error "[#{L.stepName}] eval_prompts must be a non-empty array" unless Array.isArray(prompts) and prompts.length > 0

    adapterPresent = L.tools.adapter.exists adapterPath
    console.log "[#{L.stepName}] model      :", quantizedModelDir
    console.log "[#{L.stepName}] adapter    :", adapterPath, (if adapterPresent then "(present)" else "(MISSING — with_adapter variant will fail)")
    console.log "[#{L.stepName}] prompts    :", prompts.length
    console.log "[#{L.stepName}] max_tokens :", maxTokens, " temp:", temp

    rows = []
    for prompt, i in prompts
      throw new Error "[#{L.stepName}] eval_prompts[#{i}] must be a non-empty string" unless typeof prompt is 'string' and prompt.length

      # Base variant: no adapter.
      console.log "[#{L.stepName}] prompt #{i + 1}/#{prompts.length}  variant=base"
      baseOut = L.callMLX 'generate',
        model: quantizedModelDir
        prompt: prompt
        'max-tokens': maxTokens
        temp: temp
      rows.push
        prompt_index: i
        prompt: prompt
        variant: 'base'
        completion: cleanGeneratedText(prompt, baseOut)

      # With-adapter variant.
      console.log "[#{L.stepName}] prompt #{i + 1}/#{prompts.length}  variant=with_adapter"
      adapterOut = L.callMLX 'generate',
        model: quantizedModelDir
        'adapter-path': adapterPath
        prompt: prompt
        'max-tokens': maxTokens
        temp: temp
      rows.push
        prompt_index: i
        prompt: prompt
        variant: 'with_adapter'
        completion: cleanGeneratedText(prompt, adapterOut)

    console.log "[#{L.stepName}] generated #{rows.length} ablation rows (#{prompts.length} prompts × 2 variants)"
    L.make 'ablations', rows
    L.done()
    return
