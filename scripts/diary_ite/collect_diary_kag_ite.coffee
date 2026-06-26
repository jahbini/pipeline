###
  collect_diary_kag_ite.coffee  —  DIARY_ITE pipeline step
  =====================================================
  Pulls KAG rows (keywords + headlines) from sqlite for
  the selected diary events and shapes them into the context
  block the diary prompt builder consumes.

  Reads kag-joined-to-story rows via the meta layer's
  `kagByKeyword{<keyword>}.jsonl` request. The per-step business
  logic (cross-iteration dedup of story IDs, regenerating chunk_text
  from story.text when the legacy row's chunk_text is empty,
  dedup by chunk identity, per-event match limit) stays here —
  only the SQL moved out.

  Migration history: through 2026-06-25 this step opened
  `runtime.sqlite` directly via `node:sqlite` `DatabaseSync`, with
  a header comment claiming the JOIN required bypassing the meta
  layer. That was a misreading — the right fix was a new request
  key, not a second DB connection. Migrated 2026-06-26; see
  GPT/CONVENTIONS.md § "fs stinginess in step scripts" for the
  rule and `GPT/diary_ite/collect_diary_kag_ite.md` for context.
###

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

# Apply the diary's per-emotion match-selection rules to a raw list
# of kag-rows. Returns at most `limit` matches; mutates `usedStoryIDs`
# so subsequent emotions in the same diary skip stories already used.
selectMatches = (rows, limit, usedStoryIDs = null) ->
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

    eventMap = {}
    usedStoryIDs = new Set()

    for kind in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
      selectedEmotion = String(L.param("#{kind}_emotion", '') ? '').trim()
      rows = if selectedEmotion.length
        L.theLowdown("kagByKeyword{#{selectedEmotion}}.jsonl")?.value ? []
      else
        []
      matches = selectMatches rows, limit, usedStoryIDs
      eventMap[kind] =
        kind: kind
        selected_emotion: selectedEmotion
        matches: matches

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
