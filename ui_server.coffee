#!/usr/bin/env coffee
fs = require 'fs'
path = require 'path'
http = require 'http'
yaml = require 'js-yaml'
{ spawn } = require 'child_process'
{ DatabaseSync } = require 'node:sqlite'

CWD = process.env.CWD ? process.cwd()
PORT = Number(process.env.UI_PORT ? 4311)
UI_BIND_MODE = String(process.env.UI_BIND_MODE ? (if process.argv[2] is 'net' then 'net' else 'local'))
HOST = if UI_BIND_MODE is 'net' then '0.0.0.0' else '127.0.0.1'
repeatLoop =
  enabled: false
  payload: null
  timer: null
  next_launch_at: null
  delay_seconds: 60
UI_CONTROL_PATH = path.join(CWD, 'state', 'ui-control.json')
CONTROL_OVERRIDE_PATH = path.join(CWD, 'control_override.yaml')
OVERRIDE_PATH = path.join(CWD, 'override.yaml')
OVERRIDE_DIR = path.join(CWD, 'override')
MERGE_RUN_PATH = path.join(CWD, 'state', 'merge-run.json')

readJson = (p, fallback = null) ->
  return fallback unless fs.existsSync(p)
  try JSON.parse(fs.readFileSync(p, 'utf8')) catch then fallback

readText = (p, fallback = '') ->
  return fallback unless fs.existsSync(p)
  try fs.readFileSync(p, 'utf8') catch then fallback

writeText = (p, text) ->
  fs.mkdirSync path.dirname(p), { recursive: true }
  fs.writeFileSync p, text, 'utf8'

looksLikeExecRoot = (candidate) ->
  return false unless typeof candidate is 'string' and candidate.length
  # **Project-owned UI fix — keep this comment.**
  # We used to require `ui/index.html` here too, but the UI can
  # live at the *project* root if the project copies it there
  # (e.g. `cp -r node_modules/@jahbini/pipeline/ui ./ui`). EXEC_ROOT
  # is identified by runner-shipped assets only: `pipeline_runner.coffee`
  # + `meta/`. The static UI is resolved separately, project-first
  # with EXEC_ROOT fallback (see resolveUiAsset below).
  try
    fs.existsSync(path.join(candidate, 'pipeline_runner.coffee')) and
      fs.existsSync(path.join(candidate, 'meta'))
  catch
    false

resolveExecRoot = ->
  candidates = []
  seen = new Set()

  pushCandidate = (candidate) ->
    return unless typeof candidate is 'string' and candidate.length
    absolute = path.resolve(candidate)
    return if seen.has(absolute)
    seen.add absolute
    candidates.push absolute

  pushCandidate process.env.EXEC if process.env.EXEC?

  # **Read env/EXEC stamped by the runner.**
  # On every run, pipeline_runner.coffee saves `env/EXEC` (and
  # `env/CWD`, `env/PYTHON`, …) into the project via the slash
  # meta device. That's the authoritative project record of where
  # the runner code lives, so we honor it before any heuristic
  # guess. The file is JSON-encoded (the slash meta does
  # JSON.stringify on string values), hence the parse.
  try
    envExecPath = path.join(CWD, 'env', 'EXEC')
    if fs.existsSync(envExecPath)
      raw = fs.readFileSync(envExecPath, 'utf8').trim()
      parsed = null
      try parsed = JSON.parse(raw) catch then parsed = raw
      pushCandidate parsed if typeof parsed is 'string'
  catch
    null

  pushCandidate path.dirname(__filename)
  pushCandidate process.cwd()
  pushCandidate CWD
  pushCandidate path.dirname(CWD)
  pushCandidate path.dirname(path.dirname(CWD))

  for candidate in candidates when looksLikeExecRoot(candidate)
    return candidate

  candidates[0] ? path.dirname(__filename)

EXEC_ROOT = resolveExecRoot()

# Project base — mirrors pipeline_runner's BASE. When the runner is installed as
# an npm package EXEC_ROOT is `<base>/node_modules/@jahbini/pipeline` (npm wipes
# node_modules), so the durable project root is the dir containing node_modules.
# In the monolith layout BASE_ROOT == EXEC_ROOT.
BASE_ROOT = do ->
  marker = "#{path.sep}node_modules#{path.sep}"
  idx = EXEC_ROOT.indexOf(marker)
  if idx isnt -1 then EXEC_ROOT.slice(0, idx) else EXEC_ROOT

# Recipe config resolution (mirrors pipeline_runner.resolveConfigPath): project-
# shared `<BASE_ROOT>/config/<name>.yaml` shadows bundled `<EXEC_ROOT>/config/`.
# No CWD tier — config is repo-common. Returns first existing; else the bundled path.
resolveConfigPath = (name) ->
  # Mirrors pipeline_runner.resolveConfigPath: CWD wins (per-pipe recipe),
  # then BASE (project-shared), then EXEC (bundled).
  candidates = [
    path.join(CWD,       'config', "#{name}.yaml")
    path.join(BASE_ROOT, 'config', "#{name}.yaml")
    path.join(EXEC_ROOT, 'config', "#{name}.yaml")
  ]
  for candidate in candidates when fs.existsSync(candidate)
    return candidate
  candidates[candidates.length - 1]

# Discover available recipes for the Recipe Selector by enumerating
# `<BASE_ROOT>/config/*.yaml` and `<EXEC_ROOT>/config/*.yaml` and taking the
# sorted union of stems. BASE shadows EXEC for same-named recipes via
# `resolveConfigPath`; here we only need the name set. Dot-prefixed and
# non-`.yaml` files are ignored.
discoverPipelineNames = ->
  names = new Set()
  for root in [BASE_ROOT, EXEC_ROOT]
    dir = path.join(root, 'config')
    continue unless fs.existsSync(dir) and fs.statSync(dir).isDirectory()
    try
      for entry in fs.readdirSync(dir)
        continue if entry.startsWith('.')
        continue unless entry.endsWith('.yaml')
        names.add entry.slice(0, -'.yaml'.length)
    catch
      null
  Array.from(names).sort()

RUNNER = path.join(EXEC_ROOT, 'pipeline_runner.coffee')
MERGE_SCRIPT = path.join(EXEC_ROOT, 'merge_sqlite_dbs.coffee')

# === SQLite query layer (agent surface step 1) =========================
# A per-pipe (per-CWD) Memo instance with the EXEC meta loader applied,
# used solely for read-only dispatch of sqlite request keys through the
# same `meta/sqlite.coffee` REQUESTS map that steps use. Cached by CWD
# path so we open each DB once. See GPT/ui/agent_surface.md.
{ Memo } = require RUNNER
sqliteMemoCache = new Map()

getSqliteMemoForPipe = (pipeCwd) ->
  cached = sqliteMemoCache.get(pipeCwd)
  return cached if cached?
  M = new Memo()
  try
    metaLoader = require path.join(EXEC_ROOT, 'meta')
    metaLoader M, { baseDir: pipeCwd }
  catch err
    console.error "[ui/sqlite] meta loader failed for #{pipeCwd}:", err?.message ? err
    return null
  sqliteMemoCache.set pipeCwd, M
  M

# Dispatch a sqlite request key (e.g. 'allStories.jsonl',
# 'storyByID{abc-123}.json') through the active pipe's Memo. Returns the
# resolved value or undefined; never throws — the API layer decides how to
# represent errors.
runSqliteRequest = (requestKey) ->
  pipeCwd = CWD
  M = getSqliteMemoForPipe(pipeCwd)
  return undefined unless M?
  try
    entry = M.theLowdown(requestKey)
    return entry?.value
  catch err
    console.error "[ui/sqlite] request '#{requestKey}' failed:", err?.message ? err
    return undefined

# Same as runSqliteRequest but rethrows so the caller can surface the meta
# layer's specific reason (e.g. "arg 'bogus' is not a uuid..."). Used by
# /api/sqlite/diff so the agent sees the exact validation message.
runSqliteRequestStrict = (requestKey) ->
  pipeCwd = CWD
  M = getSqliteMemoForPipe(pipeCwd)
  throw new Error 'meta loader not available' unless M?
  entry = M.theLowdown(requestKey)
  entry?.value

PIPE_ROOT = path.join(BASE_ROOT, 'pipe')
DEFAULT_KAG_KEYWORDS = [
  'joy'
  'contentment'
  'sadness'
  'grief'
  'fear'
  'anxiety'
  'anger'
  'frustration'
  'disgust'
  'shame'
  'surprise'
  'neutral'
]

isProcessAlive = (pid) ->
  num = Number(pid)
  return false unless Number.isFinite(num) and num > 0
  try
    process.kill num, 0
    true
  catch
    false

normalizeUiRun = (run) ->
  current = if run? and typeof run is 'object' and not Array.isArray(run) then Object.assign({}, run) else {}
  pid = Number(current.pid ? 0)
  alive = isProcessAlive(pid)

  if alive and current.status in ['launching', 'running', 'skipped', 'killing']
    current.status = if current.status is 'killing' then 'killing' else 'running'
    current.pid = pid
    current.is_attached = true
    current.is_process_alive = true
    return current

  current.is_attached = false
  current.is_process_alive = alive
  current

normalizeMergeRun = (run) ->
  current = if run? and typeof run is 'object' and not Array.isArray(run) then Object.assign({}, run) else {}
  pid = Number(current.pid ? 0)
  alive = isProcessAlive(pid)

  if alive and current.status in ['launching', 'running']
    current.status = 'running'
    current.pid = pid
    current.is_process_alive = true
    return current

  current.is_process_alive = alive
  current

readMergeRun = ->
  normalizeMergeRun readJson(MERGE_RUN_PATH, {})

resolveCoffeeBin = ->
  localCoffee = path.join(EXEC_ROOT, 'node_modules', '.bin', 'coffee')
  return localCoffee if fs.existsSync(localCoffee)
  'coffee'

workspacePipeName = (workspacePath = CWD) ->
  rel = path.relative(PIPE_ROOT, workspacePath)
  return null if not rel? or rel.startsWith('..') or path.isAbsolute(rel) or rel is ''
  rel.split(path.sep)[0] ? null

