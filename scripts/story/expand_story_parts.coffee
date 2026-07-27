###
Expand resolved story parts into fuller prose while preserving structure.
###

cloneDeep = (obj) ->
  return JSON.parse JSON.stringify obj

ensureSentence = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0

  last = text.charAt text.length - 1
  if last not in ['.', '!', '?']
    text = text + '.'

  rval = text
  return rval

capitalizeFirst = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0

  rval = text.charAt(0).toUpperCase() + text.slice(1)
  return rval

lowerFirst = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0

  rval = text.charAt(0).toLowerCase() + text.slice(1)
  return rval

expandScene = (part) ->
  raw = part?.text ? ''
  raw = lowerFirst raw
  text = "The #{raw}"
  text = ensureSentence text

  rval =
    text: text
    source_text: part?.text ? ''
    location: part?.location ? null
    expansion_mode: 'scene_narration'

  return rval

expandArrival = (part) ->
  raw = part?.text ? ''
  text = capitalizeFirst raw
  text = ensureSentence text

  rval =
    text: text
    source_text: part?.text ? ''
    character: part?.character ? null
    expansion_mode: 'arrival_narration'

  return rval

expandDisturbance = (part) ->
  raw = part?.text ? ''
  raw = lowerFirst raw
  text = "On the radio, #{raw}"
  text = ensureSentence text

  rval =
    text: text
    source_text: part?.text ? ''
    theme: part?.theme ? null
    expansion_mode: 'disturbance_narration'

  return rval

expandReflection = (part) ->
  raw = part?.text ? ''
  text = capitalizeFirst raw
  text = ensureSentence text

  rval =
    text: text
    source_text: part?.text ? ''
    expansion_mode: 'reflection_narration'

  return rval

expandRealization = (part) ->
  raw = part?.text ? ''
  raw = lowerFirst raw
  text = "That was when I realized #{raw}"
  text = ensureSentence text

  rval =
    text: text
    source_text: part?.text ? ''
    expansion_mode: 'realization_narration'

  return rval

@step =
  desc: "Expand resolved story parts into fuller prose"

  action: (M, stepName) ->

    storyPartsKey = "story_parts"
    storyPartsEntry = M.theLowdown storyPartsKey
    storyParts = storyPartsEntry?.value
    if storyParts is undefined
      if typeof storyPartsEntry?.waitFor is 'function'
        storyParts = await storyPartsEntry.waitFor()
      else if storyPartsEntry?.notifier?
        storyParts = await storyPartsEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{storyPartsKey}'" if storyParts is undefined

    keys = cloneDeep(storyParts.keys ? {})

    expandedParts =
      scene: expandScene storyParts.scene
      arrival: expandArrival storyParts.arrival
      disturbance: expandDisturbance storyParts.disturbance
      reflection: expandReflection storyParts.reflection
      realization: expandRealization storyParts.realization

    out =
      story_id: storyParts.story_id ? null
      keys: keys
      source_parts: cloneDeep(storyParts)
      expanded_parts: expandedParts

    M.saveThis "expanded_story_parts", out
    M.saveThis "done:#{stepName}", true
    return
