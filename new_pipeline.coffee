#!/usr/bin/env coffee
###
pipeline_runner_clean.coffee — Flat DAG Runner (CALLMLX + STATE DIR, CLEAN)
===========================================================================

Hard guarantees:
• callMLX EXISTS and is used via Memo meta rules
• Memo meta-dispatch preserved (read + write)
• experiment.yaml is saved into Memo BEFORE any step runs
• Step params are saved into Memo BEFORE any step runs
• State protocol:
    - One file per step: state/step-<name>.json
    - State is consulted ONLY at startup
    - Runner records running/done/failed for each step
    - restart_here is consumed at startup; downstream state is DELETED (so old "done" can’t inhibit reruns)
• CRITICAL FIX:
    - Memo.saveThis resolves notifier for boolean values EVERY TIME (not just first write)
###

fs        = require 'fs'
path      = require 'path'
yaml      = require 'js-yaml'
{ spawn, execSync } = require 'child_process'
CoffeeScript = require 'coffeescript'
CoffeeScript.register()

EXEC = process.env.EXEC ? path.dirname(__filename)
CWD  = process.cwd()

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
      delete target[k]; continue
    if isPlainObject(v) and isPlainObject(target[k])
      deepMerge target[k], v
    else
      target[k] = Array.isArray(v) and v.slice() or v
  target

loadYamlSafe = (p) ->
  return {} unless p? and fs.existsSync(p)
  yaml.load fs.readFileSync(p,'utf8') or {}

expandIncludes = (spec, baseDir) ->
  incs = spec.include
  return spec unless incs? and Array.isArray(incs)
  merged = JSON.parse(JSON.stringify(spec))
  for inc in incs
    incPath = path.isAbsolute(inc) and inc or path.join(baseDir, inc)
    merged = deepMerge merged, loadYamlSafe(incPath)
  merged

ensureSingleInstance = ->
  try
    scriptPath = path.resolve(__filename)
    out = execSync("ps -Ao pid,command | grep 'coffee' | grep '#{scriptPath}' | grep -v grep || true").toString()
    lines = out.trim().split("\n").filter (l)-> l.length>0
    others = lines.filter (l)-> not l.startsWith(process.pid.toString())
    if others.length>0 then process.exit(0)
  catch then null

# -------------------------------------------------------------------
# State Directory: One file per step
# -------------------------------------------------------------------
class StepStateStore
  constructor: (@dir) ->
    fs.mkdirSync(@dir, {recursive:true})

  _pathFor: (n) -> path.join(@dir, "step-#{n}.json")

  read: (n) ->
    p = @_pathFor(n)
    return null unless fs.existsSync(p)
    try JSON.parse(fs.readFileSync(p,'utf8')) catch then null

  write: (n, obj) ->
    payload = Object.assign {}, obj,
      step: n
      updated_at: new Date().toISOString()
    fs.writeFileSync @_pathFor(n), JSON.stringify(payload, null, 2), 'utf8'
    payload

  delete: (n) ->
    p = @_pathFor(n)
    return false unless fs.existsSync(p)
    fs.unlinkSync(p)
    true

  markRunning: (n) ->
    @write n,
      status: 'running'
      done: false
      started_at: new Date().toISOString()

  markDone: (n, extra={}) ->
    @write n, Object.assign {}, extra,
      status: 'done'
      done: true
      dirty: false
      finished_at: new Date().toISOString()

  markFailed: (n, errMsg, extra={}) ->
    @write n, Object.assign {}, extra,
      status: 'failed'
      done: false
      error: String(errMsg ? 'unknown error')
      finished_at: new Date().toISOString()

  clearRestartHere: (n) ->
    st = @read(n)
    return unless st?.restart_here is true
    st.restart_here = false
    st.restart_consumed_at = new Date().toISOString()
    @write n, st