inferModelIdFromPipeName = (pipeName) ->
  name = String(pipeName ? '').trim()
  return '' unless name.length
  underscoreIndex = name.indexOf('_')
  return '' unless underscoreIndex > 0 and underscoreIndex < name.length - 1
  organization = name.slice(0, underscoreIndex).trim()
  modelName = name.slice(underscoreIndex + 1).trim()
  return '' unless organization.length and modelName.length
  "#{organization}/#{modelName}"

listPipeDirectories = ->
  return [] unless fs.existsSync(PIPE_ROOT)
  names = fs.readdirSync(PIPE_ROOT).filter (name) ->
    full = path.join(PIPE_ROOT, name)
    try
      fs.statSync(full).isDirectory()
    catch
      false
  names.sort (a, b) -> String(a).localeCompare String(b)

buildPipeSummary = ->
  current = workspacePipeName(CWD)
  pipes = (name: name, is_active: name is current for name in listPipeDirectories())
  {
    root: PIPE_ROOT
    current: current
    workspace: CWD
    pipes: pipes
  }

# === Agent manifest (step 2) ============================================
# Single entry point a fresh Claude session calls to learn what's available
# in this project, this active pipe. Cheap to assemble — no I/O beyond the
# recipe loads, which we cap by enumerating discovered names.
runnerExports = require RUNNER
sqliteMetaFactory = (try require path.join(EXEC_ROOT, 'meta', 'sqlite.coffee') catch then null)

parseRecipeForManifest = (name) ->
  configPath = resolveConfigPath(name)
  return null unless configPath? and fs.existsSync(configPath)
  try
    recipe = runnerExports.expandIncludes runnerExports.loadYamlSafe(configPath), path.dirname(configPath)
  catch
    return null
  steps = []
  artifacts = []
  for own key, val of (recipe ? {})
    continue unless val? and typeof val is 'object' and not Array.isArray(val)
    if val.run? or val.run_mlx?
      steps.push
        name: key
        run: val.run ? null
        depends_on: val.depends_on ? []
        needs: val.needs ? []
        makes: val.makes ? []
        desc: val.desc ? null
  if recipe?.artifacts? and typeof recipe.artifacts is 'object'
    for own aKey, aSpec of recipe.artifacts
      artifacts.push Object.assign({name: aKey}, (if typeof aSpec is 'object' then aSpec else {value: aSpec}))
  {
    name: name
    config_path: path.relative(BASE_ROOT, configPath)
    steps: steps
    artifacts: artifacts
  }

listArtifactsOnDisk = (dir = 'out') ->
  full = path.join(CWD, dir)
  return [] unless fs.existsSync(full) and fs.statSync(full).isDirectory()
  out = []
  walk = (rel) ->
    abs = path.join(CWD, rel)
    for name in fs.readdirSync(abs)
      continue if name.startsWith('.')
      sub = path.join(rel, name)
      stat = try fs.statSync(path.join(CWD, sub)) catch then null
      continue unless stat?
      if stat.isDirectory()
        walk sub
      else
        out.push { path: sub, size: stat.size, mtime: stat.mtime.toISOString() }
  try walk(dir) catch then null
  out

KNOWN_ENDPOINTS = [
  { method: 'GET',  path: '/api/manifest',                         summary: 'this manifest — agent bootstrap' }
  { method: 'GET',  path: '/api/status',                           summary: 'live run/pipe/steps state for the active pipe' }
  { method: 'GET',  path: '/api/sqlite/<request-key>',             summary: 'dispatch a meta/sqlite request key through the active pipe' }
  { method: 'GET',  path: '/api/sqlite/diff?since=<run_id|ts|change_id>', summary: 'precise change-log diff since an anchor (uuid, ISO timestamp, or change_id)' }
  { method: 'GET',  path: '/api/run/<run-id>',                     summary: 'composite run-evaluation: runs row + log tails + artifacts written + sqlite rows added' }
  { method: 'GET',  path: '/api/recipe?name=…',                    summary: 'read recipe yaml + parsed step/artifact view' }
  { method: 'PUT',  path: '/api/recipe?name=…',                    summary: 'create/replace CWD/config/<name>.yaml; body {content}; returns merged experiment + warnings' }
  { method: 'GET',  path: '/api/override?recipe=…',                summary: 'read per-pipe override yaml (CWD/override/<recipe>.yaml)' }
  { method: 'PUT',  path: '/api/override?recipe=…',                summary: 'create/replace per-pipe override; body {content}; returns merged experiment + toposort check' }
  { method: 'GET',  path: '/api/script?path=…',                    summary: 'read step script source via three-tier resolution' }
  { method: 'PUT',  path: '/api/script?path=…',                    summary: 'write CWD/scripts/<path>; body {content}; .coffee bodies are compile-checked' }
  { method: 'GET',  path: '/api/file?path=<rel>',                  summary: 'read a file under CWD (artifact, log)' }
  { method: 'POST', path: '/api/launch',                           summary: 'launch the active pipe (idempotent via ensureSingleInstance)' }
  { method: 'POST', path: '/api/kill',                             summary: 'SIGTERM the active pipeline run' }
  { method: 'POST', path: '/api/control',                          summary: 'write UI-control values (recipe selector, continuous flag, …)' }
  { method: 'POST', path: '/api/human_override',                   summary: 'write the human override YAML for the active recipe' }
  { method: 'POST', path: '/api/clear_pipeline_state',             summary: 'erase pipeline.json (death record)' }
  { method: 'POST', path: '/api/switch_pipe',                      summary: 'switch the UI to a different pipe (or restart in place)' }
  { method: 'POST', path: '/api/merge_pipe',                       summary: 'merge sqlite + adapter from another machine (project-specific)' }
  { method: 'POST', path: '/api/shutdown_ui',                      summary: 'stop the UI server process' }
]

buildManifest = ->
  activePipe = workspacePipeName(CWD)
  pipes = listPipeDirectories()
  recipeNames = discoverPipelineNames()
  recipesByName = {}
  for name in recipeNames
    parsed = parseRecipeForManifest(name)
    recipesByName[name] = parsed if parsed?
  sqliteRequests = sqliteMetaFactory?.requestNames ? []
  artifactsOnDisk = listArtifactsOnDisk('out').concat listArtifactsOnDisk('build/train')
  {
    base:         BASE_ROOT
    exec:         EXEC_ROOT
    cwd:          CWD
    pipe_root:    PIPE_ROOT
    active_pipe:  activePipe
    pipes:        pipes
    recipes:
      available:  recipeNames
      by_name:    recipesByName
    sqlite_requests: sqliteRequests
    artifacts_on_disk: artifactsOnDisk
    endpoints:    KNOWN_ENDPOINTS
    generated_at: new Date().toISOString()
  }

# === Run evaluation (step 3) ============================================
# Composite endpoint: given a run_id, return the runs-table row, log tails,
# the artifact files that were touched during the run's window, and a
# heuristic "rows added in this window" block for tables with timestamps.
# This is the evaluation surface a Claude (or a human looking at "Run
# Detail" in the UI) consults after a run finishes. Precise diffs of all
# tables come in step 5 (per-table change log); step 3 ships with the
# timestamp-based approximation, which is honest about what it can and
# can't determine — `null` in `sqlite_rows_added` means "no timestamp on
# that table, see step 5."

# Files under one or more directories whose mtime falls within [start, end].
# `end` may be null (still-running) — treated as "now".
filesInWindow = (dirs, startedAt, finishedAt) ->
  startMs = if startedAt? then Date.parse(startedAt) else null
  endMs   = if finishedAt? then Date.parse(finishedAt) else Date.now()
  return [] unless Number.isFinite(startMs)
  endMs = Date.now() unless Number.isFinite(endMs)
  out = []
  for dir in dirs
    full = path.join(CWD, dir)
    continue unless fs.existsSync(full) and fs.statSync(full).isDirectory()
    walk = (rel) ->
      abs = path.join(CWD, rel)
      for name in fs.readdirSync(abs)
        continue if name.startsWith('.')
        sub = path.join(rel, name)
        stat = try fs.statSync(path.join(CWD, sub)) catch then null
        continue unless stat?
        if stat.isDirectory()
          walk sub
        else
          mtimeMs = stat.mtimeMs ? stat.mtime.getTime()
          # Accept files whose mtime is at or after start, and at or before
          # end (we add a 2-second grace on each side for clock skew + the
          # registration timestamp racing the first artifact write).
          continue unless mtimeMs >= (startMs - 2000) and mtimeMs <= (endMs + 2000)
          out.push
            path: sub
            size: stat.size
            mtime: stat.mtime.toISOString()
    try walk(dir) catch then null
  out

# Per-table heuristic of "what got added during this run". For tables with
# an obvious timestamp column we can answer precisely; for tables without
# one we return `null` (step 5's change log will close this gap).
# Returned shape:
#   { runs: {count, ids}, lora_training_runs: {count, ids}, kag_entries: null, ... }
sqliteRowsInWindow = (startedAt, finishedAt) ->
  startMs = if startedAt? then Date.parse(startedAt) else null
  endMs   = if finishedAt? then Date.parse(finishedAt) else Date.now()
  endMs   = Date.now() unless Number.isFinite(endMs)
  inWindow = (iso) ->
    return false unless typeof iso is 'string'
    ms = Date.parse(iso)
    Number.isFinite(ms) and ms >= (startMs - 2000) and ms <= (endMs + 2000)

  out = {}

  # runs table — the canonical timestamp surface.
  history = runSqliteRequest('runHistory.jsonl') ? []
  matched = (r.run_id for r in history when inWindow(r.started_at))
  out.runs = { count: matched.length, ids: matched }

  # lora_training_runs — has started_at. The lora-specific run_id is
  # independent of the generic runs.run_id; match by time window.
  loraRuns = runSqliteRequest('loraTrainingRuns.jsonl') ? []
  matched = (r.run_id for r in loraRuns when inWindow(r.started_at))
  out.lora_training_runs = { count: matched.length, ids: matched }

  # lora_story_usage — last_trained_at is the closest signal.
  usage = runSqliteRequest('loraStoryUsage.jsonl') ? []
  matched = (r.story_id for r in usage when inWindow(r.last_trained_at))
  out.lora_story_usage = { count: matched.length, ids: matched }

  # Tables without a timestamp column.
  out.stories              = null
  out.kag_entries          = null
  out.story_parts          = null
  out.expanded_story_parts = null
  out.lora_trained_stories = null
  out.oracle_story_attempts = null

  out

