###
  build_kag_prompt_sqlite.coffee  —  KAG_USER_ITE pipeline step
  =====================================================
  Renders the KAG context block (keyword + headline
  pairs from the selected story) into the prompt
  template fed to the part-expansion step. Pure
  string-building; no MLX calls.
###
renderKagEntry = (entry) ->
  keyword = String(entry?.keyword ? '').trim()
  headline = String(entry?.headline ? '').trim()
  return null unless keyword.length or headline.length
  return "- #{keyword}: #{headline}" if keyword.length and headline.length
  return "- #{keyword}" if keyword.length
  "- #{headline}"

@step =
  desc: "Build a KAG-augmented prompt for final story generation"

  action: (S) ->
    storyID = await S.need 'selected_story_id'
    story = await S.need 'story'
    throw new Error "[#{S.stepName}] selected_story_id must be a string" unless typeof storyID is 'string'
    throw new Error "[#{S.stepName}] story must be an object" unless story?.text?

    storyRecord = S.theLowdown("storyByID{#{storyID}}.json")?.value
    kag = S.theLowdown("kagFor{#{storyID}}.json")?.value

    throw new Error "[#{S.stepName}] Missing sqlite story #{storyID}" unless storyRecord?.text?
    throw new Error "[#{S.stepName}] Missing sqlite KAG #{storyID}" unless Array.isArray(kag?.entries)

    kagLines = []
    for entry in kag.entries
      rendered = renderKagEntry entry
      kagLines.push rendered if rendered?

    prompt = [
      "You are writing in the narrative voice of Jim from St. John's."
      ""
      "Use the following KAG emotional/event cues to guide the story."
      "Keep the story grounded in the source material and preserve the event order already present in the scaffold."
      ""
      "KAG cues:"
      if kagLines.length then kagLines.join("\n") else "- none"
      ""
      "Rules:"
      "- Speak in the first person as Jim"
      "- Keep the same order of events"
      "- Do not introduce new plot elements that contradict the scaffold"
      "- Add natural narration and sensory detail"
      "- Keep the tone observational, slightly humorous, and reflective"
      "- Return only the finished story"
      ""
      "Source title:"
      "#{storyRecord.title ? storyID}"
      ""
      "Story scaffold:"
      ""
      "#{story.text}"
    ].join "\n"

    S.make 'kag_prompt_text', prompt
    S.done()
    return
