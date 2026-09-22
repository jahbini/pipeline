#!/usr/bin/env coffee
# mlx/helper_train.coffee
# ---------------------------------------------------------------------------
# Training scaffold for the puppeteer's local "helper" LLM (see
# ~/puppeteer/GPT/helper_llm_plan.md).
#
# Three subcommands, invoked from CLI:
#   bootstrap  — run the current helper against unlabeled puppeteer data
#                (spawn_log rows) and store the model's predictions in a
#                new sqlite table for human review.
#   train      — read HUMAN-APPROVED training examples from that table
#                (or a JSONL), write train.jsonl + valid.jsonl in the
#                shape mlx_lm.lora expects, and fine-tune a LoRA adapter
#                on Qwen3-1.7B-Instruct.
#   eval       — load the trained adapter and score it on a held-out
#                subset. Prints accuracy per capability.
#
# The training data schema lives in puppeteer/runtime.sqlite:
#
#   CREATE TABLE helper_training_examples (
#     id             INTEGER PRIMARY KEY AUTOINCREMENT,
#     capability     TEXT NOT NULL,          -- classify_failure | summarize_log
#     input          TEXT NOT NULL,          -- what the caller feeds the helper
#     expected_output TEXT NOT NULL,         -- JSON string, ideal helper reply
#     source         TEXT NOT NULL,          -- bootstrap | human | correction
#     created_at     TEXT NOT NULL,
#     approved_by    TEXT,                   -- NULL until human blesses
#     approved_at    TEXT,
#     UNIQUE (capability, input)
#   );
#
# Bootstrap fills the table with the model's own guesses; the human
# reviews and updates `approved_by` (and possibly edits
# `expected_output`) to teach the model where its guesses were wrong.
# Only rows with `approved_by IS NOT NULL` are used for training.
#
# The trained adapter lives at ~/pipeline/mlx/helper_lora/adapter/ by
# default; the runtime `helper_llm.coffee` picks it up automatically
# if HELPER_LLM_ADAPTER_PATH is set (defaults to that path).
#
# CLI:
#   coffee helper_train.coffee bootstrap [--limit N] [--capability C]
#   coffee helper_train.coffee train    [--iters N] [--lr X] [--rank R]
#   coffee helper_train.coffee eval     [--adapter PATH]

fs   = require 'fs'
path = require 'path'
os   = require 'os'
{ DatabaseSync } = require 'node:sqlite'

# --- paths -----------------------------------------------------------------
DEFAULT_MODEL_DIR   = process.env.HELPER_LLM_MODEL_DIR ? '/Users/jahbini/models/Qwen/Qwen3-1.7B-mlx4'
DEFAULT_PUPPET_DB   = process.env.PUPPETEER_DB ? '/Users/jahbini/puppeteer/runtime.sqlite'
DEFAULT_TRAIN_DIR   = process.env.HELPER_LORA_TRAIN_DIR ? path.join(__dirname, 'helper_lora', 'train')
DEFAULT_ADAPTER_DIR = process.env.HELPER_LLM_ADAPTER_PATH ? path.join(__dirname, 'helper_lora', 'adapter')

# --- sqlite bootstrap ------------------------------------------------------
openDb = (dbPath = DEFAULT_PUPPET_DB) ->
  throw new Error "puppeteer DB not found: #{dbPath}" unless fs.existsSync dbPath
  db = new DatabaseSync(dbPath)
  db.exec """
    CREATE TABLE IF NOT EXISTS helper_training_examples (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      capability      TEXT NOT NULL,
      input           TEXT NOT NULL,
      expected_output TEXT NOT NULL,
      source          TEXT NOT NULL,
      created_at      TEXT NOT NULL,
      approved_by     TEXT,
      approved_at     TEXT,
      UNIQUE (capability, input)
    );
    CREATE INDEX IF NOT EXISTS idx_hte_cap      ON helper_training_examples (capability);
    CREATE INDEX IF NOT EXISTS idx_hte_approved ON helper_training_examples (approved_by);
  """
  db