# Tables that have INSERT/UPDATE/DELETE triggers wired up. When the change
# log is the source of truth, any of these missing from `diff.by_table`
# genuinely had zero changes during the window — surface that as a precise
# {count: 0} rather than the heuristic `null`.
TRACKED_TABLES = [
  'stories'
  'story_parts'
  'expanded_story_parts'
  'kag_entries'
  'oracle_story_attempts'
  'lora_trained_stories'
  'lora_story_usage'
  'lora_training_runs'
  'lora_training_run_stories'
  'runs'
]

# Step 5: replace the heuristic `sqlite_rows_added` block with precise
# change-log counts whenever `_change_log` is populated. Every tracked
# table is surfaced — present-with-changes from the diff, absent-but-
# tracked as a precise `{count: 0}`. Heuristic values for non-tracked
# tables are left in place.
mergeChangeLogCounts = (heuristic, startedAt) ->
  return heuristic unless startedAt?
  try
    diff = runSqliteRequest "changesSince{#{startedAt}}.json"
  catch then diff = null
  return heuristic unless diff? and diff.by_table?
  merged = Object.assign {}, heuristic
  for table in TRACKED_TABLES
    stats = diff.by_table[table]
    if stats?
      merged[table] = {
        count: stats.count
        inserts: stats.inserts
        updates: stats.updates
        deletes: stats.deletes
        ids: stats.ids
        source: 'change_log'
      }
    else
      merged[table] = { count: 0, inserts: 0, updates: 0, deletes: 0, ids: [], source: 'change_log' }
  merged

buildRunEvaluation = (runId) ->
  run = runSqliteRequest("runById{#{runId}}.json")
  return null unless run?

  startedAt  = run.started_at
  finishedAt = run.finished_at

  log_tail = null
  err_tail = null
  artifact_log_tail = null
  if run.logdir
    log_tail = tailText path.join(CWD, 'logs', "#{run.logdir}.log"), 60
    err_tail = tailText path.join(CWD, 'logs', "#{run.logdir}.err"), 60
    artifactLogPath = path.join(CWD, 'logs', "#{run.logdir}.artifacts.log")
    if fs.existsSync(artifactLogPath)
      artifact_log_tail = tailText artifactLogPath, 200

  artifacts_written = filesInWindow ['out', 'build/train', 'state'], startedAt, finishedAt
  sqlite_rows_added = mergeChangeLogCounts sqliteRowsInWindow(startedAt, finishedAt), startedAt

  Object.assign {}, run,
    log_tail: log_tail
    err_tail: err_tail
    artifact_log_tail: artifact_log_tail
    artifacts_written: artifacts_written
    sqlite_rows_added: sqlite_rows_added
    evaluated_at: new Date().toISOString()

writeUiRunPatch = (patch) ->
  runPath = path.join(CWD, 'state', 'ui-run.json')
  current = readJson(runPath, {})
  current = {} unless current? and typeof current is 'object' and not Array.isArray(current)
  next = Object.assign {}, current, patch
  writeText runPath, JSON.stringify(next, null, 2)
  next

readUiControl = ->
  current = readJson(UI_CONTROL_PATH, {})
  current = {} unless current? and typeof current is 'object' and not Array.isArray(current)
  current

writeUiControl = (patch) ->
  current = readUiControl()
  next = Object.assign {}, current, patch
  writeText UI_CONTROL_PATH, JSON.stringify(next, null, 2)
  next

normalizeCooldownSeconds = (value, fallback = 60) ->
  num = Number(value)
  return 20 if num is 20
  return 60 if num is 60
  fallback

dumpYaml = (value) ->
  yaml.dump value,
    lineWidth: 120
    noRefs: true

getByPath = (root, dottedPath) ->
  return undefined unless root? and typeof dottedPath is 'string' and dottedPath.length
  node = root
  for part in dottedPath.split('.')
    return undefined unless node? and typeof node is 'object'
    node = node[part]
  node

setByPath = (root, dottedPath, value) ->
  return root unless root? and typeof root is 'object' and typeof dottedPath is 'string' and dottedPath.length
  parts = dottedPath.split('.')
  node = root
  for part, index in parts
    if index is parts.length - 1
      node[part] = value
    else
      node[part] ?= {}
      node = node[part]
  root

deleteByPath = (root, dottedPath) ->
  return root unless root? and typeof root is 'object' and typeof dottedPath is 'string' and dottedPath.length
  parts = dottedPath.split('.')
  chain = []
  node = root
  for part in parts
    return root unless node? and typeof node is 'object'
    chain.push [node, part]
    node = node[part]

  [leafParent, leafKey] = chain[chain.length - 1]
  delete leafParent[leafKey]

  for index in [(chain.length - 2)..0]
    [parent, key] = chain[index]
    child = parent[key]
    break unless child? and typeof child is 'object' and not Array.isArray(child) and Object.keys(child).length is 0
    delete parent[key]

  root

loadDropdownOptions = (specPath) ->
  return [] unless typeof specPath is 'string' and specPath.length
  if specPath is 'db/kag_keywords'
    dbPath = path.join CWD, 'runtime.sqlite'
    fallbackRows = ({ key, label: key } for key in DEFAULT_KAG_KEYWORDS)
    return fallbackRows unless fs.existsSync dbPath
    db = null
    try
      db = new DatabaseSync dbPath
      rows = db.prepare("""
        SELECT DISTINCT keyword
        FROM kag_entries
        WHERE keyword IS NOT NULL AND TRIM(keyword) != ''
        ORDER BY keyword ASC
      """).all()
      mapped = ({
        key: String(row.keyword)
        label: String(row.keyword)
      } for row in rows when row?.keyword?)
      return mapped if mapped.length
      return fallbackRows
    catch
      return fallbackRows
    finally
      try db?.close() catch then null
  parts = specPath.split('/')
  return [] unless parts.length >= 3
  filePath = path.join CWD, parts[0], parts[1]
  keyParts = parts.slice(2)
  doc = readYaml filePath
  node = doc
  for key in keyParts
    return [] unless node? and typeof node is 'object'
    node = node[key]
  return [] unless node? and typeof node is 'object'
  rows = []
  for own key, value of node
    label = value?.text ? value?.character ? value?.label ? key
    rows.push { key, label }
  rows.sort (a, b) -> String(a.label).localeCompare String(b.label)
  rows

scanUiFields = (recipe, override, uiControl) ->
  pendingUi = uiControl?.ui_values ? {}
  rows = []

  buildLabel = (pathText) ->
    parts = String(pathText ? '').split('.')
    return pathText unless parts.length
    if parts.length >= 2
      stepName = parts[0]
      keyName = parts[parts.length - 1]
      return "#{stepName}: #{keyName}"
    pathText

  walk = (node, prefix = '') ->
    return unless node? and typeof node is 'object'
    if Array.isArray(node)
      directive = String(node[0] ? '')
      if directive is 'UI_checkbox'
        defaultValue = node[1] is true
        chosenValue = if Object::hasOwnProperty.call(pendingUi, prefix)
          pendingUi[prefix] is true
        else
          overrideValue = getByPath override, prefix
          if typeof overrideValue is 'boolean' then overrideValue else defaultValue
        rows.push
          path: prefix
          label: buildLabel(prefix)
          type: 'checkbox'
          default_value: defaultValue
          value: chosenValue
      else if directive is 'UI_dropdown'
        sourcePath = String(node[1] ? '')
        defaultValue = String(node[2] ? '')
        chosenValue = if Object::hasOwnProperty.call(pendingUi, prefix)
          String(pendingUi[prefix] ? '')
        else
          overrideValue = getByPath override, prefix
          if typeof overrideValue is 'string' then overrideValue else defaultValue
        sourceParts = sourcePath.split('/')
        rows.push
          path: prefix
          label: buildLabel(prefix)
          type: 'dropdown'
          default_value: defaultValue
          value: chosenValue
          source_path: sourcePath
          options: loadDropdownOptions(sourcePath)
      else if directive is 'UI_textarea'
        defaultValue = if node.length >= 2 then String(node[1] ? '') else ''
        chosenValue = if Object::hasOwnProperty.call(pendingUi, prefix)
          String(pendingUi[prefix] ? '')
        else
          overrideValue = getByPath override, prefix
          if typeof overrideValue is 'string' then overrideValue else defaultValue
        rows.push
          path: prefix
          label: buildLabel(prefix)
          type: 'textarea'
          default_value: defaultValue
          value: chosenValue
      return

    return unless not Array.isArray(node)
    for own key, value of node
      currentPath = if prefix.length then "#{prefix}.#{key}" else key
      walk value, currentPath

  walk recipe
  rows.sort (a, b) -> String(a.path).localeCompare String(b.path)
  rows

readRecipe = (pipeline) ->
  return {} unless typeof pipeline is 'string' and pipeline.length
  readYaml resolveConfigPath(pipeline)

pad2 = (n) ->
  text = String(Number(n) ? 0)
  if text.length < 2 then "0#{text}" else text

buildRunTag = ->
  now = new Date()
  hhmm = "#{pad2(now.getHours())}_#{pad2(now.getMinutes())}"
  {
    hh_mm: hhmm
    logdir: "pipe_#{hhmm}"
  }

tailText = (p, maxLines = 120) ->
  text = readText(p, '')
  lines = text.split /\r?\n/
  lines.slice(Math.max(lines.length - maxLines, 0)).join "\n"

