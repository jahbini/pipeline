###
  generate_prompt_ite.coffee  —  PROMPT_ITE pipeline step
  =====================================================
  Generates new story-seed prompts from an instruction
  template via the in-process LLM door:
  `L.callLLM({op:'generate', ...})`. No Python, no
  `mlx_lm generate` subprocess.

  Historical: this was the smaller, MLX-only sibling of
  `generate_prompt_rusty_ite.coffee`. Now the "MLX" spawn
  path is gone — everything runs through llm_dispatch.
###
cleanGeneratedText = (prompt, rawOutput) ->
  # callLLM returns clean structured text; only need to trim the
  # prompt-echo prefix if the model returned it (raw:true mode).
  text = String(rawOutput ? '').trim()
  return '' unless text.length
  if text.indexOf(prompt) is 0
    text = text.slice(prompt.length).trim()
  text

resolveRunTag = (L) ->
  raw = process.env.HH_MM ? L.theLowdown('env/HH_MM')?.value ? null
  return null unless raw?
  text = String(raw).trim()
  text = text.replace(/^"+|"+$/g, '')
  text = text.replace(/^'+|'+$/g, '')
  return null unless text.length
  text

buildDiaryRecord = (prompt, text) ->
  [
    "Prompt:"
    prompt
    ""
    "Generation:"
    text
    ""
  ].join "\n"

@step =
  desc: "Generate text from a UI-supplied prompt and write it to out/"

  action: (L) ->
    prompt = String(L.param('prompt_text', '') ? '').trim()
    throw new Error "[#{L.stepName}] prompt_text must be a non-empty string" unless prompt.length

    modelDir = L.param 'quantized_model_dir', null
    llmConfig = L.param('llm', null) ? L.param('mlx', null)
    outputPrefix = String(L.param('output_file_prefix', 'prompt_generate') ? 'prompt_generate').trim() or 'prompt_generate'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] llm/mlx must be an object when provided" if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))

    # Map legacy kebab-case keys → camelCase for defense against
    # unmigrated overrides. `llm:` blocks are already camelCase.
    MLX_TO_LLM = {
      'max-tokens':    'maxTokens'
      'temp':          'temperature'
      'temperature':   'temperature'
      'top-p':         'topP'
      'system-prompt': 'systemPrompt'
    }

    llmArgs =
      op:       'generate'
      modelDir: modelDir
      prompt:   prompt
      raw:      true

    if llmConfig? and typeof llmConfig is 'object'
      for own key, value of llmConfig
        continue unless value?
        continue if key is 'op'
        llmArgs[MLX_TO_LLM[key] ? key] = value

    result = await L.callLLM llmArgs
    rawOutput = String(result?.rawText ? result?.text ? '')
    text = cleanGeneratedText prompt, rawOutput

    meta =
      mode: 'prompt_generate'
      model_dir: modelDir
      prompt_chars: prompt.length
      raw_chars: String(rawOutput ? '').length
      text_chars: text.length

    console.log "[generate_prompt_ite] prompt chars:", prompt.length
    console.log "[generate_prompt_ite] text chars:", text.length

    L.make 'prompt_generate_raw', String(rawOutput ? '')
    L.make 'prompt_generate_meta', meta
    L.make 'prompt_generate_text', text

    runTag = resolveRunTag L
    if typeof runTag is 'string' and runTag.length
      L.saveThis "out/#{outputPrefix}_#{runTag}.txt", text
      L.saveThis "diary/#{outputPrefix}_#{runTag}.txt", buildDiaryRecord(prompt, text)

    L.done()
    return