# --- prompt scaffolds (mirror runtime helper_llm.coffee EXACTLY) ----------
# Any drift between these prompts and the runtime prompts would mean the
# trained adapter is optimizing for one shape and the caller uses another.
# Keep in sync when helper_llm.coffee grows new capabilities.

FAILURE_CATEGORIES = [
  'too_big', 'recipe_bug', 'soft_limit', 'thermal_timeout', 'oom',
  'no_adapter', 'metal_abort', 'network', 'unknown'
]

SCHEDULE_ACTIONS = [
  'reset', 'launch', 'hospitalize', 'graduate', 'reject', 'wait',
  'raise_ceiling', 'kill', 'escalate'
]

promptFor =
  # 2026-09-16: schedule prompt — MIRRORS helper_llm.coffee `schedule()`.
  # Any change to the runtime shape must land here in the same commit,
  # or trained rows will train the model to answer a different prompt
  # than inference sends.
  schedule: (input) ->
    scenarioText =
      if typeof input is 'string' then input
      else JSON.stringify(input, null, 2)
    """
    You are a scheduling adviser for a puppeteer that runs LoRA training
    and evaluation recipes on peer machines. Given one pipe's recent
    session history and current state, reply with exactly one JSON
    object on one line — no prose, no markdown, no code fences.

    Allowed actions (pick exactly ONE):
      #{SCHEDULE_ACTIONS.join(', ')}

    Reply shape (all five keys required):
      {"action": "<one of the above>", "target_pipe": "<pipe name>", "target_recipe": "<recipe name or null>", "confidence": <0.0 to 1.0>, "reason": "<one paragraph explaining WHY, citing specific rows from recent_sessions and any state markers>"}

    Scenario:
    #{scenarioText}
    Output:
  """

  classify_failure: (errorText) -> """
    You are a pipeline-failure classifier. Read the error text below and
    reply with exactly one JSON object on one line — no prose, no markdown,
    no code fences.

    Allowed categories (pick exactly ONE):
      #{FAILURE_CATEGORIES.join(', ')}

    Reply shape (all three keys required):
      {"category": "<one of the above>", "confidence": <0.0 to 1.0>, "summary": "<one short sentence>"}

    Error text:
    #{String(errorText ? '').trim()}
  """
  summarize_log: (logTail) -> """
    You are a log-summarizer for a machine-learning pipeline. Read the log
    tail below and reply with exactly one JSON object on one line — no
    prose, no markdown, no code fences.

    Reply shape (single required key):
      {"summary": "<one or two sentences that explain what went wrong and where>"}

    Rules:
      - Focus on the LAST failure signal — earlier lines are usually setup.
      - Name the step or component if it's identifiable.
      - Prefer 60–160 characters. Never exceed 240.
      - If the log looks like a clean completion (no failure), summarize
        the outcome instead ("recipe completed X of Y stories", etc.).

    Log tail:
    #{String(logTail ? '').trim()}
  """

# --- Qwen ChatML wrap ------------------------------------------------------
# `mlx_lm.lora`-style completion training under --mask-prompt means the
# adapter learns to produce the assistant turn only. The training data
# format is `{prompt, completion}` where prompt is the FULL user-visible
# task text and completion is the assistant's ideal JSON reply.
#
# `run_lora_train_ite.coffee` reads `train.jsonl` / `valid.jsonl` from
# the `dataDir` we pass. Row shape:
#   {"prompt": "<user text>", "completion": "<assistant JSON>"}
#
# The trainer's `buildBatch` renders the ChatML wrapping around them
# so we DON'T include `<|im_start|>` here — that would double-wrap.
buildTrainingRow = (capability, input, expectedOutput) ->
  prompt = promptFor[capability]?(input)
  throw new Error "unknown capability: #{capability}" unless prompt?
  # 2026-09-14: bake the same <think>…</think> directive prefill into
  # every training row that inference will inject.
  # `helper_llm.thinkPrefillFor` is the single source of truth for
  # both training and inference so drift is impossible.
  helperMod =
    try require './helper_llm'
    catch then null
  prefill = String(helperMod?.thinkPrefillFor?[capability] ? '').trim()
  # 2026-09-14: `mlx/lora/train.coffee:60` reads only obj.text (or
  # obj.completion as fallback) — obj.prompt is DISCARDED. Concatenate
  # into one `text` field so the model learns to complete the JSON
  # answer given the full ChatML context.
  # The ChatML wrap mirrors what session_api produces at inference:
  #   <|im_start|>user\n[task]<|im_end|>\n<|im_start|>assistant\n
  #   <think>\n[rules]\n</think>\n\n[completion]<|im_end|>
  # No mask-prompt, so the model also learns to reproduce the prompt
  # tokens — wasteful at scale but harmless for tiny helper datasets.
  chatml = """
    <|im_start|>user
    #{prompt}<|im_end|>
    <|im_start|>assistant
  """
  thinkBlock =
    if prefill.length > 0
      "\n<think>\n#{prefill}\n</think>\n\n"
    else
      "\n"
  fullText = "#{chatml}#{thinkBlock}#{expectedOutput}<|im_end|>"
  { text: fullText }

