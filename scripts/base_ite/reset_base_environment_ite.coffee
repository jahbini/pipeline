###
  reset_base_environment_ite.coffee  —  BASE_ITE pipeline step
  =============================================================
  First step of the base_ite bootstrap chain. Wipes stale
  training artifacts and per-run bookkeeping so the downstream
  download/quantize/seed steps start from a clean slate.

  Also fires the `sqliteResetAll.json` request key so the meta
  layer can reset the sqlite corpus (see meta/sqlite.coffee for
  how the runtime.sqlite is truncated on this request).

  Runs inside a pipe's CWD (pipes/<pipe>/). Paths are relative
  to that CWD, so this only cleans the current pipe — other
  pipes are untouched.
###
fs = require 'fs'
path = require 'path'

removePath = (baseDir, relativePath) ->
  fullPath = path.join(baseDir, relativePath)
  return false unless fs.existsSync fullPath
  fs.rmSync fullPath, recursive: true, force: true
  true

@step =
  desc: "Reset stale DB and training artifacts before base_ite seeds a fresh environment"

  action: (S) ->
    baseDir = process.cwd()

    S.saveThis 'sqliteResetAll.json',
      mode: 'full'
      reset_at: new Date().toISOString()

    # Do NOT wipe build/model or build/model4. Those are the outputs of
    # download_model + quantize_model — both are idempotent (download is
    # git+lfs provenance-checked; quantize skips when target already has
    # a matching quantization block). Wiping them would force a full
    # re-download + re-quantize on every base_ite run, which is minutes
    # to hours of avoidable work.
    #
    # The fused-model dir IS wiped because it's derived from an adapter
    # that reset itself removes — the two must stay consistent.
    cleanupTargets = [
      'build/adapter'
      'build/adapter_llm'
      'build/train'
      'build/model_fused_llm'
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

    removed = []
    for relativePath in cleanupTargets
      if removePath(baseDir, relativePath)
        removed.push relativePath
        console.log "[reset_base_environment_ite] removed #{relativePath}"

    console.log "[reset_base_environment_ite] removed count:", removed.length
    S.done()
    return
