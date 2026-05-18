###
  collect_diary_kag_ite.coffee  —  DIARY_ITE pipeline step
  =====================================================
  Pulls KAG rows (keywords + headlines) from sqlite for
  the selected story and shapes them into the context
  block the diary prompt builder consumes. Uses
  `DatabaseSync` directly rather than the sqlite meta
  device because the query joins multiple request keys.
###
path = require 'path'
{ DatabaseSync } = require 'node:sqlite'

coerceJSON = (value) ->
  return value unless typeof value is 'string'
  try
    JSON.parse value
  catch
    value

splitParagraphs = (text) ->
  rawParts = String(text ? '').split /\n\s*\n/
  parts = []
  for rawPart in rawParts
    part = String(rawPart ? '').replace(/\s+/g, ' ').trim()
    continue unless part.length
    parts.push part
  parts

buildStoryGroups = (text) ->
  paragraphs = splitParagraphs text
  return [] unless paragraphs.length

  if paragraphs.length < 5
    return [
      group_index: 1
      text: paragraphs.join "\n\n"
    ]

  groups = []
  total = paragraphs.length
  baseSize = Math.floor(total / 5)
  remainder = total % 5
  startIndex = 0

  for groupIndex in [0...5]
    groupSize = baseSize
    groupSize += 1 if groupIndex < remainder
    selected = paragraphs.slice startIndex, startIndex + groupSize
    groups.push
      group_index: groupIndex + 1
      text: selected.join "\n\n"
    startIndex += groupSize

  groups

queryEmotionMatches = (db, emotionKeyword, limit, usedStoryIDs = null) ->
  return [] unless typeof emotionKeyword is 'string' and emotionKeyword.trim().length

  rows = db.prepare("""
    SELECT kag_entries.story_id, stories.title, stories.text, kag_entries.chunk_index, kag_entries.start_paragraph, kag_entries.end_paragraph, kag_entries.chunk_text, kag_entries.keyword, kag_entries.headline, kag_entries.entry_index
    FROM kag_entries
    INNER JOIN stories
      ON stories.story_id = kag_entries.story_id
    WHERE kag_entries.keyword = ?
    ORDER BY kag_entries.story_id ASC, kag_entries.chunk_index ASC, kag_entries.entry_index ASC
  """).all(emotionKeyword)

  matches = []
  seen = new Set()

  for row in rows
    storyID = String(row?.story_id ? '').trim()
    continue unless storyID.length
    continue if usedStoryIDs?.has(storyID)

    chunkIndex = Number row?.chunk_index
    continue unless Number.isFinite(chunkIndex) and chunkIndex > 0

    chunkText = String(row?.chunk_text ? '').trim()
    startParagraph = Number row?.start_paragraph
    endParagraph = Number row?.end_paragraph

    if chunkText.length is 0
      groups = buildStoryGroups row?.text ? ''
      group = groups[chunkIndex - 1]
      continue unless group?
      chunkText = group.text

    dedupeKey = "#{row.story_id}|#{chunkIndex}|#{row.keyword}|#{row.headline ? ''}"
    continue if seen.has dedupeKey
    seen.add dedupeKey

    matches.push
      story_id: storyID
      title: row.title ? null
      chunk_index: chunkIndex
      start_paragraph: if Number.isFinite(startParagraph) then startParagraph else null
      end_paragraph: if Number.isFinite(endParagraph) then endParagraph else null
      keyword: row.keyword ? null
      headline: row.headline ? null
      chunk_text: chunkText

    usedStoryIDs?.add storyID if usedStoryIDs?
    break if matches.length >= limit

  matches

flattenEntries = (eventMap) ->
  entries = []
  keywords = []
  seenKeywords = new Set()

  for own kind, payload of (eventMap ? {})
    for match in (payload?.matches ? [])
      entries.push
        story_id: match.story_id
        kind: kind
        chunk_index: match.chunk_index
        start_paragraph: match.start_paragraph
        end_paragraph: match.end_paragraph
        keyword: match.keyword
        headline: match.headline
        chunk_text: match.chunk_text

      keyword = String(match.keyword ? '').trim()
      continue unless keyword.length
      continue if seenKeywords.has keyword
      seenKeywords.add keyword
      keywords.push keyword

  { entries, keywords }

@step =
  desc: "Collect exact KAG chunk matches for the selected diary event emotions"

  action: (L) ->
    storyParts = await L.need 'story_parts'
    storyParts = coerceJSON storyParts

    throw new Error "[#{L.stepName}] story_parts must be an object" unless storyParts? and typeof storyParts is 'object' and not Array.isArray(storyParts)

    limitRaw = L.param 'per_event_match_limit'
    limit = Number limitRaw
    throw new Error "[#{L.stepName}] per_event_match_limit must be a positive integer" unless Number.isFinite(limit) and limit > 0 and Math.floor(limit) is limit

    dbPath = path.join process.cwd(), 'runtime.sqlite'
    db = new DatabaseSync dbPath
    eventMap = {}
    usedStoryIDs = new Set()

    try
      for kind in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
        selectedEmotion = String(L.param("#{kind}_emotion", '') ? '').trim()
        matches = queryEmotionMatches db, selectedEmotion, limit, usedStoryIDs
        eventMap[kind] =
          kind: kind
          selected_emotion: selectedEmotion
          matches: matches
    finally
      try db.close() catch then null

    flattened = flattenEntries eventMap

    payload =
      story_id: null
      keywords: flattened.keywords
      entries: flattened.entries
      events: eventMap

    for own kind, row of eventMap
      console.log "[collect_diary_kag_ite] #{kind} emotion:", row.selected_emotion ? ''
      console.log "[collect_diary_kag_ite] #{kind} matches:", row.matches.length

    L.make 'diary_kag', payload
    L.done()
    return