# -------------------------------------------------------------------
# Memo with Meta-Dispatcher (CALLMLX PRESERVED)
# -------------------------------------------------------------------
class Memo
  constructor: ->
    @MM = {}
    @metaRules = []
    @initializeMetaRules CWD

  _newEntry: (key, value) ->
    breaker = null
    p = new Promise (resolve) -> breaker = resolve
    entry =
      value: value
      notifier: p
      resolver: breaker
      meta: @selectMetaHandler(key)
    entry

  _resolve: (entry, value) ->
    try entry.resolver?(value) catch then null

  saveThis: (key, value) ->
    entry = @MM[key]
    unless entry?
      entry = @_newEntry(key, value)
      @MM[key] = entry
      try rv = entry.meta(key, value) catch then null
      entry.value = rv if rv?
      @_resolve(entry, value) if value is true or value is false
      return entry

    old = entry.resolver
    entry = @MM[key] = @_newEntry(key, value)
    try old?(value) catch then null
    try rv = entry.meta(key, value) catch then null
    entry.value = rv if rv?
    @_resolve(entry, value) if value is true or value is false   # <<< CRITICAL FIX
    entry.notifier.then (nv) -> entry.value = nv if nv?
    entry

  theLowdown: (key) ->
    entry = @MM[key]
    unless entry?
      entry = @_newEntry(key, undefined)
      @MM[key] = entry
      try rv = entry.meta(key, undefined) catch then null
      if rv?
        entry.value = rv
        @_resolve(entry, rv)
      return entry

    if entry.value is undefined
      try rv = entry.meta(key, undefined) catch then null
      if rv?
        entry.value = rv
        @_resolve(entry, rv)
    entry

  waitFor: (keys, andDo) ->
    entries = ( @theLowdown(k) for k in keys )
    return if entries.some((e)-> e.value is false)
    if entries.every((e)-> e.value is true)
      try andDo() catch then null
      return
    Promise.all(entries.map((e)-> e.notifier)).then =>
      return if keys.some((k)-> @theLowdown(k).value is false)
      try andDo() catch then null

  selectMetaHandler: (key) ->
    for r in @metaRules when r.regex.test(key)
      return r.handler
    (k,v)-> return

  addMetaRule: (name, regex, handler) ->
    @metaRules.push {name, regex, handler}

  initializeMetaRules: (baseDir) ->
    fs2 = require 'fs'
    path2 = require 'path'

    readText = (p) -> if fs2.existsSync(p) then fs2.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs2.mkdirSync(path2.dirname(p),{recursive:true}); fs2.writeFileSync(p,s,'utf8')

    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readJSONL = (p) ->
      raw = readText(p); return undefined unless raw?
      out=[]
      for l in raw.split(/\r?\n/) when l.trim().length
        try out.push JSON.parse(l) catch then continue
      out

    # ---- MLX META RULE (CALLMLX) ----
    @addMetaRule "mlx-meta",
      /^donkeyButt mlx-lm:(train|generate|fuse|convert|lora)$/,
      (key, payload) =>
        return unless payload?
        cmd = key.split(":")[1]
        @callMLX cmd, payload

    # ---- JSONL ----
    @addMetaRule "jsonl",
      /\.jsonl$/i,
      (key, value) ->
        dest = path2.join(baseDir, key)
        if value is undefined
          return readJSONL(dest)
        fs2.mkdirSync(path2.dirname(dest),{recursive:true})
        fs2.writeFileSync(dest,'','utf8')
        for t in value
          fs2.appendFileSync(dest, JSON.stringify(t)+"\n",'utf8')
        value

    # ---- JSON ----
    @addMetaRule "json",
      /\.json$/i,
      (key, value) ->
        dest = path2.join(baseDir, key)
        if value is undefined
          return readJSON(dest)
        writeText(dest, JSON.stringify(value,null,2))
        value

    # ---- slash-path ----
    @addMetaRule "slash",
      /^(?=.*\/)(?!.*\.[A-Za-z0-9]{1,8}$).+$/,
      (key, value) ->
        dest = path2.join(baseDir, key)
        if value is undefined
          return readText(dest)
        fs2.mkdirSync(path2.dirname(dest),{recursive:true})
        data = if Buffer.isBuffer(value) then value else JSON.stringify(value,null,2)
        fs2.writeFileSync(dest,data)
        value

  callMLX: (cmdType, payload) ->
    buildArgs = (cmdType, params) ->
      args = ['-m','mlx_lm',cmdType]
      for k,v of params
        args.push "--#{k}"
        args.push v if v?
      args

    args = buildArgs(cmdType, payload)
    spawnSync = require('child_process').spawnSync
    res = spawnSync 'python', args, {encoding:'utf8'}
    if res.status isnt 0
      throw new Error "MLX failed: #{res.stderr}"
    res.stdout

