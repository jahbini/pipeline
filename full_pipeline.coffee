#!/usr/bin/env coffee
###
  pipeline_runner.coffee — Flat-Step Runner (Evaluator-Compatible)
  ---------------------------------------------------------------
  Unified runtime with:
    • Single Memo shared across steps
    • Reactive file persistence for *.json / *.csv / any path-like memo keys
    • In-process execution for CoffeeScript steps defining @step = { action }
    • Centralized MLX runner via M.mlx_runner(params)
    • Declarative MLX steps supported via run_mlx: true + mlx: { ... }
    • depends_on DAG, not nested pipeline.steps

  Workspace model:
    • EXEC = directory containing this file, plus config/ and scripts/
    • CWD  = workspace (train_323, train_324, ...)

  Config selection:
    • override.yaml in CWD is REQUIRED
    • override.yaml MUST contain:  pipeline: <name>
    • Config is loaded from:  $EXEC/config/<pipeline>.yaml

  Schema precedence:
    config/<pipeline>.yaml < override.yaml
###

fs        = require 'fs'
path      = require 'path'
yaml      = require 'js-yaml'
{ spawn, execSync } = require 'child_process'
CoffeeScript = require 'coffeescript'
CoffeeScript.register()

EXEC = process.env.EXEC ? path.dirname(__filename)
CWD  = process.cwd()

