#!/usr/bin/env coffee
###
pipeline_runner.coffee — Flat DAG Runner (CALLMLX PRESERVED)
===========================================================

Hard guarantees:
• callMLX EXISTS and is used via Memo meta rules
• Memo meta-dispatch preserved (read + write)
• experiment.yaml is saved into Memo BEFORE any step runs
• Step params are saved into Memo BEFORE any step runs
• No working subsystem removed

This file intentionally stays close to your known-good runner.
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

  # --------------------------------------------------------------
  # Meta rules — INCLUDING callMLX
  # --------------------------------------------------------------
  initializeMetaRules: (baseDir) ->
    fs = require 'fs'
    path = require 'path'

    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')

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
        dest = path.join(baseDir, key)
        if value is undefined
          return readJSONL(dest)
        fs.mkdirSync(path.dirname(dest),{recursive:true})
        fs.writeFileSync(dest,'','utf8')
        for t in value
          fs.appendFileSync(dest, JSON.stringify(t)+"\n",'utf8')
        value

    # ---- JSON ----
    @addMetaRule "json",
      /\.json$/i,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return readJSON(dest)
        writeText(dest, JSON.stringify(value,null,2))
        value

    # ---- slash-path ----
    @addMetaRule "slash",
      /^(?=.*\/)(?!.*\.[A-Za-z0-9]{1,8}$).+$/,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return readText(dest)
        fs.mkdirSync(path.dirname(dest),{recursive:true})
        data = if Buffer.isBuffer(value) then value else JSON.stringify(value,null,2)
        fs.writeFileSync(dest,data)
        value

  # --------------------------------------------------------------
  # callMLX — PRESERVED
  # --------------------------------------------------------------
  callMLX: (cmdType, payload) ->
    buildArgs = (cmdType, params) ->
      args = ['-m','mlx_lm',cmdType]
      for k,v of params
        args.push "--#{k}"
        args.push v if v?
      args

    args = buildArgs(cmdType, payload)
    proc = spawnSync = require('child_process').spawnSync
    res = proc 'python', args, {encoding:'utf8'}
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

discoverSteps = (spec) ->
  steps={}
  for own k,v of spec when isPlainObject(v) and (v.run? or v.run_mlx)
    steps[k]=Object.assign {},v,depends_on:(v.depends_on ? [])
  steps

toposort = (steps) ->
  indeg={}; g={}
  for own n of steps then indeg[n]=0; g[n]=[]
  for own n,d of steps
    for dep in d.depends_on
      indeg[n]+=1; g[dep].push n
  q=(n for own n,d of indeg when d is 0); o=[]
  while q.length then n=q.shift(); o.push n; for m in g[n] then indeg[m]-=1; q.push(m) if indeg[m] is 0
  o

# -------------------------------------------------------------------
# Step Runner
# -------------------------------------------------------------------
isNewStyleStep=(p)-> try /\@step\s*=/.test fs.readFileSync(p,'utf8') catch then false

runStep=(n,def,exp,M)->
  new Promise (res,rej)->
    unless M.theLowdown("experiment.yaml")?.value?
      return rej new Error "experiment.yaml missing in memo"

    if def.run_mlx
      M.saveThis "donkeyButt mlx-lm:#{def.mlx.entry ? 'generate'}", def.mlx
      M.saveThis "done:#{n}", true
      return res()

    script=path.join(EXEC,'scripts',def.run)
    if /\.coffee$/i.test(script) and isNewStyleStep(script)
      delete require.cache[require.resolve(script)]
      step=require(script)?.step
      Promise.resolve(step.action(M,n))
        .then -> M.saveThis "done:#{n}",true; res()
        .catch (e)-> M.saveThis "done:#{n}",false; rej e
      return

    interp = if /\.py$/i.test(script) then 'python' else 'coffee'
    proc=spawn interp,[script],{env:Object.assign process.env,CFG_OVERRIDE:exp}
    proc.on 'exit',(c)-> if c is 0 then M.saveThis "done:#{n}",true; res() else M.saveThis "done:#{n}",false; rej()

# -------------------------------------------------------------------
# MAIN
# -------------------------------------------------------------------
main= ->
  ensureSingleInstance()

  override = loadYamlSafe path.join(CWD,'override.yaml')
  configPath = path.join(EXEC,'config',"#{override.pipeline}.yaml")
  exp = createExperimentYaml configPath, path.join(CWD,'override.yaml')
  spec = loadYamlSafe exp

  steps = discoverSteps spec
  order = toposort steps

  M = new Memo()

  # REQUIRED INITIALIZATION
  M.saveThis "experiment.yaml", spec
  for n in order
    M.saveThis "params/#{n}.json", steps[n]
    M.theLowdown "done:#{n}"

  for n in order
    do (n)->
      deps=steps[n].depends_on
      start=-> runStep n,steps[n],exp,M
      deps.length is 0 and start() or M.waitFor (deps.map((d)->"done:#{d}")),start

main()