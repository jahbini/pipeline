###
  reset_base_environment_ite.coffee  —  BASE_ITE pipeline step
  =============================================================
  First step of the `reset` recipe. Wipes stale training artifacts
  and per-run bookkeeping as directed by the human via checkbox
  params from the reset recipe's UI.

  2026-09-13 rewrite. Prior versions unconditionally wiped
  `build/adapter/` on every run, which — combined with the sqlite
  guard that preserves `lora_training_run_stories` — made every
  elementary retry a self-defeating loop (see
  `~/pipeline/GPT/base_ite/reset_recipe.md` for the failure
  fingerprint). Now:

    Default (no force flags):
      · Wipe only transient out/*.json files (cheap, prevents
        stale reads on next launch).
      · If sqlite doesn't exist or is empty, fire `sqliteResetAll`
        to initialize the schema. This is the newborn bootstrap
        path; a populated sqlite is left alone.

    force_lora_reset: true
      · Wipe build/adapter, build/adapter_llm, build/model_fused_llm.
      · Fire `loraCycleReset` — clears lora_training_runs,
        lora_training_run_stories, lora_story_usage,
        lora_trained_stories.
      · Preserves kag_entries + stories.

    force_oracle_reset: true
      · Fire `oracleReset` — clears kag_entries, both embedding
        tables, story_simplifications, oracle_story_attempts,
        expanded_story_parts, story_parts.
      · Preserves stories + lora_*.

    force_download: true
      · Wipe build/model and build/model4. Forces the next
        download_model + quantize_model to re-run in full.
      · Use when the source repo changed or a corrupt download
        needs replacing.

    force_full_reset: true
      · Fire `sqliteResetAll` (nukes everything including stories).
      · Wipe every build/* dir.
      · Equivalent to the pre-2026-09-11 aggressive reset.
      · Only use if you truly want to start over from a fresh pipe.

  Runs inside a pipe's CWD (pipes/<pipe>/). Paths are relative to
  that CWD, so this only cleans the current pipe.
###
fs = require 'fs'
path = require 'path'

removePath = (baseDir, relativePath) ->
  fullPath = path.join(baseDir, relativePath)
  return false unless fs.existsSync fullPath
  fs.rmSync fullPath, recursive: true, force: true
  true

@step =
  desc: "Reset stale artifacts under human-selected checkboxes (default: preserve everything)"

  action: (S) ->
    baseDir = process.cwd()

    forceLoraReset   = !!S.param('force_lora_reset',   false)
    forceOracleReset = !!S.param('force_oracle_reset', false)
    forceDownload    = !!S.param('force_download',     false)
    forceFullReset   = !!S.param('force_full_reset',   false)

    now = -> new Date().toISOString()

    # --- sqlite: bootstrap vs. targeted vs. full wipe ---------------
    sqliteAlive = false
    sqliteHasWork = false
    try
      { DatabaseSync } = require 'node:sqlite'
      dbPath = path.join(baseDir, 'runtime.sqlite')
      if fs.existsSync(dbPath)
        db = new DatabaseSync(dbPath)
        sqliteAlive = true
        try
          row = db.prepare("SELECT COUNT(*) AS c FROM stories").get()
          sqliteHasWork = Number(row?.c ? 0) > 0
        catch
          sqliteHasWork = false
        try db.close() catch then null
    catch
      sqliteAlive = false

    if forceFullReset
      console.log "[reset_base_environment_ite] force_full_reset — firing sqliteResetAll"
      S.saveThis 'sqliteResetAll.json', {mode: 'full', reset_at: now()}
    else if not sqliteAlive or not sqliteHasWork
      console.log "[reset_base_environment_ite] sqlite empty or absent — firing sqliteResetAll (bootstrap)"
      S.saveThis 'sqliteResetAll.json', {mode: 'full', reset_at: now()}
    else
      # sqlite has real work; only fire targeted resets the human asked for.
      if forceOracleReset
        console.log "[reset_base_environment_ite] force_oracle_reset — firing oracleReset"
        S.saveThis 'oracleReset.json', {reset_at: now()}
      if forceLoraReset
        console.log "[reset_base_environment_ite] force_lora_reset — firing loraCycleReset"
        S.saveThis 'loraCycleReset.json', {mode: 'lora', reset_at: now()}
      if not (forceOracleReset or forceLoraReset)
        console.log "[reset_base_environment_ite] sqlite preserved — no force flags set"

    # --- filesystem cleanup: transient always, force-gated for the rest ---
    transientOut = [
      'out/story_seed_ids.json'
      'out/new_story_ids.json'
      'out/oracle_remaining_count.json'
      'out/rejects.jsonl'
      'out/viewed.jsonl'
      'out/lora_cycle_state.json'
      'out/lora_remaining_count.json'
      'out/selected_story_ids.json'
      'out/lora_train.txt'
      'out/lora_run_record.json'
      'out/trained_story_ids.json'
    ]
    loraArtifacts = [
      'build/adapter'
      'build/adapter_llm'
      'build/train'
      'build/model_fused_llm'
    ]
    modelArtifacts = [
      'build/model'
      'build/model4'
    ]

    cleanupTargets = transientOut.slice()
    if forceLoraReset or forceFullReset
      cleanupTargets.push loraArtifacts...
    if forceDownload or forceFullReset
      cleanupTargets.push modelArtifacts...

    removed = []
    for relativePath in cleanupTargets
      if removePath(baseDir, relativePath)
        removed.push relativePath
        console.log "[reset_base_environment_ite] removed #{relativePath}"

    console.log "[reset_base_environment_ite] flags: lora=#{forceLoraReset} oracle=#{forceOracleReset} download=#{forceDownload} full=#{forceFullReset}"
    console.log "[reset_base_environment_ite] removed count:", removed.length
    S.done()
    return