# --- bootstrap -------------------------------------------------------------
# Read every distinct spawn_log.error_text with status='error' that
# doesn't already have a helper_training_examples row, run the current
# helper on each, and INSERT a `bootstrap`-source row with approved_by=null.
# The human then approves/edits and re-runs `train`.
bootstrap = (opts = {}) ->
  helper = require './helper_llm'
  db = openDb(opts.dbPath)
  limit = Number(opts.limit ? 500)
  targetCapability = String(opts.capability ? 'classify_failure')

  # Only classify_failure has a natural spawn_log source. summarize_log
  # bootstrap would want a log-file corpus — not covered here.
  unless targetCapability is 'classify_failure'
    console.error "[bootstrap] only classify_failure supported (got #{targetCapability})"
    process.exit 2

  # Pull errored spawn rows the helper hasn't seen yet.
  rows = db.prepare("""
    SELECT DISTINCT error_text
      FROM spawn_log
     WHERE status = 'error'
       AND error_text IS NOT NULL
       AND LENGTH(TRIM(error_text)) > 0
       AND error_text NOT IN (SELECT input FROM helper_training_examples WHERE capability = ?)
     LIMIT ?
  """).all(targetCapability, limit)

  console.log "[bootstrap] #{rows.length} new distinct error strings to classify"
  return db.close() unless rows.length

  insert = db.prepare("""
    INSERT OR IGNORE INTO helper_training_examples
      (capability, input, expected_output, source, created_at, approved_by, approved_at)
    VALUES (?, ?, ?, 'bootstrap', ?, NULL, NULL)
  """)

  now = new Date().toISOString()
  written = 0
  for row, i in rows
    input = String(row.error_text ? '').trim()
    continue unless input.length
    try
      result = await helper.classify_failure(input)
      # Store the raw model output as JSON so downstream training or
      # human-edit sees exactly what the current model produced.
      expected = JSON.stringify(
        category:   result?.category   ? 'unknown'
        confidence: result?.confidence ? 0.5
        summary:    result?.summary    ? '(no summary)'
      )
      info = insert.run targetCapability, input, expected, now
      written += info.changes
    catch err
      console.log "[bootstrap] row #{i} failed: #{String(err?.message ? err)}"
    if (i+1) % 10 is 0
      console.log "[bootstrap] progressed #{i+1}/#{rows.length}"
  console.log "[bootstrap] inserted #{written} rows into helper_training_examples (approved_by=null pending human review)"
  helper.dispose()
  db.close()
  return