listFiles = (dir) ->
  return [] unless fs.existsSync(dir)
  names = fs.readdirSync(dir).sort()
  out = []
  for name in names
    full = path.join(dir, name)
    stat = fs.statSync(full)
    out.push
      name: name
      path: full
      is_dir: stat.isDirectory()
      size: stat.size
      mtime: stat.mtime.toISOString()
  out

readJsonlTail = (p, maxRows = 80) ->
  return [] unless fs.existsSync(p)
  text = fs.readFileSync(p, 'utf8')
  rows = []
  for line in text.split(/\r?\n/) when line.trim().length
    try rows.push JSON.parse(line) catch then null
  rows.slice Math.max(rows.length - maxRows, 0)

latestLogStem = ->
  logDir = path.join(CWD, 'logs')
  return null unless fs.existsSync(logDir)
  names = fs.readdirSync(logDir).filter (name) -> /^pipe_\d{2}_\d{2}\.(log|err)$/.test(name)
  return null unless names.length
  stems = {}
  for name in names
    stem = name.replace /\.(log|err)$/, ''
    stems[stem] = true
  ordered = Object.keys(stems).sort()
  ordered[ordered.length - 1]

collectStepStates = ->
  stateDir = path.join(CWD, 'state')
  return [] unless fs.existsSync(stateDir)
  names = fs.readdirSync(stateDir).filter (name) -> /^step-.*\.json$/.test(name)
  rows = []
  for name in names
    row = readJson path.join(stateDir, name), {}
    continue unless row?
    rows.push row
  rows.sort (a, b) ->
    String(a.step ? '').localeCompare String(b.step ? '')

overridePathForPipeline = (pipelineName) ->
  name = String(pipelineName ? '').trim()
  return OVERRIDE_PATH unless name.length
  path.join OVERRIDE_DIR, "#{name}.yaml"

readLegacyOverride = ->
  parsed = if fs.existsSync(OVERRIDE_PATH)
    try yaml.load(fs.readFileSync(OVERRIDE_PATH, 'utf8')) ? {} catch then {}
  else
    {}
  parsed = {} unless parsed? and typeof parsed is 'object' and not Array.isArray(parsed)
  parsed

readOverride = (pipelineName = null) ->
  foundational = {}
  pipeName = workspacePipeName(CWD)
  inferredModel = inferModelIdFromPipeName(pipeName)
  legacy = readLegacyOverride()
  selectedPipeline = String(pipelineName ? '').trim()
  selectedPipeline = String(legacy.pipeline ? '').trim() unless selectedPipeline.length
  selectedPath = overridePathForPipeline selectedPipeline

  materializedFromLegacy = false
  parsed = if fs.existsSync(selectedPath)
    try yaml.load(fs.readFileSync(selectedPath, 'utf8')) ? {} catch then {}
  else if fs.existsSync(OVERRIDE_PATH)
    materializedFromLegacy = selectedPipeline.length > 0
    Object.assign {}, legacy
  else
    {}

  parsed = {} unless parsed? and typeof parsed is 'object' and not Array.isArray(parsed)
  needsWrite = false

  if inferredModel.length
    parsed.run = {} unless parsed.run? and typeof parsed.run is 'object' and not Array.isArray(parsed.run)
    currentModel = String(parsed.run.model ? '').trim()
    if currentModel.length is 0
      parsed.run.model = inferredModel
      needsWrite = true

  if selectedPipeline.length and not parsed.pipeline?
    parsed.pipeline = selectedPipeline
    needsWrite = true

  if materializedFromLegacy or needsWrite or (inferredModel.length and not fs.existsSync(selectedPath))
    writeText selectedPath, dumpYaml(parsed)

  parsed

readControlOverride = ->
  return {} unless fs.existsSync CONTROL_OVERRIDE_PATH
  try yaml.load(fs.readFileSync(CONTROL_OVERRIDE_PATH, 'utf8')) ? {} catch then {}

readYaml = (p) ->
  target = p
  if not fs.existsSync(target) and typeof p is 'string'
    rel = path.relative(CWD, p)
    if rel? and not rel.startsWith('..') and not path.isAbsolute(rel)
      fallback = path.join(EXEC_ROOT, rel)
      target = fallback if fs.existsSync(fallback)
  return {} unless fs.existsSync target
  try yaml.load(fs.readFileSync(target, 'utf8')) ? {} catch then {}

buildControls = ->
  controlOverride = readControlOverride()
  uiControl = readUiControl()
  pending = uiControl.pending ? {}
  legacyOverride = readLegacyOverride()
  pipelineName = pending.pipeline ? controlOverride.pipeline ? legacyOverride.pipeline ? ''
  override = readOverride(pipelineName)
  recipe = readRecipe(pipelineName)
  libraryDoc = readYaml path.join(EXEC_ROOT, 'data', 'jim_story_library.yaml')
  library = libraryDoc?.library ? {}
  recipeStoryStep = recipe?.select_story_recipe ? {}
  controlStoryStep = controlOverride?.select_story_recipe ? {}

  makeOptions = (shelfName) ->
    shelf = library?[shelfName] ? {}
    rows = []
    for own key, value of shelf
      label = value?.text ? value?.character ? key
      rows.push { key, label }
    rows.sort (a, b) -> String(a.label).localeCompare String(b.label)
    rows

  overrideObject = buildOverrideObject
    pipeline: pipelineName
    scene: pending.scene ? controlStoryStep.scene ? recipeStoryStep.scene ? ''
    arrival: pending.arrival ? controlStoryStep.arrival ? recipeStoryStep.arrival ? ''
    disturbance: pending.disturbance ? controlStoryStep.disturbance ? recipeStoryStep.disturbance ? ''
    reflection: pending.reflection ? controlStoryStep.reflection ? recipeStoryStep.reflection ? ''
    realization: pending.realization ? controlStoryStep.realization ? recipeStoryStep.realization ? ''
    ui_values: Object.assign {}, (uiControl.ui_values ? {})

  controlOverrideText = if typeof uiControl.control_override_text is 'string' and uiControl.control_override_text.trim().length
    uiControl.control_override_text
  else
    dumpYaml overrideObject
  recipeText = if pipelineName.length then dumpYaml(recipe) else ''
  humanOverridePath = overridePathForPipeline pipelineName
  humanOverrideText = if fs.existsSync(humanOverridePath)
    readText humanOverridePath, ''
  else if fs.existsSync(OVERRIDE_PATH)
    readText OVERRIDE_PATH, ''
  else
    ''
  experimentText = if fs.existsSync(path.join(CWD, 'experiment.yaml')) then readText(path.join(CWD, 'experiment.yaml'), '') else ''
  uiFields = scanUiFields recipe, controlOverride, uiControl

  {
    pipeline: pipelineName
    scene: pending.scene ? controlStoryStep.scene ? recipeStoryStep.scene ? ''
    arrival: pending.arrival ? controlStoryStep.arrival ? recipeStoryStep.arrival ? ''
    disturbance: pending.disturbance ? controlStoryStep.disturbance ? recipeStoryStep.disturbance ? ''
    reflection: pending.reflection ? controlStoryStep.reflection ? recipeStoryStep.reflection ? ''
    realization: pending.realization ? controlStoryStep.realization ? recipeStoryStep.realization ? ''
    continuous: uiControl.continuous is true
    continuous_delay_seconds: normalizeCooldownSeconds(uiControl.continuous_delay_seconds, 60)
    pipelines: discoverPipelineNames()
    scene_options: makeOptions 'scenes'
    arrival_options: makeOptions 'characters'
    disturbance_options: makeOptions 'disturbances'
    reflection_options: makeOptions 'reflections'
    realization_options: makeOptions 'realizations'
    ui_fields: uiFields
    control_override_text: controlOverrideText
    human_override_text: humanOverrideText
    recipe_text: recipeText
    experiment_text: experimentText
  }

describeOutputFile = (relativePath, runStart = null) ->
  fullPath = path.join(CWD, relativePath)
  exists = fs.existsSync(fullPath)
  stat = if exists then fs.statSync(fullPath) else null
  mtime = if stat? then stat.mtime.toISOString() else null
  fresh = false
  if stat? and runStart?
    started = new Date(runStart)
    fresh = not Number.isNaN(started.getTime()) and stat.mtime.getTime() >= started.getTime()

  {
    name: path.basename(relativePath)
    path: relativePath
    exists: exists
    size: stat?.size ? null
    mtime: mtime
    is_fresh: fresh
  }

collectExpectedOutputs = (run) ->
  controlOverride = readControlOverride()
  legacyOverride = readLegacyOverride()
  pipeline = controlOverride.pipeline ? legacyOverride.pipeline ? run?.pipeline ? null
  override = readOverride(pipeline)
  return { out_files: [], diary_files: collectDiaryFiles(run) } unless pipeline?

  configPath = resolveConfigPath(pipeline)
  recipe = readYaml(configPath)
  artifacts = recipe?.artifacts ? {}
  runStart = run?.started_at ? null

  outFiles = []
  seen = new Set()

  for own artifactKey, spec of artifacts
    continue unless spec? and typeof spec is 'object' and typeof spec.target is 'string'
    target = String(spec.target)
    continue if seen.has(target)
    seen.add target
    row = describeOutputFile target, runStart
    continue if /^diary\//.test(target)
    outFiles.push row

  outFiles.sort (a, b) -> String(a.path).localeCompare String(b.path)

  {
    out_files: outFiles
    diary_files: collectDiaryFiles(run)
  }

collectDiaryFiles = (run) ->
  diaryDir = path.join(CWD, 'diary')
  runStart = run?.started_at ? null
  rows = []
  return rows unless fs.existsSync(diaryDir)

  for entry in listFiles(diaryDir) when entry? and entry.is_dir isnt true
    rows.push describeOutputFile "diary/#{entry.name}", runStart

  rows.sort (a, b) -> String(a.path).localeCompare String(b.path)
  rows

# Ported from writeStory main: lists files under `logs/`, marking
# any updated since the current run started as "fresh". The frontend
# uses this to render the "logs" panel.
collectLogFiles = (run) ->
  logDir = path.join(CWD, 'logs')
  runStart = run?.started_at ? null
  rows = []
  return rows unless fs.existsSync(logDir)

  for entry in listFiles(logDir) when entry? and entry.is_dir isnt true
    rows.push describeOutputFile "logs/#{entry.name}", runStart

  rows.sort (a, b) -> String(b.path).localeCompare String(a.path)
  rows