# -------------------------------------------------------------------
# Experiment + DAG
# -------------------------------------------------------------------
createExperimentYaml = (configPath, overridePath) ->
  recipe = expandIncludes loadYamlSafe(configPath), path.dirname(configPath)
  merged = deepMerge {}, recipe
  merged = deepMerge merged, loadYamlSafe(overridePath)
  out = path.join(CWD,'experiment.yaml')
  fs.writeFileSync out, yaml.dump(merged),'utf8'
  out

normalizeDeps = (d) ->
  return [] unless d?
  return d.slice() if Array.isArray(d)
  return [d] if typeof d is 'string'
  []

discoverSteps = (spec) ->
  steps = {}
  for own k, v of spec
    continue unless isPlainObject(v)
    continue unless v.run? or v.run_mlx
    def = Object.assign {}, v
    def.depends_on = normalizeDeps(v.depends_on)
    steps[k] = def
  steps

toposort = (steps) ->
  indeg = {}; g = {}
  for own n of steps
    indeg[n]=0; g[n]=[]
  for own n, d of steps
    for dep in (d.depends_on or [])
      throw new Error "Undefined dependency '#{dep}' (by '#{n}')" unless steps[dep]?
      indeg[n] += 1
      g[dep].push n
  q = (n for own n,d of indeg when d is 0)
  o = []
  while q.length
    n = q.shift()
    o.push n
    for m in g[n]
      indeg[m] -= 1
      q.push(m) if indeg[m] is 0
  if o.length isnt Object.keys(steps).length
    throw new Error "Topo sort failed (cycle?)"
  o

downstreamMap = (steps) ->
  g = {}
  for own n of steps then g[n]=[]
  for own n, d of steps
    for dep in (d.depends_on or [])
      g[dep].push n
  g

collectDownstream = (g, start) ->
  seen = new Set()
  stack = [start]
  while stack.length
    n = stack.pop()
    continue if seen.has(n)
    seen.add(n)
    for c in (g[n] or []) then stack.push c
  Array.from(seen)

terminalSteps = (steps) ->
  hasDependent = new Set()
  for own n, d of steps
    for dep in (d.depends_on or []) then hasDependent.add(dep)
  (n for own n of steps when not hasDependent.has(n))

# -------------------------------------------------------------------
# Step Runner (SACRED new-style loader preserved)
# -------------------------------------------------------------------
isNewStyleStep = (p) ->
  try /\@step\s*=/.test fs.readFileSync(p,'utf8') catch then false

runStep = (n, def, exp, M, S, active) ->
  new Promise (res, rej) ->
    active.count += 1
    S.markRunning n

    finish = (ok, errMsg=null) ->
      active.count -= 1
      if ok
        wantsRestart = M.theLowdown("restart_here:#{n}")?.value is true
        if wantsRestart
          S.markDone n, restart_here:true
        else
          S.markDone n
        M.saveThis "done:#{n}", true
        res(true)
      else
        S.markFailed n, errMsg ? "failed"
        M.saveThis "done:#{n}", false
        rej new Error(String(errMsg ? "failed"))

    # declarative mlx step: still uses callMLX via memo meta rule
    if def.run_mlx
      try
        entry = def.mlx?.entry ? 'generate'
        M.saveThis "donkeyButt mlx-lm:#{entry}", def.mlx
        finish(true)
      catch e
        finish(false, e.message)
      return

    script = path.join(EXEC,'scripts',def.run)

    # ---- SACRED PATH ----
    if /\.coffee$/i.test(script) and isNewStyleStep(script)
      try delete require.cache[require.resolve(script)] catch then null
      step = require(script)?.step
      unless step?.action?
        finish(false, "Missing @step.action in #{script}")
        return
      Promise.resolve(step.action(M,n))
        .then -> finish(true)
        .catch (e)-> finish(false, e.message)
      return

    # legacy spawn (only for non-newstyle)
    interp = if /\.py$/i.test(script) then 'python' else 'coffee'
    proc = spawn interp, [script],
      env: Object.assign process.env,
        CFG_OVERRIDE: exp
        STEP_NAME: n
        STEP_PARAMS_JSON: JSON.stringify(def)
      stdio: ['ignore','pipe','pipe']

    proc.stdout.on 'data', (buf) -> process.stdout.write prefixLines("┆ #{n} | ", buf.toString())
    proc.stderr.on 'data', (buf) -> process.stderr.write prefixLines("! #{n} | ", buf.toString())
    proc.on 'error', (err) -> finish(false, err.message)
    proc.on 'exit', (c) ->
      if c is 0 then finish(true) else finish(false, "exit #{c}")

