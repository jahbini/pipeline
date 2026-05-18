###
  expand_story_parts_sqlite.coffee  —  KAG_USER_ITE pipeline step
  =====================================================
  For each of the five narrative parts produced by
  `create_story_parts_sqlite`, calls MLX to expand the
  one-sentence summary into a richer paragraph.
  Writes via `expandedPartsFor{...}.json`. This is the
  MLX-heaviest step in the KAG user pipeline.
###
ensureSentence = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0
  last = text.charAt text.length - 1
  text = text + '.' if last not in ['.', '!', '?']
  text

capitalizeFirst = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0
  text.charAt(0).toUpperCase() + text.slice(1)

lowerFirst = (s) ->
  return '' unless s?
  text = "#{s}".trim()
  return '' unless text.length > 0
  text.charAt(0).toLowerCase() + text.slice(1)

expandScene = (part) ->
  raw = lowerFirst part?.text ? ''
  text = ensureSentence "The #{raw}"
  {
    text: text
    source_text: part?.text ? ''
    location: part?.location ? null
    expansion_mode: 'scene_narration'
  }

expandArrival = (part) ->
  text = ensureSentence capitalizeFirst part?.text ? ''
  {
    text: text
    source_text: part?.text ? ''
    character: part?.character ? null
    expansion_mode: 'arrival_narration'
  }

expandDisturbance = (part) ->
  raw = lowerFirst part?.text ? ''
  text = ensureSentence "On the radio, #{raw}"
  {
    text: text
    source_text: part?.text ? ''
    theme: part?.theme ? null
    expansion_mode: 'disturbance_narration'
  }

expandReflection = (part) ->
  text = ensureSentence capitalizeFirst part?.text ? ''
  {
    text: text
    source_text: part?.text ? ''
    expansion_mode: 'reflection_narration'
  }

expandRealization = (part) ->
  raw = lowerFirst part?.text ? ''
  text = ensureSentence "That was when I realized #{raw}"
  {
    text: text
    source_text: part?.text ? ''
    expansion_mode: 'realization_narration'
  }

@step =
  desc: "Expand sqlite-backed story events into fuller prose parts"

  action: (S) ->
    storyID = await S.need 'selected_story_id'
    throw new Error "[#{S.stepName}] selected_story_id must be a string" unless typeof storyID is 'string'

    storyParts = S.theLowdown("partsFor{#{storyID}}.json")?.value
    throw new Error "[#{S.stepName}] Missing sqlite story parts #{storyID}" unless storyParts?.parts?

    expandedParts =
      scene: expandScene storyParts.parts.scene
      arrival: expandArrival storyParts.parts.arrival
      disturbance: expandDisturbance storyParts.parts.disturbance
      reflection: expandReflection storyParts.parts.reflection
      realization: expandRealization storyParts.parts.realization

    S.saveThis "expandedPartsFor{#{storyID}}.json",
      story_id: storyID
      expanded_parts: expandedParts

    S.done()
    return
