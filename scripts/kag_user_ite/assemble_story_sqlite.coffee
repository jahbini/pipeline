###
  assemble_story_sqlite.coffee  —  KAG_USER_ITE pipeline step
  =====================================================
  Joins the five expanded narrative parts (scene,
  arrival, disturbance, reflection, realization) into a
  single coherent story text. The final assembly step
  in the user-facing KAG generation pipeline.
###
joinParagraphs = (items) ->
  parts = []
  for item in items
    continue unless item?
    text = "#{item}".trim()
    continue unless text.length > 0
    parts.push text
  parts.join "\n"

@step =
  desc: "Assemble sqlite-backed expanded parts into story scaffold"

  action: (S) ->
    storyID = await S.need 'selected_story_id'
    throw new Error "[#{S.stepName}] selected_story_id must be a string" unless typeof storyID is 'string'

    expanded = S.theLowdown("expandedPartsFor{#{storyID}}.json")?.value
    throw new Error "[#{S.stepName}] Missing sqlite expanded parts #{storyID}" unless expanded?.expanded_parts?

    expandedParts = expanded.expanded_parts

    text = joinParagraphs [
      "scene - " + (expandedParts.scene?.text ? '')
      "arrival -  " + (expandedParts.arrival?.text ? '')
      "disturbance - " + (expandedParts.disturbance?.text ? '')
      "reflection - " + (expandedParts.reflection?.text ? '')
      "realization - " + (expandedParts.realization?.text ? '')
    ]

    S.make 'story',
      story_id: storyID
      text: text
      parts: expanded

    S.done()
    return
