#!/usr/bin/env coffee
###
       step8_sqlite.coffee  —  TEST PIPELINE  ·  the sqlite meta in action
       =====================================================

  **What this step teaches.** End-to-end exercise of the
  `meta/sqlite.coffee` request-key model. The step writes
  through four different request keys, reads them back, and
  validates the projections — all using the same `M.saveThis` /
  `M.theLowdown` calls a step would use for any meta device.

  **No file path appears in this script.** Notice there is no
  `fs.writeFileSync` or `sqlite3.open` here — the script just
  writes memo keys like `storyByID{abc-123}.json` and lets the
  sqlite meta device do the SQL. That's the load-bearing
  abstraction: **a step never reaches the disk directly**, it
  always goes through Memo, and the meta device decides what
  "disk" means.

  **The keys exercised:**
  - `storyByID{...}.json` — single-row insert/select
  - `partsFor{...}.json` — single-row insert/select with nested
  - `kagFor{...}.json` — multi-row insert with transaction
  - `storiesWithKag{fear}.jsonl` — join, read-only projection
  - `storiesMissingKag.jsonl` — anti-join, read-only projection
  - `storyByID{...}.txt` — same row, different formatter
###
fs = require 'fs'
path = require 'path'

findByStoryID = (rows, storyID) ->
  return null unless Array.isArray rows
  for row in rows
    return row if row?.story_id is storyID
  null

@step =
  name: 'step8_sqlite'
  desc: 'Validate sqlite-backed meta request keys and projections.'

  action: (M, stepName) ->
    inputKey = "python_result"
    inputEntry = M.theLowdown inputKey
    inputVal = inputEntry?.value
    if inputVal is undefined
      if typeof inputEntry?.waitFor is 'function'
        inputVal = await inputEntry.waitFor()
      else if inputEntry?.notifier?
        inputVal = await inputEntry.notifier
    throw new Error "[#{stepName}] Missing input key '#{inputKey}'" if inputVal is undefined

    withKagStoryID = 'sql_test_with_kag'
    withoutKagStoryID = 'sql_test_without_kag'

    storyWithKag =
      story_id: withKagStoryID
      title: 'SQLite Test With KAG'
      text: 'A storm rolled in, but the coffee improved matters.'

    storyWithoutKag =
      story_id: withoutKagStoryID
      title: 'SQLite Test Missing KAG'
      text: 'This story exists without any KAG rows.'

    partsPayload =
      story_id: withKagStoryID
      parts:
        scene: 'dock'
        arrival: 'friend'
        disturbance: 'storm'
        reflection: 'hmm'
        realization: 'aha'

    kagPayload =
      story_id: withKagStoryID
      entries: [
        {
          meta:
            doc_id: withKagStoryID
            paragraph_index: '001'
          keyword: 'fear'
          headline: 'storm rolls in'
        }
        {
          meta:
            doc_id: withKagStoryID
            paragraph_index: '002'
          keyword: 'joy'
          headline: 'coffee helps'
        }
      ]
      keywords: ['fear', 'joy']

    M.saveThis "storyByID{#{withKagStoryID}}.json", storyWithKag
    M.saveThis "storyByID{#{withoutKagStoryID}}.json", storyWithoutKag
    M.saveThis "partsFor{#{withKagStoryID}}.json", partsPayload
    M.saveThis "kagFor{#{withKagStoryID}}.json", kagPayload

    storyRead = M.theLowdown("storyByID{#{withKagStoryID}}.json")?.value
    partsRead = M.theLowdown("partsFor{#{withKagStoryID}}.json")?.value
    kagRead = M.theLowdown("kagFor{#{withKagStoryID}}.json")?.value
    storiesWithFear = M.theLowdown("storiesWithKag{fear}.jsonl")?.value
    storiesMissingKag = M.theLowdown("storiesMissingKag.jsonl")?.value
    storyTxt = M.theLowdown("storyByID{#{withKagStoryID}}.txt")?.value

    throw new Error "[#{stepName}] sqlite story read failed" unless storyRead?.story_id is withKagStoryID
    throw new Error "[#{stepName}] sqlite parts read failed" unless partsRead?.parts?.scene is 'dock'
    throw new Error "[#{stepName}] sqlite kag read failed" unless Array.isArray(kagRead?.entries) and kagRead.entries.length is 2
    throw new Error "[#{stepName}] sqlite keyword projection failed" unless Array.isArray(kagRead?.keywords) and kagRead.keywords.includes('fear')
    throw new Error "[#{stepName}] sqlite storiesWithKag projection failed" unless findByStoryID(storiesWithFear, withKagStoryID)?
    throw new Error "[#{stepName}] sqlite storiesMissingKag projection failed" unless findByStoryID(storiesMissingKag, withoutKagStoryID)?
    throw new Error "[#{stepName}] sqlite txt projection failed" unless typeof storyTxt is 'string' and storyTxt.includes(withKagStoryID)

    sqlitePath = path.join process.cwd(), 'runtime.sqlite'

    summary =
      status: 'ok'
      sqlite_file: sqlitePath
      sqlite_exists: fs.existsSync sqlitePath
      checked_story_id: withKagStoryID
      checked_missing_story_id: withoutKagStoryID
      stories_with_fear_count: if Array.isArray(storiesWithFear) then storiesWithFear.length else 0
      stories_missing_kag_count: if Array.isArray(storiesMissingKag) then storiesMissingKag.length else 0
      story_read: storyRead
      parts_read: partsRead
      kag_read: kagRead
      txt_preview: String(storyTxt ? '').slice(0, 120)

    M.saveThis "sql_validation", summary
    M.saveThis "done:#{stepName}", true
    console.log "[#{stepName}] sqlite meta validation passed"
    return