# # ---------------------------------------------------------------
# Memo with Meta-Dispatcher
# ---------------------------------------------------------------
class Memo
  constructor: ->
    @MM = {}
    @metaRules = []     # ordered list of {name, regex, handler}
    @currentStep = null
    @initializeMetaRules CWD

  # --------------------------------------------------------------
  # saveThis: now calls meta handler (cached per key)
  # --------------------------------------------------------------
  saveThis: (key, value,HELP=false) ->
    entry = @MM[key]

    # First-time entry → create memo record
    unless entry?
      breaker = null
      maybe = new Promise (resolve) -> breaker = resolve
      entry =
        value: value
        notifier: maybe
        resolver: breaker
        meta: null      # meta handler set on first save
      @MM[key] = entry

      # Initialize meta handler once
      entry.meta = @selectMetaHandler(key)

      # Fire meta handler FIRST (so it has the raw new value)
      try v = entry.meta(key, value) catch e then console.error "Meta init error:", e.message
      entry.value = v if v?
      console.error "JIM entry.meta",key,entry,v if HELP
      return entry

    # Existing entry, update value + notify previous resolver.
    oldResolver = entry.resolver ? null
    breaker = null
    maybe = new Promise (resolve) -> breaker = resolve
    entry.resolver = breaker
    entry.notifier = maybe
    entry.value = value

    oldResolver value if oldResolver

    # Call meta handler for this key
    try entry.meta(key, value) catch e then console.error "Meta update error:", key, e.message
    console.error "JIM meta",key  if HELP

    # After notifier resolves, update stored value
    maybe.then (newval) -> entry.value = newval if newval?

    return entry

  theLowdown: (key,help=false) ->
    return @MM[key] if @MM[key]?
    @saveThis key, undefined,help

  waitFor: (keys, andDo) ->
    unsatisfied = []
    for key in keys
      entry = @theLowdown(key)
      if entry.value is true then continue
      unsatisfied.push entry.notifier

    if unsatisfied.length is 0
      try andDo() catch e then console.error "waitFor immediate:", e.message
      return

    Promise.all(unsatisfied).then ->
      try andDo() catch e then console.error "waitFor deferred:", e.message

  # --------------------------------------------------------------
  # Meta Dispatcher: FIRST match wins, becomes permanent handler
  # --------------------------------------------------------------
  selectMetaHandler: (key) ->
    for rule in @metaRules
      if rule.regex.test(key)
        return rule.handler
    return (k,v)-> return   # no-op if no rules matched

  # --------------------------------------------------------------
  # API to register meta rules in priority order
  # --------------------------------------------------------------
  addMetaRule: (name, regex, handler) ->
    @metaRules.push {name, regex, handler}

  # --------------------------------------------------------------
  # Meta Rules Initialization
  # Call this once after creating Memo instance
  # --------------------------------------------------------------
  initializeMetaRules: (baseDir) ->
    fs = require 'fs'
    path = require 'path'

    # --- Utility writers ----------------------------------------
    writeJSON = (dest, obj) ->
      fs.mkdirSync(path.dirname(dest), {recursive:true})
      fs.writeFileSync(dest, JSON.stringify(obj, null, 2), 'utf8')

    writeCSV = (dest, rows) ->
      fs.mkdirSync(path.dirname(dest), {recursive:true})
      if typeof rows is 'string'
        fs.writeFileSync(dest, rows, 'utf8'); return

      unless Array.isArray(rows)
        throw new Error "CSV expects array or string"
      return unless rows.length and typeof rows[0] is 'object'

      keys = Object.keys(rows[0])
      buf = [keys.join(',')]
      for r in rows
        vals = (String(r[k] ? '').replace(/,/g,';') for k in keys)
        buf.push vals.join(',')
      fs.writeFileSync(dest, buf.join('\n') + '\n', 'utf8')

    writeJSONL = (dest, arr) ->
      fs.mkdirSync(path.dirname(dest), {recursive:true})
      fs.writeFileSync dest, ''
      for t in arr
        fs.appendFileSync dest, JSON.stringify(t) + "\n"
      return

    # ------------------------------------------------------------
    # 1) MLX rules (placeholder hook)
    # ------------------------------------------------------------
    @addMetaRule "mlx-lm agent",
      /^donkeyButt mlx-lm:(train|generate|fuse|convert|lora)$/
      (key, payload) =>
        return unless payload?
        cmdType = key.split(":")[1]
        @callMLX cmdType, payload

    # ------------------------------------------------------------
    # 2) JSONL writer
    # ------------------------------------------------------------
    @addMetaRule "jsonl-writer",
      /\.jsonl$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeJSONL(dest, value)
        console.log "JSONL written:", dest, value.length

    # ------------------------------------------------------------
    # 3) JSON writer
    # ------------------------------------------------------------
    @addMetaRule "json-writer",
      /\.json$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeJSON(dest, value)
        console.log "JSON written:", dest, value.length

    # ------------------------------------------------------------
    # 4) CSV writer
    # ------------------------------------------------------------
    @addMetaRule "csv-writer",
      /\.csv$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeCSV(dest, value)
        console.log "💾 CSV:", dest

    # ------------------------------------------------------------
    # 5) Generic “path with slash” writer (no extension)
    # ------------------------------------------------------------
    @addMetaRule "slash-path-writer",
      /^(?=.*\/)(?!.*\.[A-Za-z0-9]{1,8}$).+$/,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        fs.mkdirSync(path.dirname(dest), {recursive:true})
        data = if Buffer.isBuffer(value) then value else JSON.stringify(value, null, 2)
        fs.writeFileSync(dest, data, 'utf8')
        console.log "💾 FILE:", dest

    # ------------------------------------------------------------
    # 6) No-op fallback
    # ------------------------------------------------------------
    @addMetaRule "noop",
      /.^/,
      (k,v)-> return

  # --------------------------------------------------------------
  # demand: load from filesystem (JSONL/raw) into memo, sync
  # --------------------------------------------------------------
  demand: (key) ->
    # 1. Already in memo?
    if @MM[key]?
      return @MM[key]

    fs   = require 'fs'
    path = require 'path'
    abs  = path.join(process.cwd(), key)

    unless fs.existsSync(abs)
      return undefined

    raw = null
    try
      raw = fs.readFileSync(abs, 'utf8')
    catch e
      return undefined

    value = null
    if /\.jsonl$/i.test(key)
      lines = raw.split(/\r?\n/).filter (l)-> l.trim().length
      objs  = []
      for l in lines
        try
          objs.push JSON.parse(l)
        catch e
          continue
      value = objs
    else
      value = raw

    entry =
      value: value
      notifier: null
      resolver: null
      meta: (-> return)

    @MM[key] = entry
    entry

  # --------------------------------------------------------------
  # callMLX: synchronous MLX wrapper for meta rules
  # --------------------------------------------------------------
  callMLX: (cmdType, payload) ->
    child = require 'child_process'

    buildArgs = (cmdType, params) ->
      args = []
      args.push "-m", "mlx_lm", cmdType
      for k,v of params
        args.push "--#{k}"
        args.push v if v?
      args

    args = buildArgs(cmdType, payload)
    cmd  = "python"

    hdr =
      "=== MLX ERROR ===\n" +
      "Key: #{cmdType}\n" +
      "Payload:#{JSON.stringify(payload,null,2)}\n" +
      "Command:#{cmd} #{args.join " "}\n"

    try
      proc = child.spawnSync(cmd, args, {encoding:'utf8'})
    catch e
      console.error hdr + "spawn failed:\n#{e.message}"
      throw e

    if proc.status isnt 0
      console.error hdr + "stderr:\n#{proc.stderr}"
      throw new Error "MLX command failed for #{cmdType}"

    proc.stdout

