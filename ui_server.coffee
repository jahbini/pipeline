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
  # We used to require `ui/index.html` here too, but the UI now
  # lives at the *project* root (copied via `pipeline-runner
  # ui:init`). EXEC_ROOT is identified by runner-shipped assets
  # only: `pipeline_runner.coffee` + `meta/`. The static UI is
  # resolved separately, project-first with EXEC_ROOT fallback.
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
  pushCandidate path.dirname(__filename)
  pushCandidate process.cwd()
  pushCandidate CWD
  pushCandidate path.dirname(CWD)
  pushCandidate path.dirname(path.dirname(CWD))

  for candidate in candidates when looksLikeExecRoot(candidate)
    return candidate

  candidates[0] ? path.dirname(__filename)

EXEC_ROOT = resolveExecRoot()
RUNNER = path.join(EXEC_ROOT, 'pipeline_runner.coffee')
# Path to the npm bin wrapper. Spawning this via `process.execPath`
# (the running node binary) avoids any dependency on a globally
# installed `coffee`; the wrapper registers the CoffeeScript loader
# and then defers to the runner. See bin/pipeline-runner.js.
RUNNER_BIN = path.join(EXEC_ROOT, 'bin', 'pipeline-runner.js')
MERGE_SCRIPT = path.join(EXEC_ROOT, 'merge_sqlite_dbs.coffee')

PIPES_ROOT = path.join(EXEC_ROOT, 'pipes')
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
  rel = path.relative(PIPES_ROOT, workspacePath)
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
  return [] unless fs.existsSync(PIPES_ROOT)
  names = fs.readdirSync(PIPES_ROOT).filter (name) ->
    full = path.join(PIPES_ROOT, name)
    try
      fs.statSync(full).isDirectory()
    catch
      false
  names.sort (a, b) -> String(a).localeCompare String(b)

buildPipeSummary = ->
  current = workspacePipeName(CWD)
  pipes = (name: name, is_active: name is current for name in listPipeDirectories())
  {
    root: PIPES_ROOT
    current: current
    workspace: CWD
    pipes: pipes
  }

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
  readYaml path.join(EXEC_ROOT, 'config', "#{pipeline}.yaml")

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
    pipelines: [
      'base_ite'
      'oracle_ite'
      'lora_ite'
      'diary_ite'
      'diary_translate_ite'
      'prompt_ite'
      'story_scan'
      'lora_scan'
    ]
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

  configPath = path.join(EXEC_ROOT, 'config', "#{pipeline}.yaml")
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

  {
    run: run
    merge_run: mergeRun
    pipeline_state: pipelineState
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
  }

isAllowedFilePath = (relativePath) ->
  return false unless typeof relativePath is 'string' and relativePath.length
  normalized = path.normalize(relativePath)
  return false if normalized.startsWith('..') or path.isAbsolute(normalized)
  /^logs\//.test(normalized) or /^out\//.test(normalized) or /^diary\//.test(normalized) or /^build\//.test(normalized)

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

  child = spawn process.execPath, [RUNNER_BIN],
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
  return sendJson(res, 400, { ok: false, error: 'pipe is required' }) unless pipeName.length
  return sendJson(res, 400, { ok: false, error: 'invalid pipe name' }) if pipeName.includes('/') or pipeName.includes(path.sep) or pipeName is '.' or pipeName is '..'

  targetCwd = path.join(PIPES_ROOT, pipeName)
  return sendJson(res, 404, { ok: false, error: 'pipe directory not found' }) unless fs.existsSync(targetCwd) and fs.statSync(targetCwd).isDirectory()
  return sendJson(res, 200, { ok: true, pipe: pipeName, cwd: targetCwd, unchanged: true }) if path.resolve(targetCwd) is path.resolve(CWD)

  fs.mkdirSync path.join(targetCwd, 'state'), { recursive: true }
  fs.mkdirSync path.join(targetCwd, 'logs'), { recursive: true }

  sendJson res, 200,
    ok: true
    pipe: pipeName
    cwd: targetCwd
    restarting: true

  launchArgs = ['-lc', "sleep 1; exec coffee #{JSON.stringify(path.join(EXEC_ROOT, 'ui_server.coffee'))}"]
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
# `pipeline-runner ui:init` yet. This is what makes the UI a
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
  if url.startsWith('/api/file?')
    query = new URL(url, 'http://127.0.0.1').searchParams
    relativePath = query.get('path')
    payload = readViewerFile(relativePath)
    return sendJson(res, 404, { ok: false, error: 'file not found' }) unless payload?
    return sendJson res, 200, { ok: true, file: payload }
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
