###
  select_story_sqlite.coffee  —  KAG_USER_ITE pipeline step
  =====================================================
  Selects the story to operate on for this pipeline
  run by `story_id` param. The smallest script in the
  user KAG family — useful as a minimal example of
  reading a required param + a sqlite request key,
  using the contract API.
###
@step =
  desc: "Select a SQLite-backed story for KAG-assisted generation"

  action: (S) ->
    storyID = S.param 'story_id'
    throw new Error "[#{S.stepName}] Missing story_id param" unless storyID?

    story = S.theLowdown("storyByID{#{storyID}}.json")?.value
    throw new Error "[#{S.stepName}] Missing sqlite story #{storyID}" unless story?.story_id is storyID

    kag = S.theLowdown("kagFor{#{storyID}}.json")?.value
    throw new Error "[#{S.stepName}] Missing sqlite KAG #{storyID}" unless Array.isArray(kag?.entries) and kag.entries.length > 0

    S.make 'selected_story_id', storyID
    S.done()
    return