# -------------------------------------------------------------------
# Utilities
# -------------------------------------------------------------------
banner = (msg) -> console.log "\n=== #{msg} ==="
prefixLines = (pfx, s) -> (s ? '').split(/\r?\n/).map((l)-> pfx + l).join("\n")
isPlainObject = (o) -> Object.prototype.toString.call(o) is '[object Object]'

deepMerge = (target, source) ->
  return target unless source?
  for own k, v of source
    if v is null
      delete target[k]
      continue
    if isPlainObject(v) and isPlainObject(target[k])
      deepMerge target[k], v
    else
      target[k] = Array.isArray(v) and v.slice() or v
  target

loadYamlSafe = (p) ->
  return {} unless p? and fs.existsSync(p)
  yaml.load fs.readFileSync(p, 'utf8') or {}

expandIncludes = (spec, baseDir) ->
  incs = spec.include
  return spec unless incs? and Array.isArray(incs) and incs.length > 0
  merged = JSON.parse(JSON.stringify(spec))
  for inc in incs
    incPath = path.isAbsolute(inc) and inc or path.join(baseDir, inc)
    sub = loadYamlSafe(incPath)
    merged = deepMerge merged, sub
  merged

### Restart helpers (done flags on disk) ###

bootstrapDoneFlags = (M, spec) ->
  stateDir = path.join(process.cwd(), 'state')
  return unless fs.existsSync(stateDir)

  for own name, val of spec
    continue unless isPlainObject(val)
    fp = path.join(stateDir, "done-#{name}.json")
    continue unless fs.existsSync(fp)
    try
      st = JSON.parse fs.readFileSync(fp, 'utf8')
      if st?.done is true
        console.log "↺ restoring done:#{name} from state/"
        M.saveThis "done:#{name}", true
    catch e
      console.error "state restore failed for #{name}:", e.message

persistDone = (stepName) ->
  try
    stateDir = path.join(process.cwd(), 'state')
    fs.mkdirSync stateDir, {recursive:true}
    fp = path.join(stateDir, "done-#{stepName}.json")
    payload =
      done: true
      finished_at: new Date().toISOString()
    fs.writeFileSync fp, JSON.stringify(payload, null, 2), 'utf8'
    console.log "💾 state/done-#{stepName}.json"
  catch e
    console.error "persistDone failed for #{stepName}:", e.message

# -------------------------------------------------------------------
# Build experiment.yaml (config < override)
# -------------------------------------------------------------------
createExperimentYaml = (configPath, overridePath) ->
  banner "🔧 Creating experiment.yaml"
  baseAbs  = path.resolve(configPath)
  baseDir  = path.dirname(baseAbs)

  recipe   = loadYamlSafe(baseAbs)
  recipe   = expandIncludes(recipe, baseDir)
  override = loadYamlSafe(overridePath)

  merged = deepMerge {}, recipe
  merged = deepMerge merged, override

  expPath = path.join(process.cwd(), 'experiment.yaml')
  fs.writeFileSync expPath, yaml.dump(merged), 'utf8'
  console.log "✅ Wrote experiment.yaml:", expPath
  expPath

# -------------------------------------------------------------------
# Step discovery (flat map)
# -------------------------------------------------------------------
discoverSteps = (spec) ->
  steps = {}
  for own key, val of spec
    continue if key is 'run'
    continue unless isPlainObject(val)
    if val.run? or val.run_mlx is true
      deps = []
      if val.depends_on?
        if Array.isArray(val.depends_on)
          deps = val.depends_on.slice()
        else if typeof val.depends_on is 'string'
          deps = [val.depends_on]
        if deps.length is 1 and String(deps[0]).toLowerCase() is 'never'
          console.log "⏭️  skipping step #{key} (depends_on: never)"
          continue
      def = {}
      for own k2, v2 of val
        def[k2] = v2
      def.depends_on = deps unless deps.length == 0
      steps[key] = def
  if Object.keys(steps).length is 0
    throw new Error "No steps discovered in experiment.yaml"
  steps