# --- write train.jsonl / valid.jsonl from approved rows ------------------
writeJsonlSets = (opts = {}) ->
  db = openDb(opts.dbPath)
  outDir = String(opts.outDir ? DEFAULT_TRAIN_DIR)
  validRatio = Number(opts.validRatio ? 0.1)

  rows = db.prepare("""
    SELECT capability, input, expected_output
      FROM helper_training_examples
     WHERE approved_by IS NOT NULL
     ORDER BY id
  """).all()

  throw new Error "no approved examples in helper_training_examples — bootstrap + human-review first" unless rows.length

  # Deterministic split by ID rather than random shuffle — makes reruns
  # comparable and lets a human predict which rows land in valid.
  fs.mkdirSync outDir, recursive: true
  trainF = fs.openSync path.join(outDir, 'train.jsonl'), 'w'
  validF = fs.openSync path.join(outDir, 'valid.jsonl'), 'w'
  # test.jsonl is required by mlx_lm.lora even in --train mode as a
  # placeholder; write a tiny one so nothing throws.
  testF  = fs.openSync path.join(outDir, 'test.jsonl'),  'w'

  nTrain = nValid = 0
  everyN = Math.max 2, Math.round(1 / validRatio)  # e.g. 10 → every 10th → valid
  for row, i in rows
    tr = buildTrainingRow row.capability, row.input, row.expected_output
    line = JSON.stringify(tr) + '\n'
    if i % everyN is (everyN - 1)
      fs.writeSync validF, line
      nValid++
    else
      fs.writeSync trainF, line
      nTrain++
  # Duplicate one train row into test.jsonl so the loader doesn't
  # complain about an empty test set on future eval calls.
  if nTrain > 0
    tr = buildTrainingRow rows[0].capability, rows[0].input, rows[0].expected_output
    fs.writeSync testF, JSON.stringify(tr) + '\n'
  fs.closeSync trainF
  fs.closeSync validF
  fs.closeSync testF
  db.close()

  console.log "[train] wrote #{nTrain} train + #{nValid} valid rows to #{outDir}"
  return { nTrain, nValid, outDir }

# --- train -----------------------------------------------------------------
train = (opts = {}) ->
  # 2026-09-17: `--skip-jsonl` bypasses the sqlite-read + JSONL-write
  # step. Use when training on a host that doesn't have the puppeteer
  # DB — e.g. the mac-mini peer, which has helper_lora/train/*.jsonl
  # synced in but no runtime.sqlite. Row counts are read from the
  # existing files' line counts so the iters-heuristic still works.
  # Accept both camelCase (programmatic) and kebab-case (CLI) forms.
  skipJsonl = opts.skipJsonl or opts['skip-jsonl']
  { nTrain, nValid, outDir } =
    if skipJsonl
      dir = String(opts.outDir ? DEFAULT_TRAIN_DIR)
      trainPath = path.join(dir, 'train.jsonl')
      validPath = path.join(dir, 'valid.jsonl')
      unless fs.existsSync(trainPath)
        throw new Error "--skip-jsonl requires an existing #{trainPath}. Sync the training data over first, or drop the flag."
      countLines = (p) ->
        return 0 unless fs.existsSync(p)
        fs.readFileSync(p, 'utf8').split(/\r?\n/).filter((l) -> l.trim().length).length
      { nTrain: countLines(trainPath), nValid: countLines(validPath), outDir: dir }
    else
      writeJsonlSets(opts)
  adapterDir = String(opts.adapterDir ? DEFAULT_ADAPTER_DIR)
  fs.mkdirSync adapterDir, recursive: true

  { trainLoRA } = require './lora/train'

  # Sensible defaults for a small-dataset helper adapter. 200 iters,
  # rank 8, lr 1e-4 (LoRA tolerates higher LR than full fine-tune). If
  # the labeled set is very small (< 50) drop iters to avoid memorizing.
  iters = Number(opts.iters ? (if nTrain < 50 then 50 else 200))

  trainLoRA
    modelDir:     DEFAULT_MODEL_DIR
    dataDir:      outDir
    adapterPath:  adapterDir
    train:        true
    iters:        iters
    batchSize:    Number(opts.batchSize    ? 1)
    maxSeqLength: Number(opts.maxSeqLength ? 2048)
    learningRate: Number(opts.learningRate ? 1e-4)
    loraRank:     Number(opts.loraRank     ? 8)
    loraAlpha:    Number(opts.loraAlpha    ? 16)
    saveEvery:    Number(opts.saveEvery    ? 50)
    stepsPerEval: Number(opts.stepsPerEval ? 50)
    stepsPerReport: 10

  console.log "[train] adapter saved to #{adapterDir}/adapters.safetensors"
  return