buildStatus = ->
  run = normalizeUiRun readJson path.join(CWD, 'state', 'ui-run.json'), {}
  mergeRun = readMergeRun()
  pipelineState = readJson path.join(CWD, 'pipeline.json'), null
  expectedOutputs = collectExpectedOutputs(run)
  pipeSummary = buildPipeSummary()
  loraRemaining = readJson path.join(CWD, 'out', 'lora_remaining_count.json'), null
  oracleRemaining = readJson path.join(CWD, 'out', 'oracle_remaining_count.json'), null
  storiesRemaining = if oracleRemaining? then oracleRemaining else loraRemaining
  events = readJsonlTail path.join(CWD, 'state', 'ui-events.jsonl')
  steps = collectStepStates()
  stem = if run?.logdir? then String(run.logdir) else latestLogStem()
  latestLog = if stem? then readText(path.join(CWD, 'logs', "#{stem}.log")) else ''
  latestErr = if stem? then readText(path.join(CWD, 'logs', "#{stem}.err")) else ''

  # Workspace summary for the page header: top_level is the project root the
  # ui_server was first started in (BASE_ROOT — same as EXEC_ROOT in monolith),
  # pipe is the active `pipes/<name>` workspace if CWD sits under one.
  workspace =
    top_level: path.basename(BASE_ROOT)
    pipe: workspacePipeName(CWD)

  {
    run: run
    merge_run: mergeRun
    pipeline_state: pipelineState
    workspace: workspace
    pipe: pipeSummary
    lora_remaining_count: loraRemaining
    oracle_remaining_count: oracleRemaining
    stories_remaining_count: storiesRemaining
    controls: buildControls()
    steps: steps
    events: events
    latest_log_stem: stem
    latest_log: latestLog
    latest_err: latestErr
    out_files: expectedOutputs.out_files
    diary_files: expectedOutputs.diary_files
    log_files: collectLogFiles(run)
  }

isAllowedFilePath = (relativePath) ->
  return false unless typeof relativePath is 'string' and relativePath.length
  normalized = path.normalize(relativePath)
  return false if normalized.startsWith('..') or path.isAbsolute(normalized)
  /^logs\//.test(normalized) or /^out\//.test(normalized) or /^diary\//.test(normalized) or /^build\//.test(normalized) or /^tested\//.test(normalized)

readViewerFile = (relativePath) ->
  return null unless isAllowedFilePath(relativePath)
  fullPath = path.join(CWD, relativePath)
  return null unless fs.existsSync(fullPath)
  stat = fs.statSync(fullPath)
  return null unless stat.isFile()
  {
    path: relativePath
    size: stat.size
    mtime: stat.mtime.toISOString()
    text: readText(fullPath, '')
  }

sendJson = (res, code, payload) ->
  body = JSON.stringify(payload, null, 2)
  res.writeHead code,
    'Content-Type': 'application/json; charset=utf-8'
    'Content-Length': Buffer.byteLength(body)
    'Cache-Control': 'no-store'
  res.end body

sendHtml = (res, p) ->
  body = readText p, ''
  if not body.length
    console.error "[ui_server] missing html:", p
    console.error "[ui_server] EXEC_ROOT:", EXEC_ROOT
    console.error "[ui_server] CWD:", CWD
    console.error "[ui_server] __filename:", __filename
    res.writeHead 404, 'Content-Type': 'text/plain; charset=utf-8'
    res.end 'ui/index.html not found'
    return
  res.writeHead 200,
    'Content-Type': 'text/html; charset=utf-8'
    'Content-Length': Buffer.byteLength(body)
    'Cache-Control': 'no-store'
  res.end body

readRequestBody = (req) ->
  new Promise (resolve, reject) ->
    chunks = []
    req.on 'data', (chunk) -> chunks.push chunk
    req.on 'end', ->
      text = Buffer.concat(chunks).toString('utf8')
      resolve text
    req.on 'error', reject

clearStepState = ->
  stateDir = path.join(CWD, 'state')
  return unless fs.existsSync stateDir
  for name in fs.readdirSync(stateDir) when /^step-.*\.json$/.test(name) or /^ui-run\.(json|jsonl)$/.test(name) or /^ui-events\.(json|jsonl)$/.test(name)
    fs.unlinkSync path.join(stateDir, name)

  pipelinePath = path.join(CWD, 'pipeline.json')
  fs.unlinkSync(pipelinePath) if fs.existsSync(pipelinePath)

seedUiRun = (launch, override) ->
  runPath = path.join(CWD, 'state', 'ui-run.json')
  current = readJson(runPath, {})
  current = {} unless current? and typeof current is 'object' and not Array.isArray(current)

  seeded =
    pipeline: current.pipeline ? override.pipeline ? null
    pid: current.pid ? launch.pid
    cwd: current.cwd ? CWD
    hh_mm: current.hh_mm ? launch.hh_mm
    logdir: current.logdir ? launch.logdir
    status: current.status ? 'launching'
    started_at: current.started_at ? new Date().toISOString()
    finished_at: current.finished_at ? null

  writeText runPath, JSON.stringify(seeded, null, 2)

findActiveWorkspaceRun = ->
  runPath = path.join(CWD, 'state', 'ui-run.json')
  run = normalizeUiRun readJson(runPath, {}), {}
  return null unless run.is_process_alive is true and Number(run.pid ? 0) > 0
  run

markUiRunExited = (launch, patch = {}) ->
  runPath = path.join(CWD, 'state', 'ui-run.json')
  current = readJson(runPath, {})
  return unless current? and typeof current is 'object' and not Array.isArray(current)
  return unless current.pid is launch.pid
  return unless current.status in ['launching', 'running']

  next = Object.assign {}, current,
    status: patch.status ? 'exited'
    finished_at: patch.finished_at ? new Date().toISOString()
  , patch

  writeText runPath, JSON.stringify(next, null, 2)

markMergeRunExited = (launch, patch = {}) ->
  current = readJson(MERGE_RUN_PATH, {})
  return unless current? and typeof current is 'object' and not Array.isArray(current)
  return unless current.pid is launch.pid
  return unless current.status in ['launching', 'running']

  next = Object.assign {}, current,
    status: patch.status ? 'exited'
    finished_at: patch.finished_at ? new Date().toISOString()
  , patch

  writeText MERGE_RUN_PATH, JSON.stringify(next, null, 2)

stopRepeatLoop = ->
  if repeatLoop.timer?
    clearTimeout repeatLoop.timer
  repeatLoop.enabled = false
  repeatLoop.payload = null
  repeatLoop.timer = null
  repeatLoop.next_launch_at = null
  repeatLoop.delay_seconds = 60
  writeUiControl continuous: false

buildLaunchPayloadFromControl = ->
  uiControl = readUiControl()
  pending = uiControl.pending ? {}
  controlOverride = readControlOverride()
  legacyOverride = readLegacyOverride()
  payload =
    pipeline: pending.pipeline ? controlOverride.pipeline ? legacyOverride.pipeline ? ''
    continuous: uiControl.continuous is true
    continuous_delay_seconds: normalizeCooldownSeconds(uiControl.continuous_delay_seconds, 60)

  for key in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
    payload[key] = pending[key] if pending[key]?
  payload.ui_values = Object.assign {}, (uiControl.ui_values ? {})

  payload

buildOverrideObject = (payload) ->
  override = {}
  pipelineName = String(payload.pipeline ? readLegacyOverride().pipeline ? '')
  recipe = readRecipe(pipelineName)
  recipeStory = recipe?.select_story_recipe ? {}
  override.pipeline = pipelineName
  diaryPipelines = ['diary_ite', 'diary_translate_ite']

  if override.pipeline in diaryPipelines
    override.select_story_recipe ?= {}

  if override.pipeline in diaryPipelines
    for key in ['scene', 'arrival', 'disturbance', 'reflection', 'realization']
      value = String(payload[key] ? '').trim()
      recipeValue = String(recipeStory[key] ? '')
      if value.length and value isnt recipeValue
        override.select_story_recipe[key] = value
      else
        delete override.select_story_recipe[key]

    delete override.select_story_recipe if Object.keys(override.select_story_recipe).length is 0
  else
    delete override.select_story_recipe

  uiFields = scanUiFields recipe, override, { ui_values: payload.ui_values ? {} }
  for field in uiFields
    chosenValue = if payload?.ui_values? and Object::hasOwnProperty.call(payload.ui_values, field.path)
      payload.ui_values[field.path]
    else
      field.value

    if chosenValue is field.default_value
      deleteByPath override, field.path
    else
      setByPath override, field.path, chosenValue

  override

writeControlOverrideText = (text) ->
  writeText CONTROL_OVERRIDE_PATH, text
  parsed = readYaml CONTROL_OVERRIDE_PATH
  throw new Error 'control_override.yaml must parse to an object' unless parsed? and typeof parsed is 'object' and not Array.isArray(parsed)
  throw new Error 'control_override.yaml must include pipeline' unless typeof parsed.pipeline is 'string' and parsed.pipeline.trim().length
  parsed

writeHumanOverrideText = (text) ->
  trimmed = String(text ? '').trim()
  controlOverride = readControlOverride()
  uiControl = readUiControl()
  pipelineName = String(controlOverride.pipeline ? uiControl?.pending?.pipeline ? readLegacyOverride().pipeline ? '').trim()
  targetPath = overridePathForPipeline pipelineName
  if trimmed.length is 0
    parsed = readOverride(pipelineName)
    return parsed

  writeText targetPath, text
  parsed = readYaml targetPath
  throw new Error "#{path.relative(CWD, targetPath)} must parse to an object" unless parsed? and typeof parsed is 'object' and not Array.isArray(parsed)
  pipeName = workspacePipeName(CWD)
  inferredModel = inferModelIdFromPipeName(pipeName)
  if inferredModel.length
    parsed.run = {} unless parsed.run? and typeof parsed.run is 'object' and not Array.isArray(parsed.run)
    currentModel = String(parsed.run.model ? '').trim()
    if currentModel.length is 0
      parsed.run.model = inferredModel
      writeText targetPath, dumpYaml(parsed)
  parsed

