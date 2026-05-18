###
  prepare_kag_segments_sqlite.coffee  —  ORACLE_ITE pipeline step
  =====================================================
  Pure-data step (no MLX). Reads the seeded story rows
  via `storyByID{...}.json` and any existing KAG rows
  via `kagFor{...}.json`, then chunks the story text
  into segments the oracle prompt can ingest. Demonstrates
  the **contract API** (`S.need`/`S.make`) end-to-end —
  a good reference for new step authors.
###
@step =
  desc: "Build KAG rows from sqlite-backed story and kag request keys"

  action: (S) ->
    storyIDs = await S.need 'new_story_ids'
    throw new Error "[#{S.stepName}] new_story_ids must be an array" unless Array.isArray storyIDs

    outRows = []
    matched = 0

    for storyID in storyIDs
      continue unless storyID?

      story = S.theLowdown("storyByID{#{storyID}}.json")?.value
      kag = S.theLowdown("kagFor{#{storyID}}.json")?.value

      continue unless story?.text?
      continue unless Array.isArray(kag?.entries)

      emotions = {}
      for entry in kag.entries
        keyword = entry?.keyword
        headline = entry?.headline
        continue unless keyword?
        continue unless headline?
        emotions[keyword] = headline

      continue unless Object.keys(emotions).length

      matched += 1

      outRows.push
        meta:
          doc_id: storyID
          paragraph_index: '001'
          title: story.title ? storyID
        text: story.text
        emotions: emotions

    console.log "[prepare_kag_segments_sqlite] segments matched:", matched
    console.log "[prepare_kag_segments_sqlite] rows written:", outRows.length

    S.make 'kag_segments', outRows
    S.done()
    return
