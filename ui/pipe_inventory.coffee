# pipe_inventory — canonical writer-pipe inventory probe (MARRIAGE Stage B).
#
# ONE copy of the filesystem+sqlite scan that reports, per writer pipe:
# model / download / quantization state, kag counts, oracle·lora·reembed
# remaining-work, live-run flag, recipe_manifest. Exposed to plugins via
# `ctx.pipeInventory` (see pipeline/ui_server.coffee). Two consumers:
#
#   - the WRITER plugin runs INVENTORY_BASH LOCALLY on a timer and
#     publishes the parsed array to the memo key `sys/pipe_inventory/<host>`
#     (the puppet announcing its own inventory — cheap local I/O, no SSH).
#   - the PUPPETEER plugin runs it over SSH (SshDispatcher.bash) as the
#     FALLBACK when the broker snapshot is absent/stale.
#
# The script keys off `$HOME/writer/pipes`, so the SAME text is correct
# both locally (writer host) and over SSH (resolved on the peer). Keep
# INVENTORY_BASH and parse() in lockstep — the tab column order is the
# contract between them.

# Bash scan. Tab-separated columns, one line per pipe. `set -e` + the
# per-command `|| echo` guards keep a single bad pipe from aborting the
# sweep. NOTE: `\\n`/`\\t` are deliberate literal backslash-escapes for
# bash printf/tr — do not "fix" them to real newlines.
INVENTORY_BASH = '''
  set -e
  MODELS_ROOT="${MODELS:-/Volumes/bigbig/models}"
  PIPES_ROOT="$HOME/writer/pipes"
  for d in "$PIPES_ROOT"/*/; do
    name=$(basename "$d")
    model=$(awk '/^  model:/ {print $2; exit}' "$d/override.yaml" 2>/dev/null || echo "")
    dl_dir="$MODELS_ROOT/$model"
    q_dir="$MODELS_ROOT/${model}-mlx4"
    downloaded=$([ -d "$dl_dir" ] && echo 1 || echo 0)
    quantized=0
    if [ -d "$q_dir" ] || [ -L "$q_dir" ]; then
      if [ -f "$q_dir/config.json" ] && grep -q '"quantization"' "$q_dir/config.json" 2>/dev/null; then
        quantized=1
      else
        quantized=2
      fi
    fi
    db="$d/runtime.sqlite"
    kag_rows=0
    emb_clean_rows=0
    kag_total=0
    if [ -f "$db" ]; then
      kag_rows=$(sqlite3 "$db" "SELECT COUNT(DISTINCT doc_id) FROM kag_entries" 2>/dev/null || echo 0)
      kag_total=$(sqlite3 "$db" "SELECT COUNT(*) FROM kag_entries" 2>/dev/null || echo 0)
      emb_clean_rows=$(sqlite3 "$db" "SELECT COUNT(*) FROM kag_embeddings_clean" 2>/dev/null || echo 0)
    fi
    oracle_remaining="-"
    lora_remaining="-"
    reembed_remaining="-"
    if [ -f "$db" ]; then
      oracle_remaining=$(sqlite3 "$db" "SELECT COUNT(*) FROM stories WHERE NOT EXISTS (SELECT 1 FROM kag_entries WHERE kag_entries.story_id=stories.story_id)" 2>/dev/null || echo -)
      [ -z "$oracle_remaining" ] && oracle_remaining="-"
      reembed_remaining=$(sqlite3 "$db" "SELECT COUNT(*) FROM stories WHERE EXISTS (SELECT 1 FROM kag_entries WHERE kag_entries.story_id=stories.story_id) AND (SELECT COUNT(DISTINCT chunk_index) FROM kag_embeddings_clean WHERE kag_embeddings_clean.story_id=stories.story_id) < (SELECT COUNT(DISTINCT chunk_index) FROM kag_entries WHERE kag_entries.story_id=stories.story_id)" 2>/dev/null || echo -)
      [ -z "$reembed_remaining" ] && reembed_remaining="-"
      lora_remaining=$(sqlite3 "$db" "SELECT COUNT(*) FROM stories WHERE NOT EXISTS (SELECT 1 FROM lora_training_run_stories WHERE lora_training_run_stories.story_id=stories.story_id)" 2>/dev/null || echo -)
      [ -z "$lora_remaining" ] && lora_remaining="-"
    fi
    running=0
    run_pipeline=""
    urun="$d/state/ui-run.json"
    if [ -f "$urun" ]; then
      pid=$(jq -r ".pid // empty" "$urun" 2>/dev/null)
      st=$(jq -r ".status // empty" "$urun" 2>/dev/null)
      run_pipeline=$(jq -r ".pipeline // empty" "$urun" 2>/dev/null)
      if [ -n "$pid" ] && [ "$st" = "running" ]; then
        if kill -0 "$pid" 2>/dev/null; then running=1; fi
      fi
    fi
    manifest_json="{}"
    if [ -f "$d/recipe_manifest.json" ]; then
      manifest_json=$(cat "$d/recipe_manifest.json" 2>/dev/null | tr -d '\\n' | tr '\\t' ' ')
      [ -z "$manifest_json" ] && manifest_json="{}"
    fi
    # Portfolio (writer/GPT/portfolio.md): the generated-data subset of the
    # pipe dir — out/ diary/ build/ runtime.sqlite. Read-only counts/size so
    # the puppeteer can report each writer pipe's portfolio through this one
    # canonical scanner (no second scanner, no writes into the pipe).
    out_count=$([ -d "$d/out" ] && find "$d/out" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    diary_count=$([ -d "$d/diary" ] && find "$d/diary" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    build_count=$([ -d "$d/build" ] && find "$d/build" -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    sqlite_bytes=$([ -f "$db" ] && { stat -f%z "$db" 2>/dev/null || stat -c%s "$db" 2>/dev/null || echo 0; } || echo 0)
    # Per-stage "test already ran" flags, for the cert-pending chip (the
    # certificate marker means a human must GRADE, not re-run the test when
    # its output artifacts already exist). Entrance test (newborn recipe)
    # writes out/story_seed_ids.json; the SAT/elementary ladder writes
    # out/elementary_verdict.yaml.
    entrance_done=$([ -f "$d/out/story_seed_ids.json" ] && echo 1 || echo 0)
    sat_done=$([ -f "$d/out/elementary_verdict.yaml" ] && echo 1 || echo 0)
    printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$name" "$model" "$downloaded" "$quantized" "$kag_rows" "$running" "$run_pipeline" "$manifest_json" "$oracle_remaining" "$lora_remaining" "$kag_total" "$reembed_remaining" "$emb_clean_rows" "$out_count" "$diary_count" "$build_count" "$sqlite_bytes" "$entrance_done" "$sat_done"
  done
'''