# --- eval ------------------------------------------------------------------
# Score the adapted helper on the VALID split (approved examples not
# used in training). Reports accuracy per capability. Adapter is loaded
# via HELPER_LLM_ADAPTER_PATH env override.
evaluate = (opts = {}) ->
  adapterDir = String(opts.adapterDir ? DEFAULT_ADAPTER_DIR)
  validPath  = path.join(String(opts.outDir ? DEFAULT_TRAIN_DIR), 'valid.jsonl')
  throw new Error "no valid.jsonl at #{validPath} — run `train` first" unless fs.existsSync validPath

  process.env.HELPER_LLM_ADAPTER_PATH = adapterDir
  helper = require './helper_llm'

  # Small in-line evaluator. Reads valid.jsonl, calls the appropriate
  # capability on each, and compares the model's answer to
  # expected_output. Field-level match — we count `category` for
  # classify_failure and a fuzzy substring match on `summary` for
  # summarize_log because summaries won't match verbatim.
  hits = {classify_failure: 0, summarize_log: 0}
  total = {classify_failure: 0, summarize_log: 0}
  raw = fs.readFileSync(validPath, 'utf8').trim().split(/\r?\n/)
  for line in raw when line.trim().length
    row = JSON.parse line
    # Reverse-map: the row shape has prompt+completion. We need to
    # figure out the capability from the prompt content.
    capability =
      if row.prompt.indexOf('failure classifier') >= 0 then 'classify_failure'
      else if row.prompt.indexOf('log-summarizer') >= 0 then 'summarize_log'
      else null
    continue unless capability?
    expected = JSON.parse row.completion
    # Reconstruct the ORIGINAL input by pulling the trailing text after
    # our known "Error text:" or "Log tail:" marker in the prompt.
    marker = if capability is 'classify_failure' then 'Error text:' else 'Log tail:'
    idx = row.prompt.lastIndexOf(marker)
    input = if idx >= 0 then row.prompt.slice(idx + marker.length).trim() else ''
    result = await helper[capability](input)
    total[capability]++
    match = if capability is 'classify_failure'
      result.category is expected.category
    else
      String(result.summary ? '').toLowerCase().includes(String(expected.summary ? '').slice(0, 20).toLowerCase())
    hits[capability]++ if match
  helper.dispose()
  for cap of total when total[cap] > 0
    pct = Math.round(hits[cap]/total[cap]*100)
    console.log "[eval] #{cap}: #{hits[cap]}/#{total[cap]} correct (#{pct}%)"
  return

# --- CLI -------------------------------------------------------------------
parseArgs = (argv) ->
  args = {}
  i = 0
  while i < argv.length
    a = argv[i]
    if a.startsWith '--'
      key = a.slice(2)
      val = if argv[i+1]? and not argv[i+1].startsWith('--') then argv[i+1] else true
      args[key] = val
      i += (if val is true then 1 else 2)
    else
      args._ ?= []
      args._.push a
      i++
  args

if require.main is module
  main = ->
    [cmd, rest...] = process.argv[2..]
    opts = parseArgs(rest)
    switch cmd
      when 'bootstrap' then await bootstrap(opts)
      when 'train'     then train(opts)
      when 'eval'      then await evaluate(opts)
      else
        process.stderr.write """
          usage: coffee helper_train.coffee <bootstrap|train|eval> [--flags]

          bootstrap [--limit N] [--capability classify_failure]
            Run the current helper against unlabeled spawn_log rows and
            write predictions to helper_training_examples. Human then
            approves/edits rows before `train` uses them.

          train [--iters N] [--learningRate X] [--loraRank R] [--loraAlpha A]
                [--batchSize N] [--maxSeqLength N] [--adapterDir PATH]
            Read approved rows, write JSONL, LoRA-fine-tune. Adapter
            saves to #{DEFAULT_ADAPTER_DIR}/adapters.safetensors.

          eval [--adapterDir PATH]
            Score the trained adapter on valid.jsonl.

        """
        process.exit 2
  main().catch (err) ->
    process.stderr.write "FATAL: #{String(err?.stack ? err)}\n"
    process.exit 1

module.exports = { bootstrap, train, evaluate, writeJsonlSets, promptFor, FAILURE_CATEGORIES }
