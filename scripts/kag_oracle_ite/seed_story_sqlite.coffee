###
  seed_story_sqlite.coffee  —  ORACLE_ITE pipeline step
  =====================================================
  Ingests raw markdown stories from `stories_md` and
  seeds them into the sqlite `stories` table via the
  `storyByID{...}.json` request key. The `clean()`
  helper is the canonical markdown→training-text filter
  — note the existing `HEY GPT!` directive flagging it
  for reuse by future ingestion work (this is the same
  dual-audience-comment pattern called out in MEMORY).
###
clean = (txt) ->
  # HEY GPT! This older md2segments-style cleaner is the canonical
  # markdown-to-plain-text filter for training-quality story ingress.
  # Reuse this behavior for future markdown source normalization work.
  s = String(txt ? '')
  s = s.replace(/{{{First Name}}}/g, 'friend')
  s = s.replace(/https?:\/\/\S+/g, '')
  s = s.replace(/&(rsquo|lsquo|apos|#39);/gi, "'")
  s = s.replace(/&(rdquo|ldquo|quot);/gi, '"')
  s = s.replace(/&[a-zA-Z#0-9]+;/g, ' ')
  s = s.replace(/\[([^\]]+)\]\[\d+\]/g, '$1')
  s = s.replace(/\[\d+\]/g, '')
  s = s.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
  s = s.replace(/[_*]{1,3}([^*_]+)[_*]{1,3}/g, '$1')
  s = s.replace(/ {2,}/g, ' ')
  lines = s.split /\r?\n/
  lines = (line for line in lines when not /^:\s*$/.test(String(line ? '').trim()))
  while lines.length
    line = String(lines[lines.length - 1] ? '').trim()
    break unless /^:\s*https?:\/\/\S+\s*$/.test(line) or /^https?:\/\/\S+\s*$/.test(line)
    lines.pop()
  s = lines.join("\n").trim()
  s

safe = (title) ->
  String(title ? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '') or 'untitled'

@step =
  desc: "Seed storyByID sqlite records from markdown stories"

  action: (S) ->
    existingStories = S.theLowdown('allStories.jsonl')?.value
    existingStories = [] unless Array.isArray existingStories

    if existingStories.length > 0
      storyIDs = []
      for story in existingStories
        storyID = story?.story_id
        continue unless storyID?
        storyIDs.push storyID
      console.log "[seed_story_sqlite] sqlite already seeded, stories:", storyIDs.length
      S.make 'story_seed_ids', storyIDs
      S.done()
      return

    raw = await S.need 'stories_md'
    # No prescreen on `raw`'s type — per GPT/CONVENTIONS.md ("No
    # parameter prescreens") and GPT/pipeline_runner.md's "No
    # fallbacks, no prechecks" design standard. If the artifact
    # resolves to a non-string, the downstream `raw.split` throws a
    # native TypeError with a useful stack — the prescreen here
    # produced nothing the natural error wouldn't, and the doc
    # already calls out "do not add brittle pre-checks that block
    # fresh DB seeding" as a known pitfall.
    lines = raw.split /\r?\n/
    stories = []
    currentTitle = null
    buffer = []

    flushStory = ->
      return unless currentTitle? and buffer.length
      text = clean buffer.join("\n")
      if text.length
        stories.push
          story_id: safe(currentTitle)
          title: currentTitle
          text: text
      buffer = []

    for line in lines
      if line.startsWith '# '
        flushStory()
        currentTitle = line.slice(2).trim()
      else
        buffer.push line

    flushStory()

    storyIDs = []
    for story in stories
      S.saveThis "storyByID{#{story.story_id}}.json", story
      storyIDs.push story.story_id

    console.log "[seed_story_sqlite] stories seeded:", storyIDs.length
    S.make 'story_seed_ids', storyIDs
    S.done()
    return
