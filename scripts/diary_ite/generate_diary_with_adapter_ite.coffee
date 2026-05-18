###
  generate_diary_with_adapter_ite.coffee  —  DIARY_ITE pipeline step
  =====================================================
  Treatment arm of the diary A/B: generates a diary
  entry via MLX using the **trained LoRA adapter**.
  Pairs with `generate_diary_without_adapter_ite.coffee`
  (the control arm) so an evaluator can compare them.
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

coerceJSON = (value) ->
  return value unless typeof value is 'string'
  try
    JSON.parse value
  catch
    value

describeValue = (value) ->
  if value is undefined
    return 'undefined'
  if value is null
    return 'null'
  if Array.isArray value
    return "array(len=#{value.length})"
  if typeof value is 'string'
    snippet = value.replace(/\s+/g, ' ').slice(0, 120)
    return "string(len=#{value.length}) #{JSON.stringify(snippet)}"
  if typeof value is 'object'
    keys = Object.keys(value).slice(0, 8).join(', ')
    return "object(keys=#{keys})"
  "#{typeof value} #{JSON.stringify(value)}"

readArtifactTarget = (L, artifactKey) ->
  experiment = L.theLowdown('experiment.yaml')?.value ? {}
  targetKey = experiment?.artifacts?[artifactKey]?.target
  return undefined unless typeof targetKey is 'string'

  targetEntry = L.theLowdown targetKey
  targetValue = targetEntry?.value
  if targetValue is undefined
    if typeof targetEntry?.waitFor is 'function'
      targetValue = await targetEntry.waitFor()
    else if targetEntry?.notifier?
      targetValue = await targetEntry.notifier
  targetValue

resolveRunTag = (L) ->
  raw = process.env.HH_MM ? L.theLowdown('env/HH_MM')?.value ? null
  return null unless raw?
  text = String(raw).trim()
  text = text.replace(/^"+|"+$/g, '')
  text = text.replace(/^'+|'+$/g, '')
  return null unless text.length
  text

@step =
  desc: "Generate a diary entry using the trained adapter"

  action: (L) ->
    storyParts = await L.need 'story_parts'
    prompt = await L.need 'diary_prompt_text'
    promptSource = 'need:diary_prompt_text'
    storyParts = coerceJSON storyParts

    unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)
      storyParts = await readArtifactTarget L, 'story_parts'
      storyParts = coerceJSON storyParts

    if typeof prompt isnt 'string'
      promptFromArtifact = await readArtifactTarget L, 'diary_prompt_text'
      if typeof promptFromArtifact is 'string'
        prompt = promptFromArtifact
        promptSource = 'artifact:diary_prompt_text'
      else
        throw new Error "[#{L.stepName}] diary_prompt_text invalid; need resolved #{describeValue(await L.need 'diary_prompt_text')} from need:diary_prompt_text, artifact resolved #{describeValue(promptFromArtifact)} from artifact:diary_prompt_text"

    storyID = String(storyParts?.story_id ? '').trim()
    throw new Error "[#{L.stepName}] story_parts must be an object" unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)

    modelDir = L.param 'quantized_model_dir', null
    adapterPath = L.param 'adapter_path'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] Missing adapter_path" unless adapterPath?

    rawOutput = L.callMLX 'generate',
      model: modelDir
      prompt: prompt
      "adapter-path": adapterPath

    text = cleanGeneratedText prompt, rawOutput
    meta =
      story_id: storyID
      mode: 'adapter'
      model_dir: modelDir
      adapter_path: adapterPath
      raw_chars: String(rawOutput ? '').length
      text_chars: text.length

    console.log "[generate_diary_with_adapter_ite] story:", storyID
    console.log "[generate_diary_with_adapter_ite] text chars:", text.length
    console.log "[generate_diary_with_adapter_ite] prompt source:", promptSource

    L.make 'diary_adapted_raw', String(rawOutput ? '')
    L.make 'diary_adapted_meta', meta
    L.make 'diary_adapted_text', text
    runTag = resolveRunTag L
    if typeof runTag is 'string' and runTag.length
      L.saveThis "diary/diary_#{runTag}.adapter.txt", text
    L.done()
    return