scheduleRepeatLaunch = ->
  return unless repeatLoop.enabled

  pipelineState = readJson path.join(CWD, 'pipeline.json'), null
  if pipelineState?.status is 'shutdown'
    stopRepeatLoop()
    writeUiRunPatch
      loop_enabled: false
      countdown_seconds: null
      next_launch_at: null
    return

  delaySeconds = normalizeCooldownSeconds(repeatLoop.delay_seconds, 60)
  delayMs = delaySeconds * 1000
  repeatLoop.next_launch_at = new Date(Date.now() + delayMs).toISOString()
  writeUiRunPatch
    status: 'cooldown'
    loop_enabled: true
    countdown_seconds: delaySeconds
    next_launch_at: repeatLoop.next_launch_at

  repeatLoop.timer = setTimeout ->
    return unless repeatLoop.enabled
    pipelineStateNow = readJson path.join(CWD, 'pipeline.json'), null
    if pipelineStateNow?.status is 'shutdown'
      stopRepeatLoop()
      writeUiRunPatch
        loop_enabled: false
        countdown_seconds: null
        next_launch_at: null
      return

    uiControl = readUiControl()
    launchPayload = buildLaunchPayloadFromControl()
    overrideText = if typeof uiControl.control_override_text is 'string' and uiControl.control_override_text.trim().length
      uiControl.control_override_text
    else
      dumpYaml buildOverrideObject(launchPayload)
    override = writeControlOverrideText overrideText
    clearStepState()
    launch = startRunner()
    seedUiRun launch, override
    writeUiRunPatch
      loop_enabled: true
      countdown_seconds: null
      next_launch_at: null
  , delayMs

startRunner = ->
  runTag = buildRunTag()
  logDir = path.join(CWD, 'logs')
  fs.mkdirSync logDir, { recursive: true }
  logPath = path.join(logDir, "#{runTag.logdir}.log")
  errPath = path.join(logDir, "#{runTag.logdir}.err")
  fs.writeFileSync logPath, '', 'utf8'
  fs.writeFileSync errPath, '', 'utf8'
  outFd = fs.openSync logPath, 'a'
  errFd = fs.openSync errPath, 'a'

  child = spawn 'coffee', [RUNNER],
    cwd: CWD
    detached: true
    stdio: ['ignore', outFd, errFd]
    env: Object.assign {}, process.env,
      EXEC: EXEC_ROOT
      CWD: CWD
      PWD: CWD
      HH_MM: runTag.hh_mm
      LOGDIR: runTag.logdir

  child.unref()
  child.on 'error', (err) ->
    markUiRunExited {
      pid: child.pid
      hh_mm: runTag.hh_mm
      logdir: runTag.logdir
    },
      status: 'failed'
      error: String(err?.message ? err)

  child.on 'exit', (code, signal) ->
    status = if code is 0 then 'done' else 'failed'
    markUiRunExited {
      pid: child.pid
      hh_mm: runTag.hh_mm
      logdir: runTag.logdir
    },
      status: status
      exit_code: code
      signal: signal ? null

    if repeatLoop.enabled
      if status is 'done'
        scheduleRepeatLaunch()
      else
        stopRepeatLoop()
        writeUiRunPatch
          loop_enabled: false
          countdown_seconds: null
          next_launch_at: null

  {
    pid: child.pid
    hh_mm: runTag.hh_mm
    logdir: runTag.logdir
  }

startMerge = (pipeName) ->
  stamp = buildRunTag()
  logDir = path.join(CWD, 'logs')
  fs.mkdirSync logDir, { recursive: true }
  logStem = "merge_#{stamp.hh_mm}"
  logPath = path.join(logDir, "#{logStem}.log")
  errPath = path.join(logDir, "#{logStem}.err")
  fs.writeFileSync logPath, '', 'utf8'
  fs.writeFileSync errPath, '', 'utf8'
  outFd = fs.openSync logPath, 'a'
  errFd = fs.openSync errPath, 'a'

  child = spawn resolveCoffeeBin(), [MERGE_SCRIPT, '--pipe', pipeName],
    cwd: EXEC_ROOT
    detached: true
    stdio: ['ignore', outFd, errFd]
    env: Object.assign {}, process.env,
      EXEC: EXEC_ROOT
      CWD: CWD
      PWD: EXEC_ROOT

  payload =
    pipe: pipeName
    pid: child.pid
    status: 'launching'
    started_at: new Date().toISOString()
    finished_at: null
    logdir: logStem
    log_path: path.relative(CWD, logPath)
    err_path: path.relative(CWD, errPath)

  writeText MERGE_RUN_PATH, JSON.stringify(payload, null, 2)

  child.unref()
  child.on 'error', (err) ->
    markMergeRunExited {
      pid: child.pid
      logdir: logStem
    },
      status: 'failed'
      error: String(err?.message ? err)

  child.on 'exit', (code, signal) ->
    status = if code is 0 then 'done' else 'failed'
    markMergeRunExited {
      pid: child.pid
      logdir: logStem
    },
      status: status
      exit_code: code
      signal: signal ? null

  payload

handleLaunch = (req, res) ->
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body' }

  pipeline = String(payload.pipeline ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'pipeline is required' }) unless pipeline.length

  writeUiControl
    pending:
      pipeline: pipeline
      scene: payload.scene ? ''
      arrival: payload.arrival ? ''
      disturbance: payload.disturbance ? ''
      reflection: payload.reflection ? ''
      realization: payload.realization ? ''
    ui_values: if payload.ui_values? and typeof payload.ui_values is 'object' then payload.ui_values else {}

  if payload.continuous is true
    repeatLoop.enabled = true
    repeatLoop.payload = Object.assign {}, payload
    repeatLoop.delay_seconds = normalizeCooldownSeconds(payload.continuous_delay_seconds, 60)
    writeUiControl
      continuous: true
      continuous_delay_seconds: repeatLoop.delay_seconds
  else
    stopRepeatLoop()
  overrideText = if typeof payload.control_override_text is 'string' and payload.control_override_text.trim().length
    payload.control_override_text
  else
    dumpYaml buildOverrideObject(payload)
  writeUiControl control_override_text: overrideText
  override = writeControlOverrideText overrideText
  attachedRun = findActiveWorkspaceRun()
  if attachedRun?
    writeUiRunPatch
      status: 'running'
      pid: attachedRun.pid
      loop_enabled: repeatLoop.enabled
      countdown_seconds: null
      next_launch_at: null
    return sendJson res, 200,
      ok: true
      attached: true
      pid: attachedRun.pid
      hh_mm: attachedRun.hh_mm ? null
      logdir: attachedRun.logdir ? null
      override: override

  clearStepState()
  launch = startRunner()
  seedUiRun launch, override
  writeUiRunPatch
    loop_enabled: repeatLoop.enabled
    countdown_seconds: null
    next_launch_at: null

  sendJson res, 200,
    ok: true
    pid: launch.pid
    hh_mm: launch.hh_mm
    logdir: launch.logdir
    override: override

handleKill = (req, res) ->
  stopRepeatLoop()
  runPath = path.join(CWD, 'state', 'ui-run.json')
  run = readJson(runPath, {})
  pid = Number(run?.pid ? 0)
  targetKind = 'run'

  if Array.isArray(run?.other_runners) and run.other_runners.length > 0
    first = run.other_runners[0]
    if typeof first?.pid is 'number' and first.pid > 0
      pid = Number(first.pid)
      targetKind = 'blocking_runner'
    else
      firstText = String(first ? '')
      match = firstText.match(/^\s*(\d+)\b/)
      if match?
        pid = Number(match[1])
        targetKind = 'blocking_runner'

  return sendJson(res, 400, { ok: false, error: 'no active run pid recorded' }) unless pid > 0

  try
    process.kill pid, 'SIGTERM'
  catch err
    return sendJson res, 500,
      ok: false
      error: String(err?.message ? err)

  next = Object.assign {}, run,
    status: 'killing'
    kill_requested_at: new Date().toISOString()
    loop_enabled: false
    countdown_seconds: null
    next_launch_at: null
  writeText runPath, JSON.stringify(next, null, 2)

  sendJson res, 200,
    ok: true
    pid: pid
    target_kind: targetKind

# Stop the UI server process itself. A relaunched (Switch Pipe) server is
# detached + unref'd, so the browser is the only way to reach it; this is the
# kill switch. Respond first, then exit so the port is freed.
handleShutdownUi = (req, res) ->
  stopRepeatLoop()
  sendJson res, 200,
    ok: true
    pid: process.pid
    shutting_down: true
  setTimeout((-> process.exit(0)), 150)

handleControl = (req, res) ->
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body' }

  pipeline = String(payload.pipeline ? '').trim()
  current = readUiControl()
  controlOverride = readControlOverride()
  legacyOverride = readLegacyOverride()
  next =
    continuous: if payload.continuous is true then true else false
    continuous_delay_seconds: normalizeCooldownSeconds(payload.continuous_delay_seconds, normalizeCooldownSeconds(current?.continuous_delay_seconds, 60))
    pending:
      pipeline: if pipeline.length then pipeline else (current?.pending?.pipeline ? controlOverride.pipeline ? legacyOverride.pipeline ? '')
      scene: String(payload.scene ? '')
      arrival: String(payload.arrival ? '')
      disturbance: String(payload.disturbance ? '')
      reflection: String(payload.reflection ? '')
      realization: String(payload.realization ? '')
    ui_values: if payload.ui_values? and typeof payload.ui_values is 'object'
      Object.assign {}, (current?.ui_values ? {}), payload.ui_values
    else
      (current?.ui_values ? {})
    control_override_text: if typeof payload.control_override_text is 'string' then payload.control_override_text else null

  unless typeof payload.control_override_text is 'string'
    next.control_override_text = dumpYaml buildOverrideObject
      pipeline: next.pending.pipeline
      scene: next.pending.scene
      arrival: next.pending.arrival
      disturbance: next.pending.disturbance
      reflection: next.pending.reflection
      realization: next.pending.realization
      ui_values: next.ui_values

  writeUiControl next
  controlOverride = writeControlOverrideText next.control_override_text
  if next.continuous is true
    repeatLoop.enabled = true
    repeatLoop.delay_seconds = next.continuous_delay_seconds
  else
    stopRepeatLoop()
    writeUiRunPatch
      loop_enabled: false
      countdown_seconds: null
      next_launch_at: null

  sendJson res, 200,
    ok: true
    control: next
    control_override: controlOverride