# -------------------------------------------------------------------
# DAG helpers
# -------------------------------------------------------------------
toposort = (steps) ->
  indeg = {}; graph = {}
  for own name, def of steps
    indeg[name] = 0; graph[name] = []
  for own name, def of steps
    for dep in def.depends_on or []
      unless steps[dep]?
        throw new Error "Undefined dependency '#{dep}' (by '#{name}')"
      indeg[name] += 1
      graph[dep].push name
  q = (n for own n, d of indeg when d is 0)
  order = []
  while q.length
    n = q.shift()
    order.push n
    for m in graph[n]
      indeg[m] -= 1
      q.push(m) if indeg[m] is 0
  if order.length isnt Object.keys(steps).length
    missing = Object.keys(steps).filter (k)-> order.indexOf(k) is -1
    console.error "⚠️ DAG anomaly; missing:", missing.join(', ')
  order

terminalSteps = (steps) ->
  dependents = new Set()
  for own name, def of steps
    for dep in def.depends_on or [] then dependents.add dep
  (n for own n, _ of steps when not dependents.has(n))

emitDot = (steps, outPath) ->
  try
    lines = ['digraph pipeline {','  rankdir=LR;']
    for own n, d of steps
      lines.push "  \"#{n}\" [shape=box];"
    for own n, d of steps
      for dep in d.depends_on or []
        lines.push "  \"#{dep}\" -> \"#{n}\";"
    lines.push '}'
    fs.writeFileSync outPath, lines.join("\n"), "utf8"
    console.log "🖼  Wrote DOT graph:", outPath
  catch e
    console.error "DOT write failed:", e.message

# -------------------------------------------------------------------
# Single-instance guard
# -------------------------------------------------------------------
ensureSingleInstance = ->
  try
    scriptPath = path.resolve(__filename)
    out = execSync("ps -Ao pid,command | grep 'coffee' | grep '#{scriptPath}' | grep -v grep || true").toString()
    lines = out.trim().split("\n").filter (l)-> l.length>0
    others = lines.filter (l)-> not l.startsWith(process.pid.toString())
    if others.length>0 then process.exit(0)
  catch err
    console.error "Instance check error:", err.message

# -------------------------------------------------------------------
# MLX Runner
# -------------------------------------------------------------------
runMLX = (stepName, params={}) ->
  new Promise (resolve, reject) ->
    mod   = params.module ? 'mlx_lm'
    entry = params.entry  ? 'generate'
    args  = params.args   ? []
    cmd   = 'python'
    argv  = ['-m', mod, entry].concat args

    console.log "⚙️  #{stepName}: mlx #{argv.join(' ')}"
    proc = spawn cmd, argv,
      cwd: params.cwd ? process.cwd()
      env: Object.assign({}, process.env, params.env or {})
      stdio: ['ignore','pipe','pipe']

    out = ''
    proc.stdout.on 'data', (d) ->
      s = d.toString(); out += s
      process.stdout.write prefixLines("mlx| #{stepName} | ", s)
    proc.stderr.on 'data', (d) ->
      process.stderr.write prefixLines("! mlx #{stepName} | ", d.toString())
    proc.on 'error', (e) -> reject e
    proc.on 'exit', (code) ->
      if code is 0 then resolve out else reject new Error "mlx failed #{code}"

# -------------------------------------------------------------------
# Step Runner
# -------------------------------------------------------------------
isNewStyleStep = (scriptPath) ->
  try
    src = fs.readFileSync(scriptPath, 'utf8')
    /\@step\s*=/.test(src)
  catch e
    false

