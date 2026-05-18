###
  build_diary_prompt_ite.coffee  —  DIARY_ITE pipeline step
  =====================================================
  Renders the selected diary events into a single
  prompt string for the diary-generation models. Pure
  string-building; no MLX calls live here. The output
  artifact feeds both the with-adapter and without-adapter
  generation steps.
###
renderEvent = (event) ->
  kind = String(event?.kind ? '').trim()
  text = String(event?.text ? '').trim()
  keyword = String(event?.keyword ? '').trim()
  headline = String(event?.headline ? '').trim()
  lines = []
  lines.push "- #{kind}: #{text}" if kind.length or text.length
  lines.push "  keyword: #{keyword}" if keyword.length
  lines.push "  headline: #{headline}" if headline.length
  lines.join "\n"

renderKagEntry = (entry) ->
  keyword = String(entry?.keyword ? '').trim()
  headline = String(entry?.headline ? '').trim()
  return "- #{keyword}: #{headline}" if keyword.length and headline.length
  return "- #{headline}" if headline.length
  return "- #{keyword}" if keyword.length
  "- unlabelled KAG cue"

renderEventSupport = (kind, payload) ->
  return null unless payload? and typeof payload is 'object'
  emotion = String(payload.selected_emotion ? '').trim()
  matches = payload.matches ? []
  lines = []
  lines.push "#{kind}:"
  lines.push "  desired emotion: #{emotion}" if emotion.length
  if matches.length is 0
    lines.push "  support: none"
    return lines.join "\n"

  for match in matches
    keyword = String(match?.keyword ? '').trim()
    headline = String(match?.headline ? '').trim()
    if keyword.length and headline.length
      lines.push "  - #{keyword}: #{headline}"
    else if headline.length
      lines.push "  - #{headline}"
    else if keyword.length
      lines.push "  - #{keyword}"
    else
      lines.push "  - support cue"
  lines.join "\n"

coerceJSON = (value) ->
  return value unless typeof value is 'string'
  try
    JSON.parse value
  catch
    value

normalizeDiaryKag = (value) ->
  value = coerceJSON value
  return value if Array.isArray(value?.entries)

  if value? and typeof value is 'object' and not Array.isArray(value)
    if Array.isArray(value.value?.entries)
      return value.value
    if typeof value.entries is 'string'
      parsedEntries = coerceJSON value.entries
      if Array.isArray(parsedEntries)
        out = Object.assign {}, value
        out.entries = parsedEntries
        return out

  value

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

@step =
  desc: "Build the final diary prompt from diary events and matched KAG"

  action: (L) ->
    storyParts = await L.need 'story_parts'
    diaryKag = await L.need 'diary_kag'
    storyParts = coerceJSON storyParts
    diaryKag = normalizeDiaryKag diaryKag

    unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)
      storyParts = await readArtifactTarget L, 'story_parts'
      storyParts = coerceJSON storyParts

    unless Array.isArray(diaryKag?.entries)
      diaryKag = await readArtifactTarget L, 'diary_kag'
      diaryKag = normalizeDiaryKag diaryKag

    throw new Error "[#{L.stepName}] story_parts must be an object" unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)
    throw new Error "[#{L.stepName}] diary_kag must be an object" unless Array.isArray(diaryKag?.entries)

    eventLines = []
    eventLines.push renderEvent kind:'scene', text: storyParts.scene?.text, keyword: storyParts.scene?.location, headline: ''
    eventLines.push renderEvent kind:'arrival', text: storyParts.arrival?.text, keyword: storyParts.arrival?.character, headline: ''
    eventLines.push renderEvent kind:'disturbance', text: storyParts.disturbance?.text, keyword: storyParts.disturbance?.theme, headline: ''
    eventLines.push renderEvent kind:'reflection', text: storyParts.reflection?.text, keyword: '', headline: ''
    eventLines.push renderEvent kind:'realization', text: storyParts.realization?.text, keyword: '', headline: ''
    eventLines = eventLines.filter(Boolean)
    kagLines = (renderKagEntry(entry) for entry in diaryKag.entries when entry?).filter(Boolean)
    supportLines = []
    for kind in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
      row = renderEventSupport kind, diaryKag?.events?[kind]
      supportLines.push row if row?

    prompt = [
      "You are writing in the narrative voice of Jim from St. John's."
      ""
      "Write a diary entry in first person."
      "Use the diary events as the backbone of the entry."
      "Use the KAG cues as emotional guidance, but keep the entry grounded and concrete."
      ""
      "Rules:"
      "- Do not introduce plot contradictions"
      "- Add sensory detail and reflective narration"
      "- Keep the voice observational, slightly humorous, and reflective"
      "- Return only the finished diary entry"
      ""
      "Diary events:"
      if eventLines.length then eventLines.join("\n") else "- none"
      ""
      "Event support cues:"
      if supportLines.length then supportLines.join("\n\n") else "- none"
      ""
      "KAG cues:"
      if kagLines.length then kagLines.join("\n") else "- none"
      "Write the events in the following order: scene, arrival, disturbance, reflection, realization. make each one a separate paragraph in your writing."
    ].join "\n"

    console.log "[build_diary_prompt_ite] prompt chars:", prompt.length

    L.make 'diary_prompt_text', prompt
    L.done()
    return