# Parse the tab output into the canonical pipe objects peer_pipes consumes.
parse = (raw) ->
  pipes = []
  parseCount = (s) ->
    return null unless s? and s.length and s isnt '-'
    n = Number(s)
    if Number.isFinite(n) then n else null
  for line in String(raw ? '').split('\n')
    parts = line.split('\t')
    continue unless parts.length >= 5 and parts[0].length
    qState =
      if parts[3] is '1' then 'real'
      else if parts[3] is '2' then 'fallback'
      else 'none'
    manifest = {}
    if parts[7]?
      try manifest = JSON.parse(parts[7]) catch then manifest = {}
    pipes.push
      name:              parts[0]
      model:             parts[1]
      downloaded:        parts[2] is '1'
      quantized:         qState is 'real'
      quantized_state:   qState
      kag_rows:          Number(parts[4] ? 0)
      pid_alive:         parts[5] is '1'
      pipeline_running:  parts[6] or null
      recipe_manifest:   manifest
      oracle_remaining:  parseCount(parts[8])
      lora_remaining:    parseCount(parts[9])
      kag_total:         parseCount(parts[10]) ? 0
      reembed_remaining: parseCount(parts[11])
      emb_clean_count:   parseCount(parts[12]) ? 0
      # Portfolio counts/size (parts[13..16]). Additive: a peer still running
      # the old 13-column scanner yields undefined here → 0, never a crash.
      portfolio:
        out_files:    parseCount(parts[13]) ? 0
        diary_files:  parseCount(parts[14]) ? 0
        build_files:  parseCount(parts[15]) ? 0
        sqlite_bytes: parseCount(parts[16]) ? 0
      # Per-stage test-ran flags (parts[17..18]) for the cert-pending chip.
      # Absent on an old peer's 17-column line → false → chip falls back to
      # "launch test" (prior behavior), never a crash.
      entrance_done: parts[17] is '1'
      sat_done:      parts[18] is '1'
  pipes

module.exports = {INVENTORY_BASH, parse}