# -------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------
main = ->
  ensureSingleInstance()

  overridePath = path.join(CWD,'override.yaml')
  override = loadYamlSafe overridePath
  unless override.pipeline?
    console.error "override.yaml missing pipeline"
    process.exit(1)

  configPath = path.join(EXEC,'config',"#{override.pipeline}.yaml")
  exp = createExperimentYaml configPath, overridePath
  spec = loadYamlSafe exp

  steps  = discoverSteps spec
  order  = toposort steps
  graph  = downstreamMap steps
  finals = terminalSteps steps

  M = new Memo()
  S = new StepStateStore path.join(CWD,'state')
  active = {count: 0}

  # REQUIRED INITIALIZATION (BEFORE ANY STEP RUNS)
  M.saveThis "experiment.yaml", spec
  for n in order
    M.saveThis "params/#{n}.json", steps[n]

  # ---------------- STARTUP: restart_here consumption + state deletion ----------------
  chosen = null
  for n in order
    st = S.read(n)
    if st?.restart_here is true
      chosen = n
      break

  skipRestore = new Set()
  if chosen?
    banner "🔁 restart_here detected at startup: #{chosen}"
    affected = collectDownstream(graph, chosen)   # includes chosen and all downstream
    for a in affected
      skipRestore.add(a)
      if S.delete(a)
        console.log "🧹 deleted obsolete state:", a
    S.clearRestartHere(chosen)  # harmless if file now gone; will just no-op

  # ---------------- STARTUP: restore done/failed from state (only if NOT in skipRestore) ----------------
  for n in order when not skipRestore.has(n)
    st = S.read(n)
    if st?.status is 'done' and st?.done is true and st?.dirty isnt true
      M.saveThis "done:#{n}", true
    else if st?.status is 'failed'
      M.saveThis "done:#{n}", false
    else
      M.theLowdown "done:#{n}"  # leave undefined

  # For affected steps: ensure done key exists but remains undefined (so step WILL run)
  for n in order when skipRestore.has(n)
    M.theLowdown "done:#{n}"    # do NOT set true/false at startup

  # ---------------- EXECUTION (DAG scheduling) ----------------
  for n in order
    do (n) ->
      deps = steps[n].depends_on or []
      start = ->
        return if M.theLowdown("done:#{n}").value is true
        runStep(n, steps[n], exp, M, S, active).catch (e) ->
          console.error "! Step #{n} error:", e.message
      if deps.length is 0
        start()
      else
        M.waitFor (deps.map((d)->"done:#{d}")), start

  # ---------------- Completion tick (no hanging on unresolved Promises) ----------------
  tick = ->
    doneFinals = true
    anyFail = false
    for f in finals
      v = M.theLowdown("done:#{f}").value
      if v isnt true and v isnt false then doneFinals = false
      if v is false then anyFail = true

    if doneFinals and active.count is 0
      if anyFail
        banner "💥 Pipeline finished with failures (final: #{finals.join(', ')})"
        process.exit(1)
      else
        banner "🌟 Pipeline finished (final: #{finals.join(', ')})"
        process.exit(0)

    setTimeout(tick, 200)

  tick()

process.on 'SIGINT', ->
  console.log "\n(CTRL+C) Exiting..."
  process.exit(130)

main()