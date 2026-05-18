###
  generate_prompt_ite.coffee  —  PROMPT_ITE pipeline step
  =====================================================
  Generates new story-seed prompts from an instruction
  template via MLX. The smaller, MLX-only sibling of
  `generate_prompt_rusty_ite.coffee`. Use this variant
  unless you specifically need the Rusty native session
  for sustained inference throughput.
###
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
    mlxConfig = L.param 'mlx', null
    outputPrefix = String(L.param('output_file_prefix', 'prompt_generate') ? 'prompt_generate').trim() or 'prompt_generate'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] mlx must be an object when provided" if mlxConfig? and (typeof mlxConfig isnt 'object' or Array.isArray(mlxConfig))

    mlxArgs =
      model: modelDir
      prompt: prompt

    if mlxConfig? and typeof mlxConfig is 'object'
      for own key, value of mlxConfig
        continue unless value?
        mlxArgs[key] = value

    rawOutput = L.callMLX 'generate', mlxArgs
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