runStep = (stepName, def, expPath, M) ->
  new Promise (resolve, reject) ->
    # Declarative MLX steps
    if def.run_mlx is true
      params = def.mlx ? {}
      runMLX(stepName, params)
        .then (stdout) ->
          if typeof params.capture_stdout_key is 'string'
            M.saveThis params.capture_stdout_key, stdout
          M.saveThis "#{stepName}:mlx_stdout", stdout
          M.saveThis "done:#{stepName}", true
          persistDone stepName
          resolve true
        .catch (e) ->
          console.error "! #{stepName} mlx failed:", e.message
          M.saveThis "done:#{stepName}", false
          reject e
      return

    unless def.run?
      return reject new Error "Step '#{stepName}' missing 'run' (and not run_mlx)"

    # NOTE: def.run is now a path like "kag_oracle/md2segments.coffee"
    # under EXEC/scripts/
    scriptAbs = path.join(EXEC, 'scripts', def.run)

    # Inline CoffeeScript @step
    if /\.coffee$/i.test(scriptAbs) and isNewStyleStep(scriptAbs)
      console.log "⚙️ inline @step (require):", stepName
      stepModule = require scriptAbs
      step = stepModule?.step or global?.step
      unless step?.action?
        return reject new Error "Missing @step.action in #{stepName}"

      Promise.resolve(step.action(M, stepName))
        .then ->
          M.saveThis "done:#{stepName}", true
          persistDone stepName
          resolve true
        .catch (e) ->
          console.error "! #{stepName} failed:", e.message
          M.saveThis "done:#{stepName}", false
          reject e
      return

    # Python or legacy CoffeeScript via spawn
    interp = null; args = []
    if /\.py$/i.test(scriptAbs)
      interp = 'python'; args = ['-u', scriptAbs]
    else if /\.coffee$/i.test(scriptAbs)
      interp = 'coffee'; args = [scriptAbs]
    else
      return reject new Error "Unknown script type for #{stepName}: #{scriptAbs}"

    console.log "▶️  #{stepName}: #{interp} #{args.join(' ')}"
    proc = spawn(interp, args,
      stdio: ['ignore','pipe','pipe']
      env: Object.assign({}, process.env,
        CFG_OVERRIDE: expPath
        STEP_NAME: stepName
        STEP_PARAMS_JSON: JSON.stringify(def)
      )
    )
    proc.stdout.on 'data', (buf) -> process.stdout.write prefixLines("┆ #{stepName} | ", buf.toString())
    proc.stderr.on 'data', (buf) -> process.stderr.write prefixLines("! #{stepName} | ", buf.toString())
    proc.on 'error', (err) -> reject err
    proc.on 'exit', (code) ->
      if code is 0
        M.saveThis "done:#{stepName}", true
        persistDone stepName
        resolve true
      else
        console.error "! #{stepName} exited:", code
        M.saveThis "done:#{stepName}", false
        reject new Error "#{stepName} failed #{code}"

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main = ->
  ensureSingleInstance()

  console.log "CWD:", CWD
  console.log "EXEC:", EXEC

  # --- Mandatory override.yaml + pipeline name ---
  overridePath = path.join(CWD, 'override.yaml')
  unless fs.existsSync(overridePath)
    console.error "❌ override.yaml not found in workspace:", overridePath
    console.error "   Working directory must contain an override.yaml with:"
    console.error "     pipeline: <name>   # e.g. full, kag, kag_oracle"
    process.exit(1)

  override = loadYamlSafe(overridePath)
  unless override.pipeline?
    console.error "❌ override.yaml missing required key: pipeline"
    console.error "   Example:"
    console.error "     pipeline: full"
    console.error "     pipeline: kag"
    console.error "     pipeline: kag_oracle"
    process.exit(1)

  basePipeline = String(override.pipeline)
  console.log "Pipeline:", basePipeline

  configPath = path.join(EXEC, 'config', basePipeline + '.yaml')
  unless fs.existsSync(configPath)
    console.error "❌ Config not found for pipeline:", basePipeline
    console.error "   Expected:", configPath
    process.exit(1)

  banner "Recipe: #{basePipeline}"

  expPath = createExperimentYaml(configPath, overridePath)
  spec    = loadYamlSafe(expPath)

  M = new Memo()
  M.saveThis "experiment.yaml", spec
  M.mlx_runner = (params={}) -> runMLX("mlx", params)

  # bootstrap done flags before wiring the DAG
  bootstrapDoneFlags(M, spec)

  steps = discoverSteps(spec)
  order = toposort(steps)
  console.log "Discovered steps:", Object.keys(steps).join(', ')
  console.log "Topo order:", order.join(' → ')

  # Persist params for each step
  for own n, d of steps
    M.saveThis "params/#{n}.json", d

  # Run DAG
  for own name, def of steps
    do (name, def) ->
      deps = def.depends_on or []
      fire = ->
        runStep(name, def, expPath, M)
          .catch (err) -> console.error "! Step #{name} error:", err.message
          .then ->
            console.log "JAH fini", name
            M.saveThis "done:#{name}", true
            persistDone name
      if deps.length is 0
        console.log "▶️ starting root step #{name}"
        fire()
      else
        console.log "⏳ waiting for deps of #{name}: #{deps.join(', ')}"
        M.waitFor (deps.map (d)-> "done:#{d}"), -> fire()

  finals = terminalSteps(steps)
  Promise.all( finals.map((s)-> M.theLowdown("done:#{s}").notifier) ).then ->
    banner "🌟 Pipeline finished (final: #{finals.join(', ')})"
    process.exit(0)
  .catch (e) ->
    console.error "Pipeline failed:", e.message
    process.exit(1)

process.on 'SIGINT', ->
  console.log "\n(CTRL+C) Exiting..."
  process.exit(130)

main().catch (e) ->
  console.error "Fatal:", String(e?.message or e)
  process.exit(1)
