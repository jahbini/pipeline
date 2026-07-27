###
Assemble expanded story parts into final story text.
###

joinParagraphs = (items) ->
  parts = []

  for item in items
    continue unless item?
    text = "#{item}".trim()
    continue unless text.length > 0
    parts.push text

  rval = parts.join "\n"
  return rval

@step =
  desc: "Assemble expanded story parts into final story text"

  action: (M, stepName) ->

    expandedKey = "expanded_story_parts"
    expandedEntry = M.theLowdown expandedKey
    expanded = expandedEntry?.value
    if expanded is undefined
      if typeof expandedEntry?.waitFor is 'function'
        expanded = await expandedEntry.waitFor()
      else if expandedEntry?.notifier?
        expanded = await expandedEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{expandedKey}'" if expanded is undefined

    expandedParts = expanded.expanded_parts ? {}

    sceneText = expandedParts.scene?.text ? ''
    arrivalText = expandedParts.arrival?.text ? ''
    disturbanceText = expandedParts.disturbance?.text ? ''
    reflectionText = expandedParts.reflection?.text ? ''
    realizationText = expandedParts.realization?.text ? ''

    text = joinParagraphs [
      "scene - " + sceneText
      "arrival -  " + arrivalText
      "disturbance - " + disturbanceText
      "reflection - " + reflectionText
      "realization - " + realizationText
    ]

    out =
      story_id: expanded.story_id ? null
      text:  text
      parts: expanded

    M.saveThis "story", out
    M.saveThis "done:#{stepName}", true
    return