handleHumanOverride = (req, res) ->
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body' }

  text = if typeof payload.human_override_text is 'string' then payload.human_override_text else ''
  override = writeHumanOverrideText text
  sendJson res, 200,
    ok: true
    override: override

# === Mutation endpoints (step 4) ========================================
# Agent (and human) write surfaces for recipes, overrides, and step
# scripts. All writes are CWD-scoped (per-pipe). Every PUT returns the
# post-write effective state — for recipe/override that's the merged
# experiment.yaml; for scripts that's the resolved path. Failure returns
# 4xx with the specific reason (no silent overwrites, no half-states).

ensureSafeRelPath = (rel) ->
  return false unless typeof rel is 'string' and rel.length > 0
  return false if rel.startsWith('/') or rel.includes(' ')
  normalized = path.posix.normalize(rel.split(path.sep).join('/'))
  return false if normalized is '..' or normalized.startsWith('../') or normalized.includes('/../')
  true

isPlainObjectLocal = (o) ->
  o? and typeof o is 'object' and not Array.isArray(o)

parseYamlSafely = (text) ->
  try
    parsed = yaml.load(text)
    return { ok: false, error: 'YAML must parse to an object' } unless isPlainObjectLocal(parsed)
    { ok: true, parsed: parsed }
  catch err
    { ok: false, error: "invalid YAML: #{err?.message ? err}" }

# Pluck step entries from a parsed recipe (anything with `run:` or `run_mlx`).
discoverStepsLocal = (recipe) ->
  out = {}
  for own k, v of (recipe ? {})
    continue unless isPlainObjectLocal(v)
    continue unless v.run? or v.run_mlx
    out[k] = v
  out

# Kahn's-algorithm sanity check on step `depends_on:` graph. Returns
# `{ok}`, `{ok:false, error}` with a specific reason (unknown dep,
# cycle, etc.), and on success also `order: [step names...]`.
validateToposort = (steps) ->
  indeg = {}
  graph = {}
  for own name of steps
    indeg[name] = 0
    graph[name] = []
  for own name, def of steps
    deps = def.depends_on ? []
    deps = [deps] if typeof deps is 'string'
    for dep in deps
      continue if String(dep).toLowerCase() is 'never'   # the runtime off-switch
      unless steps[dep]?
        return { ok: false, error: "step '#{name}' depends on undefined step '#{dep}'" }
      indeg[name] += 1
      graph[dep].push name
  q = (n for own n, d of indeg when d is 0)
  order = []
  while q.length > 0
    n = q.shift()
    order.push n
    for m in graph[n]
      indeg[m] -= 1
      q.push m if indeg[m] is 0
  if order.length isnt Object.keys(steps).length
    return { ok: false, error: 'cycle detected in step dependencies' }
  { ok: true, order: order }

# Build the post-write merged experiment for `name`. Returns the merged
# object, or rethrows whatever createExperimentObject throws.
buildMergedExperimentForName = (name) ->
  configPath = runnerExports.resolveConfigPath(name)
  return null unless configPath? and fs.existsSync(configPath)
  layers = runnerExports.resolveOverrideLayers(name)
  controlPath = path.join(CWD, 'control_override.yaml')
  controlArg = if fs.existsSync(controlPath) then controlPath else null
  runnerExports.createExperimentObject configPath, layers, controlArg

writeTextFile = (p, content) ->
  fs.mkdirSync path.dirname(p), { recursive: true }
  fs.writeFileSync p, content, 'utf8'

handleGetRecipe = (req, res, query) ->
  name = String(query.get('name') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'name is required' }) unless name.length
  return sendJson(res, 400, { ok: false, error: 'invalid name' }) if name.includes('/') or name.includes('..')
  configPath = runnerExports.resolveConfigPath(name)
  return sendJson(res, 404, { ok: false, error: 'recipe not found', name: name }) unless configPath? and fs.existsSync(configPath)
  text = readText configPath
  parsed = parseRecipeForManifest(name)
  sendJson res, 200,
    ok: true
    name: name
    config_path: path.relative(BASE_ROOT, configPath)
    text: text
    parsed: parsed

handlePutRecipe = (req, res, query) ->
  name = String(query.get('name') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'name is required' }) unless name.length
  return sendJson(res, 400, { ok: false, error: 'invalid name' }) if name.includes('/') or name.includes('..')
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body — expected {"content": "<yaml>"}' }
  content = if typeof payload.content is 'string' then payload.content else null
  return sendJson(res, 400, { ok: false, error: 'content is required' }) unless content?

  parsed = parseYamlSafely content
  return sendJson(res, 400, { ok: false, error: parsed.error }) unless parsed.ok

  steps = discoverStepsLocal parsed.parsed
  topo = validateToposort steps
  return sendJson(res, 400, { ok: false, error: "toposort: #{topo.error}" }) unless topo.ok

  warnings = []
  for own stepName, def of steps
    runRef = def.run
    continue unless typeof runRef is 'string' and runRef.length
    resolved = runnerExports.resolveStepScript(runRef)
    warnings.push "step '#{stepName}' run:'#{runRef}' did not resolve to any existing script" unless resolved?

  target = path.join(CWD, 'config', "#{name}.yaml")
  try
    writeTextFile target, content
  catch err
    return sendJson res, 500, { ok: false, error: "write failed: #{err?.message ? err}" }

  experiment = null
  mergeError = null
  try
    experiment = buildMergedExperimentForName name
  catch err
    mergeError = String(err?.message ? err)

  sendJson res, 200,
    ok: true
    recipe_path: path.relative(BASE_ROOT, target)
    experiment: experiment
    warnings: warnings
    merge_error: mergeError

handleGetOverride = (req, res, query) ->
  recipe = String(query.get('recipe') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'recipe is required' }) unless recipe.length
  return sendJson(res, 400, { ok: false, error: 'invalid recipe name' }) if recipe.includes('/') or recipe.includes('..')
  overridePath = path.join(CWD, 'override', "#{recipe}.yaml")
  exists = fs.existsSync(overridePath)
  text = if exists then readText(overridePath) else ''
  sendJson res, 200,
    ok: true
    recipe: recipe
    override_path: path.relative(BASE_ROOT, overridePath)
    exists: exists
    text: text

handlePutOverride = (req, res, query) ->
  recipe = String(query.get('recipe') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'recipe is required' }) unless recipe.length
  return sendJson(res, 400, { ok: false, error: 'invalid recipe name' }) if recipe.includes('/') or recipe.includes('..')
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body — expected {"content": "<yaml>"}' }
  content = if typeof payload.content is 'string' then payload.content else null
  return sendJson(res, 400, { ok: false, error: 'content is required' }) unless content?

  parsed = parseYamlSafely content
  return sendJson(res, 400, { ok: false, error: parsed.error }) unless parsed.ok

  target = path.join(CWD, 'override', "#{recipe}.yaml")
  try
    writeTextFile target, content
  catch err
    return sendJson res, 500, { ok: false, error: "write failed: #{err?.message ? err}" }

  # Validate the merged result toposorts after the write.
  experiment = null
  mergeError = null
  toposortError = null
  try
    experiment = buildMergedExperimentForName recipe
    if experiment?
      steps = discoverStepsLocal experiment
      topo = validateToposort steps
      toposortError = topo.error unless topo.ok
  catch err
    mergeError = String(err?.message ? err)

  sendJson res, 200,
    ok: true
    override_path: path.relative(BASE_ROOT, target)
    experiment: experiment
    merge_error: mergeError
    toposort_error: toposortError

handleGetScript = (req, res, query) ->
  rel = String(query.get('path') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'path is required (and must be safe — no .., no leading /)' }) unless ensureSafeRelPath rel
  resolved = runnerExports.resolveStepScript rel
  candidates = runnerExports.stepScriptCandidates rel
  return sendJson(res, 404, { ok: false, error: 'script not found', path: rel, candidates: candidates }) unless resolved?
  sendJson res, 200,
    ok: true
    path: rel
    resolved: resolved
    text: readText(resolved, '')
    candidates: candidates

handlePutScript = (req, res, query) ->
  rel = String(query.get('path') ? '').trim()
  return sendJson(res, 400, { ok: false, error: 'path is required (and must be safe — no .., no leading /)' }) unless ensureSafeRelPath rel
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body — expected {"content": "<text>"}' }
  content = if typeof payload.content is 'string' then payload.content else null
  return sendJson(res, 400, { ok: false, error: 'content is required' }) unless content?

  # Optional compile-check for .coffee bodies — catches the most common
  # mistake (a syntax error from a Claude-generated step) before write.
  if rel.endsWith('.coffee')
    try
      require('coffeescript').compile(content)
    catch err
      return sendJson res, 400, { ok: false, error: "compile error: #{err?.message ? err}" }

  target = path.join(CWD, 'scripts', rel)
  try
    writeTextFile target, content
  catch err
    return sendJson res, 500, { ok: false, error: "write failed: #{err?.message ? err}" }

  sendJson res, 200,
    ok: true
    path: rel
    written_to: path.relative(BASE_ROOT, target)
    resolved: runnerExports.resolveStepScript(rel)
    candidates: runnerExports.stepScriptCandidates(rel)

handleClearPipelineState = (req, res) ->
  pipelinePath = path.join(CWD, 'pipeline.json')
  removed = false
  if fs.existsSync(pipelinePath)
    fs.unlinkSync pipelinePath
    removed = true

  sendJson res, 200,
    ok: true
    removed: removed

