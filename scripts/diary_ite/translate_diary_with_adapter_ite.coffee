###
  translate_diary_with_adapter_ite.coffee  —  DIARY_TRANSLATE_ITE pipeline step
  =====================================================
  Used by the `diary_translate_ite` recipe. Takes a
  previously-generated diary entry and rewrites it
  through the trained adapter — typically a stylistic
  translation rather than a pure language translation.
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
  if value is undefined then return 'undefined'
  if value is null then return 'null'
  if Array.isArray value then return "array(len=#{value.length})"
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

renderPrompt = (template, storyID, diaryText) ->
  throw new Error "translation_prompt_text must be a string" unless typeof template is 'string'
  text = template
  text = text.replace /\{story_id\}/g, String(storyID ? '')
  text = text.replace /\{diary_text\}/g, String(diaryText ? '')
  text

@step =
  desc: "Rewrite the base diary entry into Jim's voice with the adapter"

  action: (L) ->
    storyParts = await L.need 'story_parts'
    baseDiaryText = await L.need 'diary_base_text'
    storyParts = coerceJSON storyParts

    unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)
      storyParts = await readArtifactTarget L, 'story_parts'
      storyParts = coerceJSON storyParts

    if typeof baseDiaryText isnt 'string'
      baseDiaryFromArtifact = await readArtifactTarget L, 'diary_base_text'
      if typeof baseDiaryFromArtifact is 'string'
        baseDiaryText = baseDiaryFromArtifact
      else
        throw new Error "[#{L.stepName}] diary_base_text invalid; need resolved #{describeValue(await L.need 'diary_base_text')} from need:diary_base_text, artifact resolved #{describeValue(baseDiaryFromArtifact)} from artifact:diary_base_text"

    throw new Error "[#{L.stepName}] story_parts must be an object" unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)
    throw new Error "[#{L.stepName}] diary_base_text must be a non-empty string" unless typeof baseDiaryText is 'string' and baseDiaryText.trim().length

    storyID = String(storyParts.story_id ? '').trim()
    modelDir = L.param 'quantized_model_dir', null
    adapterPath = L.param 'adapter_path'
    llmConfig = L.param('llm', null) ? L.param('mlx', null)
    promptTemplate = L.param 'translation_prompt_text'

    throw new Error "[#{L.stepName}] Missing quantized_model_dir param" unless modelDir?
    throw new Error "[#{L.stepName}] Missing adapter_path" unless adapterPath?
    throw new Error "[#{L.stepName}] mlx must be an object when provided" if llmConfig? and (typeof llmConfig isnt 'object' or Array.isArray(llmConfig))

    prompt = renderPrompt promptTemplate, storyID, baseDiaryText

    llmArgs =
      op: 'generate'
      modelDir: modelDir
      prompt: prompt
      adapterPath: adapterPath

    if llmConfig? and typeof llmConfig is 'object'
      for own key, value of llmConfig
        continue unless value?
        camel = switch key
          when 'max-tokens' then 'maxTokens'
          when 'temp', 'temperature' then 'temperature'
          when 'top-p' then 'topP'
          when 'system-prompt' then 'systemPrompt'
          else key
        llmArgs[camel] = value

    result = await L.callLLM llmArgs
    rawOutput = String(result.rawText ? result.text ? '')
    text = cleanGeneratedText prompt, rawOutput

    meta =
      story_id: storyID
      mode: 'adapter_translate'
      model_dir: modelDir
      adapter_path: adapterPath
      source_text_chars: baseDiaryText.length
      raw_chars: String(rawOutput ? '').length
      text_chars: text.length

    console.log "[translate_diary_with_adapter_ite] story:", storyID
    console.log "[translate_diary_with_adapter_ite] source chars:", baseDiaryText.length
    console.log "[translate_diary_with_adapter_ite] text chars:", text.length

    L.make 'diary_adapted_raw', String(rawOutput ? '')
    L.make 'diary_adapted_meta', meta
    L.make 'diary_adapted_text', text

    runTag = resolveRunTag L
    if typeof runTag is 'string' and runTag.length
      L.saveThis "diary/diary_#{runTag}.adapter.txt", text

    L.done()
    return
