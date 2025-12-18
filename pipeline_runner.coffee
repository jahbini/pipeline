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

  Compatible with pipeline_evaluator.coffee
  -----------------------------------------
  - Same Memo runtime, regex persistence, and @step execution model.
  - CoffeeScript steps can access the shared memo via their @step.action(M).
  - Outputs auto-saved if memo key contains "/" or file extension.

  Schema precedence:
    recipe < config/default.yaml < override.yaml
###

fs        = require 'fs'
path      = require 'path'
yaml      = require 'js-yaml'
{ spawn, execSync } = require 'child_process'
CoffeeScript = require 'coffeescript'
CoffeeScript.register()

EXEC = process.env.EXEC
CWD =  process.cwd()

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
  saveThis: (key, value) ->
    entry = @MM[key]

    # First-time entry → create memo record
    unless entry?
      # value is stored BEFORE meta dispatch; this matters.
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
      try v=entry.meta(key, value) catch e then console.error "Meta init error:", e.message
      entry.value = v if v
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
    try v=entry.meta(key, value) catch e then console.error "Meta update error:",key, e.message

    # After notifier resolves, update stored value
    maybe.then (newval) -> entry.value = newval

    return entry

  theLowdown: (key) ->
    return @MM[key] if @MM[key]?
    @saveThis key, undefined

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
    # 1) MLX rules (highest priority)
    # ------------------------------------------------------------
    this.addMetaRule "mlx-lm agent",
      /^donkeyButt mlx-lm:(train|generate|fuse|convert|lora)$/
      (key, payload) =>
        return unless payload?
        cmdType = key.split(":")[1]
        @runMlxCommand(key, cmdType, payload)


    # ------------------------------------------------------------
    # 2) JSONL writer
    # ------------------------------------------------------------
    this.addMetaRule "jsonl-writer",
      /\.jsonl$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeJSONL(dest, value)
        console.log "💾 JSONL:", dest


    # ------------------------------------------------------------
    # 3) JSON writer
    # ------------------------------------------------------------
    this.addMetaRule "json-writer",
      /\.json$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeJSON(dest, value)
        console.log "💾 JSON:", dest


    # ------------------------------------------------------------
    # 4) CSV writer
    # ------------------------------------------------------------
    this.addMetaRule "csv-writer",
      /\.csv$/i,
      (key, value) ->
        return unless value?
        dest = path.join(baseDir, key)
        writeCSV(dest, value)
        console.log "💾 CSV:", dest


    # ------------------------------------------------------------
    # 5) Generic “path with slash” writer (no extension)
    # ------------------------------------------------------------
    this.addMetaRule "slash-path-writer",
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
    this.addMetaRule "noop",
      /.^/,
      (k,v)-> return

  demand: (key) ->
    # 1. Already in memo?
    if @MM[key]?
      return @MM[key]

    # 2. Try filesystem load
    fs   = require 'fs'
    path = require 'path'
    abs  = path.join(process.cwd(), key)

    unless fs.existsSync(abs)
      return undefined

    raw = null
    try
      raw = fs.readFileSync(abs, 'utf8')
    catch e
      return undefined   # silently fail per requirements

    # 3. Decode JSONL vs raw
    value = null
    if /\.jsonl$/i.test(key)
      lines = raw.split(/\r?\n/).filter (l)-> l.trim().length
      objs  = []
      for l in lines
        try
          objs.push JSON.parse(l)
        catch e
          continue   # skip malformed lines quietly
      value = objs
    else
      value = raw

    # 4. Store into memo in canonical structure
    entry =
      value: value
      notifier: null
      resolver: null
      meta: (-> return)   # no-op meta handler for loaded files

    @MM[key] = entry

    # 5. Return stored entry
    entry
  # --------------------------------------------------------------
  # runMlxCommand: same as before, but simplified to work with meta
  # --------------------------------------------------------------
  callMLX: ( cmdType, payload) ->
    child = require 'child_process'

    shQuote = (s) -> "'" + s.replace(/'/g, "'\\''") + "'"

    # Marshal payload → python args (you already have this)
    buildArgs = (cmdType, params) ->
      args = []
      args.push "-m", "mlx_lm", cmdType
      for k,v of params
        args.push "--#{k}"
        args.push v if v
      args

    args = buildArgs(cmdType, payload)
    cmd = "python"

    extractJSON = (raw) ->
      return null unless raw?
    
      # 1) Extract anything between a pair of curly braces, longest match first
      m = raw.match(/\{[\s\S]*\}/)
      return null unless m?
    
      block = m[0]
    
    hdr =
      "=== MLX ERROR ===\n" +
      "Key: #{cmdType}\n" +
      "Payload:\n#{JSON.stringify(payload,null,2)}\n" +
      "Command:\n#{cmd}\n"

    try
      proc = child.spawnSync(cmd, args, { encoding:'utf8'})
    catch e
      console.error hdr + "spawn failed:\n#{e.message}"
      throw e

    if proc.status isnt 0
      console.error hdr + "stderr:\n#{proc.stderr}"
      throw new Error "MLX command failed for #{cmdType}"

    # Overwrite the memo entry with the result (your rule)
    return  proc.stdout
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
  fileContents = fs.readFileSync(p, 'utf8') or {}
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

# -------------------------------------------------------------------
# Build experiment.yaml (recipe < config < override)
# -------------------------------------------------------------------
createExperimentYaml = (basePath, defaultConfig, overridePath) ->
  banner "🔧 Creating experiment.yaml"
  baseAbs  = path.resolve(basePath)
  baseDir  = path.dirname(baseAbs)

  recipe   = loadYamlSafe(baseAbs)
  recipe   = expandIncludes(recipe, baseDir)
  defaults = loadYamlSafe(defaultConfig)
  override = loadYamlSafe(overridePath)

  merged = deepMerge {}, defaults
  merged = deepMerge merged, recipe
  merged = deepMerge merged, override

  expPath = path.join(process.cwd(), 'experiment.yaml')
  fs.writeFileSync expPath, yaml.dump(merged), 'utf8'
  console.log "✅ Wrote experiment.yaml:", expPath
  expPath

# -------------------------------------------------------------------
# Step discovery (flat map)
# -------------------------------------------------------------------
###
discoverSteps(spec, recipe)
---------------------------------------
Return only steps explicitly declared in the recipe.
Any top-level entries with `run:` that are *not* in the recipe
are ignored, even if valid in the config.
###
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
  try src = fs.readFileSync(scriptPath, 'utf8'); /\@step\s*=/.test(src)
  catch e then false

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
          resolve true
        .catch (e) ->
          console.error "! #{stepName} mlx failed:", e.message
          M.saveThis "done:#{stepName}", false
          reject e
      return

    unless def.run?
      return reject new Error "Step '#{stepName}' missing 'run' (and not run_mlx)"

    scriptAbs = path.join(EXEC, def.run)

    # Inline CoffeeScript @step
    if /\.coffee$/i.test(scriptAbs) and isNewStyleStep(scriptAbs)
      console.log "⚙️ inline @step (require):", stepName
      stepModule = require scriptAbs
      step = stepModule?.step or global?.step
      unless step?.action?
        return reject new Error "Missing @step.action in #{stepName}"

      Promise.resolve(step.action(M,stepName))
        .then ->
          M.saveThis "done:#{stepName}", true
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
      if code is 0 then M.saveThis "done:#{stepName}", true; resolve true \
      else
        console.error "! #{stepName} exited:", code
        M.saveThis "done:#{stepName}", false
        reject new Error "#{stepName} failed #{code}"

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------
main = ->
  ensureSingleInstance()

  baseRecipe = process.argv[2] or 'full'
  dotOut     = process.env.DOT_OUT or process.argv[3] or null

  console.log "CWD:", process.cwd()
  console.log "EXEC:", EXEC
  banner "Recipe: #{baseRecipe}"

  defaultConfig = path.join(EXEC, 'config', baseRecipe+'.yaml')
  recipeInUse = path.join(EXEC, 'recipes', baseRecipe+'.yaml')
  overridePath  = path.join(process.cwd(), 'override.yaml')

  expPath = createExperimentYaml(recipeInUse, defaultConfig, overridePath)
  spec    = loadYamlSafe(expPath)
  recipe  = loadYamlSafe recipeInUse

  M = new Memo()
  M.saveThis "experiment.yaml", spec
  M.mlx_runner = (params={}) -> runMLX("mlx", params)

  steps = discoverSteps(spec)
  order = toposort(steps)
  console.log "Discovered steps:", Object.keys(steps).join(', ')
  console.log "Topo order:", order.join(' → ')
  if dotOut? then emitDot steps, dotOut

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
             console.log "JAH fini",name
             M.saveThis "done:#{name}", true
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