handleSwitchPipe = (req, res) ->
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body' }

  pipeName = String(payload.pipe ? '').trim()
  if pipeName.length
    return sendJson(res, 400, { ok: false, error: 'invalid pipe name' }) if pipeName.includes('/') or pipeName.includes(path.sep) or pipeName is '.' or pipeName is '..'
    targetCwd = path.join(PIPE_ROOT, pipeName)
    return sendJson(res, 404, { ok: false, error: 'pipe directory not found' }) unless fs.existsSync(targetCwd) and fs.statSync(targetCwd).isDirectory()
  else
    targetCwd = CWD          # empty pipe => restart current workspace in place

  fs.mkdirSync path.join(targetCwd, 'state'), { recursive: true }
  fs.mkdirSync path.join(targetCwd, 'logs'), { recursive: true }

  sendJson res, 200,
    ok: true
    pipe: pipeName
    cwd: targetCwd
    restarting: true

  # Relaunch the target workspace's OWN ui_server.coffee (so a project's edited
  # UI + its runtime.sqlite are preserved); fall back to the shipped one.
  uiServerPath = path.join(targetCwd, 'ui_server.coffee')
  uiServerPath = path.join(EXEC_ROOT, 'ui_server.coffee') unless fs.existsSync(uiServerPath)

  launchArgs = ['-lc', "sleep 1; exec coffee #{JSON.stringify(uiServerPath)}"]
  child = spawn 'bash', launchArgs,
    cwd: targetCwd
    detached: true
    stdio: 'ignore'
    env: Object.assign {}, process.env,
      EXEC: EXEC_ROOT
      CWD: targetCwd
      UI_PORT: String(PORT)
      UI_BIND_MODE: UI_BIND_MODE

  child.unref()
  setTimeout((-> process.exit(0)), 150)

handleMergePipe = (req, res) ->
  bodyText = await readRequestBody req
  payload = {}
  try
    payload = JSON.parse(bodyText ? '{}')
  catch
    return sendJson res, 400, { ok: false, error: 'invalid json body' }

  pipeName = workspacePipeName(CWD)
  return sendJson(res, 400, { ok: false, error: 'current workspace is not under pipes/' }) unless pipeName?

  mergeRun = readMergeRun()
  if mergeRun.is_process_alive is true and Number(mergeRun.pid ? 0) > 0 and mergeRun.status in ['launching', 'running']
    return sendJson res, 200,
      ok: true
      attached: true
      merge_run: mergeRun

  launch = startMerge pipeName
  sendJson res, 200,
    ok: true
    merge_run: launch

# Resolve the static UI: project-owned `CWD/ui/` wins; fall back to
# the runner-shipped `EXEC_ROOT/ui/` if the project hasn't run
# `pipeline ui:init` yet. This is what makes the UI a
# project-customizable surface.
resolveUiAsset = (rel) ->
  projectPath = path.join(CWD, 'ui', rel)
  return projectPath if fs.existsSync(projectPath)
  path.join(EXEC_ROOT, 'ui', rel)

server = http.createServer (req, res) ->
  url = req.url ? '/'
  if url is '/' or url is '/index.html'
    return sendHtml res, resolveUiAsset('index.html')
  if url is '/api/status'
    return sendJson res, 200, buildStatus()
  if url is '/api/manifest'
    try
      return sendJson res, 200, { ok: true, manifest: buildManifest() }
    catch err
      return sendJson res, 500, { ok: false, error: String(err?.message ? err) }
  if url.startsWith('/api/run/')
    rawId = url.slice('/api/run/'.length).split('?')[0]
    try
      runId = decodeURIComponent(rawId)
    catch
      return sendJson res, 400, { ok: false, error: 'invalid run_id encoding' }
    try
      payload = buildRunEvaluation(runId)
    catch err
      return sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    return sendJson res, 404, { ok: false, error: 'run not found', run_id: runId } unless payload?
    return sendJson res, 200, { ok: true, run: payload }
  if url is '/api/sqlite/diff' or url.startsWith('/api/sqlite/diff?')
    # Convenience wrapper over the `changesSince{<arg>}.json` meta request.
    # GET /api/sqlite/diff?since=<run_id|ISO-ts|change_id>
    query = new URL(url, 'http://127.0.0.1').searchParams
    sinceArg = String(query.get('since') ? '').trim()
    return sendJson(res, 400, { ok: false, error: 'since=<run_id|ISO-timestamp|change_id> is required' }) unless sinceArg.length
    # Validate shape client-side so we can return a specific 400 (the Memo
    # layer's internal try/catch otherwise hides the meta-handler throw).
    isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sinceArg)
    isInt  = /^\d+$/.test(sinceArg)
    isIso  = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(sinceArg)
    unless isUuid or isInt or isIso
      return sendJson res, 400,
        ok: false
        error: "since='#{sinceArg}' is not a uuid, ISO 8601 timestamp, or change_id"
        accepted_shapes: ['uuid', 'ISO-8601-timestamp', 'change_id (non-negative integer)']
    try
      value = runSqliteRequestStrict "changesSince{#{sinceArg}}.json"
    catch err
      return sendJson res, 400, { ok: false, error: String(err?.message ? err), since: sinceArg }
    return sendJson res, 404, { ok: false, error: 'change-log diff did not resolve', since: sinceArg } if value is undefined
    return sendJson res, 200, { ok: true, since: sinceArg, diff: value }
  if url.startsWith('/api/sqlite/')
    # /api/sqlite/<encoded-request-key>  → dispatch through meta/sqlite.coffee
    # Args go inside the request key using the meta layer's own `name{arg}.suffix`
    # grammar, URL-encoded. Examples:
    #   /api/sqlite/allStories.jsonl
    #   /api/sqlite/loraTrainingRuns.jsonl
    #   /api/sqlite/storyByID%7Babc-123%7D.json
    rawKey = url.slice('/api/sqlite/'.length)
    rawKey = rawKey.split('?')[0]   # strip any querystring; key lives in the path
    try
      requestKey = decodeURIComponent(rawKey)
    catch
      return sendJson res, 400, { ok: false, error: 'invalid request key encoding' }
    value = runSqliteRequest(requestKey)
    if value is undefined
      return sendJson res, 404, { ok: false, error: 'request key did not resolve', request: requestKey }
    return sendJson res, 200, { ok: true, request: requestKey, value: value }
  if url.startsWith('/api/file?')
    query = new URL(url, 'http://127.0.0.1').searchParams
    relativePath = query.get('path')
    payload = readViewerFile(relativePath)
    return sendJson(res, 404, { ok: false, error: 'file not found' }) unless payload?
    return sendJson res, 200, { ok: true, file: payload }
  # Mutation endpoints (step 4). Dispatch on method; GET reads, PUT writes.
  if url is '/api/recipe' or url.startsWith('/api/recipe?')
    query = new URL(url, 'http://127.0.0.1').searchParams
    if req.method is 'GET'
      return Promise.resolve(handleGetRecipe(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    if req.method is 'PUT'
      return Promise.resolve(handlePutRecipe(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    return sendJson res, 405, { ok: false, error: 'method not allowed; use GET or PUT' }
  if url is '/api/override' or url.startsWith('/api/override?')
    query = new URL(url, 'http://127.0.0.1').searchParams
    if req.method is 'GET'
      return Promise.resolve(handleGetOverride(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    if req.method is 'PUT'
      return Promise.resolve(handlePutOverride(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    return sendJson res, 405, { ok: false, error: 'method not allowed; use GET or PUT' }
  if url is '/api/script' or url.startsWith('/api/script?')
    query = new URL(url, 'http://127.0.0.1').searchParams
    if req.method is 'GET'
      return Promise.resolve(handleGetScript(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    if req.method is 'PUT'
      return Promise.resolve(handlePutScript(req, res, query)).catch (err) ->
        sendJson res, 500, { ok: false, error: String(err?.message ? err) }
    return sendJson res, 405, { ok: false, error: 'method not allowed; use GET or PUT' }
  if url is '/api/launch' and req.method is 'POST'
    return Promise.resolve(handleLaunch(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/control' and req.method is 'POST'
    return Promise.resolve(handleControl(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/human_override' and req.method is 'POST'
    return Promise.resolve(handleHumanOverride(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/clear_pipeline_state' and req.method is 'POST'
    return Promise.resolve(handleClearPipelineState(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/switch_pipe' and req.method is 'POST'
    return Promise.resolve(handleSwitchPipe(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/merge_pipe' and req.method is 'POST'
    # Feature-gate: `merge_sqlite_dbs.coffee` is a writeStory-specific
    # helper not shipped with the runner. Projects that need it can
    # drop it next to `pipeline_runner.coffee` and the endpoint
    # activates automatically.
    unless fs.existsSync(MERGE_SCRIPT)
      return sendJson res, 501,
        ok: false
        error: 'merge feature not available — merge_sqlite_dbs.coffee not present'
    return Promise.resolve(handleMergePipe(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/kill' and req.method is 'POST'
    return Promise.resolve(handleKill(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  if url is '/api/shutdown_ui' and req.method is 'POST'
    return Promise.resolve(handleShutdownUi(req, res)).catch (err) ->
      sendJson res, 500,
        ok: false
        error: String(err?.message ? err)
  res.writeHead 404, 'Content-Type': 'text/plain; charset=utf-8'
  res.end 'not found'

server.listen PORT, HOST, ->
  console.log "[ui_server] listening on http://#{HOST}:#{PORT}"

setInterval ->
  return unless repeatLoop.enabled and repeatLoop.next_launch_at?
  run = readJson path.join(CWD, 'state', 'ui-run.json'), {}
  return unless run?.status is 'cooldown'
  remainingMs = Math.max(0, new Date(repeatLoop.next_launch_at).getTime() - Date.now())
  seconds = Math.ceil(remainingMs / 1000)
  writeUiRunPatch
    loop_enabled: true
    countdown_seconds: seconds
    next_launch_at: repeatLoop.next_launch_at
, 1000
