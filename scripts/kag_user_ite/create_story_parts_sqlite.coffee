###
  create_story_parts_sqlite.coffee  —  KAG_USER_ITE pipeline step
  =====================================================
  Splits the selected story into the five canonical
  narrative parts (scene/arrival/disturbance/reflection/
  realization) using the headline sequence in the KAG
  rows as the boundary signal. Writes via the
  `partsFor{...}.json` sqlite request key.
###
headlineAt = (entries, idx, fallback) ->
  entry = entries[idx]
  return fallback unless entry?
  headline = String(entry.headline ? '').trim()
  return fallback unless headline.length
  headline

keywordAt = (entries, idx, fallback) ->
  entry = entries[idx]
  return fallback unless entry?
  keyword = String(entry.keyword ? '').trim()
  return fallback unless keyword.length
  keyword

@step =
  desc: "Create five canonical story events from sqlite KAG entries"

  action: (S) ->
    storyID = await S.need 'selected_story_id'
    throw new Error "[#{S.stepName}] selected_story_id must be a string" unless typeof storyID is 'string'

    story = S.theLowdown("storyByID{#{storyID}}.json")?.value
    kag = S.theLowdown("kagFor{#{storyID}}.json")?.value

    throw new Error "[#{S.stepName}] Missing sqlite story #{storyID}" unless story?.text?
    throw new Error "[#{S.stepName}] Missing sqlite KAG #{storyID}" unless Array.isArray(kag?.entries) and kag.entries.length > 0

    entries = kag.entries
    title = String(story.title ? storyID).trim()

    parts =
      scene:
        text: "daylight around #{title} felt touched by #{headlineAt(entries, 0, 'a quiet but unusual mood')}"
        location: title
      arrival:
        text: "the feeling of #{keywordAt(entries, 1, keywordAt(entries, 0, 'change'))} arrived with #{headlineAt(entries, 1, 'a person who brought new energy')}"
        character: keywordAt(entries, 1, 'visitor')
      disturbance:
        text: headlineAt(entries, 2, headlineAt(entries, 0, 'the calm gave way to a disturbance worth noticing'))
        theme: keywordAt(entries, 2, keywordAt(entries, 0, 'tension'))
      reflection:
        text: "I kept turning over #{headlineAt(entries, 3, headlineAt(entries, 1, 'what the moment might mean'))}"
      realization:
        text: headlineAt(entries, 4, headlineAt(entries, 2, 'something finally became clear to me'))

    S.saveThis "partsFor{#{storyID}}.json",
      story_id: storyID
      parts: parts

    S.done()
    return
