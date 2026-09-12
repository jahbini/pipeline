###
  select_lora_stories_ite.coffee  —  LORA_ITE pipeline step
  =====================================================
  Picks the stories to train on this cycle: prefers
  stories with the fewest training touches via the
  `loraStoryUsage.jsonl` request key, then shuffles
  within ties for diversity. The shuffle is in-place
  Fisher–Yates with `Math.random()` (no seed) — runs
  are non-deterministic by design.
###
shuffleInPlace = (rows) ->
  return rows unless Array.isArray rows
  for idx in [(rows.length - 1)..1]
    swapIdx = Math.floor Math.random() * (idx + 1)
    continue if swapIdx is idx
    temp = rows[idx]
    rows[idx] = rows[swapIdx]
    rows[swapIdx] = temp
  rows

shuffleUsageTies = (rows) ->
  return [] unless Array.isArray rows
  groups = new Map()
  orderedUseCounts = []

  for row in rows
    useCount = Number(row?.use_count ? 0)
    unless groups.has(useCount)
      groups.set useCount, []
      orderedUseCounts.push useCount
    groups.get(useCount).push row

  orderedUseCounts.sort (a, b) -> a - b

  out = []
  for useCount in orderedUseCounts
    bucket = groups.get(useCount) ? []
    shuffleInPlace bucket
    out.push bucket...
  out

@step =
  desc: "Select a small SQLite-backed story batch for LoRA training"

  action: (L) ->
    batchSize = L.param 'batch_size'
    cycleState = L.peek 'lora_cycle_state', {}
    cycleState = {} unless cycleState? and typeof cycleState is 'object' and not Array.isArray(cycleState)

    usageEntry = L.theLowdown 'loraStoryUsage.jsonl'
    usageRows = usageEntry?.value
    if usageRows is undefined
      if typeof usageEntry?.waitFor is 'function'
        usageRows = await usageEntry.waitFor()
      else if usageEntry?.notifier?
        usageRows = await usageEntry.notifier

    throw new Error "[#{stepName}] loraStoryUsage.jsonl must be an array" unless Array.isArray usageRows

    totalStories = usageRows.length
    remainingRows = []
    for row in usageRows
      useCount = row?.use_count ? 0
      continue unless row?.story_id?
      if useCount <= 0
        remainingRows.push row

    resetThisRun = false

    if remainingRows.length is 0 and cycleState.ready_for_reset is true and totalStories > 0
      resetAt = new Date().toISOString()
      console.log "[select_lora_stories_ite] previous cycle marked complete; resetting LoRA usage for a fresh full retrain"
      L.saveThis 'loraCycleReset.json',
        mode: 'full'
        reset_at: resetAt
      resetThisRun = true
      remainingRows = usageRows.slice().sort (a, b) ->
        String(a?.story_id ? '').localeCompare String(b?.story_id ? '')

    remainingRows = shuffleUsageTies remainingRows

    selectedStoryIDs = []

    for row in remainingRows
      storyID = row?.story_id
      continue unless storyID?
      selectedStoryIDs.push storyID
      break if selectedStoryIDs.length >= batchSize

    console.log "[select_lora_stories_ite] usage rows:", usageRows.length
    console.log "[select_lora_stories_ite] remaining stories:", remainingRows.length
    console.log "[select_lora_stories_ite] selected batch size:", selectedStoryIDs.length

    for storyID, idx in selectedStoryIDs
      console.log "[select_lora_stories_ite] batch[#{idx}] #{storyID}"

    remainingCount = remainingRows.length
    nextCycleState =
      total_stories: totalStories
      remaining_stories: remainingCount
      ready_for_reset: false
      reset_this_run: resetThisRun
      updated_at: new Date().toISOString()

    if selectedStoryIDs.length is 0
      # 2026-09-12: no `pipeline:shutdown` emission. When lora selection
      # drains inside a composite recipe (elementary), shutting down the
      # whole pipeline halts the outer recipe mid-flight. Just report
      # `done` with empty selection; the recipe's downstream steps see
      # zero rows and no-op, and queue_run_ite decides what runs next.
      nextCycleState.ready_for_reset = true
      nextCycleState.completed_at = new Date().toISOString()
      L.make 'lora_cycle_state', nextCycleState
      L.make 'lora_remaining_count', 0
      L.make 'selected_story_ids', []
      L.done()
      return

    L.make 'lora_cycle_state', nextCycleState
    L.make 'lora_remaining_count', remainingCount
    L.make 'selected_story_ids', selectedStoryIDs
    # Step-scoped iterate hint for long recipes. Note: train_lora is
    # a multi-step recipe (select → build → train → record), and
    # iterating THIS step alone isn't the right shape — we want the
    # OUTER queue_run_ite to re-fire the whole recipe so training
    # actually happens. So this hint is a no-op inside a bare
    # train_lora recipe (no next batch of stories is trained until
    # the current cycle completes) but useful only if train_lora is
    # embedded in a longer recipe where the caller wants the select
    # step to run again after a cycle. Kept for symmetry.
    if remainingCount > 0
      L.iterate?("#{remainingCount} stories still pending for lora selection") if false  # disabled — see comment
    L.done()
    return
