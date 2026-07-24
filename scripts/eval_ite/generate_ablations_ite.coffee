###
  generate_ablations_ite.coffee  —  EVAL_ITE pipeline step
  =====================================================
  Port of `~/development/pipeline/scripts/full/examination.coffee`,
  simplified to two variants per prompt (base / with_adapter) instead
  of the legacy `artifact × prompt_variant × prompt` cube.

  For each `eval_prompts` entry: run `L.callLLM({op:'generate'})`
  twice — once against the base quantized model, once with the
  adapter under evaluation. Both completions are recorded for the
  summarize step to compute distinct2 / mem_sub / sentence-ending /
  word-count / empty-rate metrics.

  Output rows shape:
    { prompt_index, prompt, variant: 'base'|'with_adapter', completion }
###
# Adapter presence is sniffed via `L.tools.adapter.exists` (see
# GPT/CONVENTIONS.md § "Tools"); no direct `fs` use needed here.

# Trim the echoed prompt prefix if the model returned it (raw:true).
# The mlx_lm subprocess-scaffolding filters (=====, "Prompt:", etc.)
# that the old callMLX path needed are gone — L.callLLM returns the
# structured completion text directly, no stdout noise.
cleanGeneratedText = (prompt, rawOutput) ->
  text = String(rawOutput ? '').trim()
  return '' unless text.length
  if text.indexOf(prompt) is 0
    text = text.slice(prompt.length).trim()
  text

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
      baseResult = await L.callLLM
        op: 'generate'
        modelDir: quantizedModelDir
        prompt: prompt
        raw: true
        maxTokens: maxTokens
        temperature: temp
      baseOut = String(baseResult?.text ? baseResult?.rawText ? '')
      rows.push
        prompt_index: i
        prompt: prompt
        variant: 'base'
        completion: cleanGeneratedText(prompt, baseOut)

      # With-adapter variant.
      console.log "[#{L.stepName}] prompt #{i + 1}/#{prompts.length}  variant=with_adapter"
      adapterResult = await L.callLLM
        op: 'generate'
        modelDir: quantizedModelDir
        adapterPath: adapterPath
        prompt: prompt
        raw: true
        maxTokens: maxTokens
        temperature: temp
      adapterOut = String(adapterResult?.text ? adapterResult?.rawText ? '')
      rows.push
        prompt_index: i
        prompt: prompt
        variant: 'with_adapter'
        completion: cleanGeneratedText(prompt, adapterOut)

    console.log "[#{L.stepName}] generated #{rows.length} ablation rows (#{prompts.length} prompts × 2 variants)"
    L.make 'ablations', rows
    L.done()
    return
