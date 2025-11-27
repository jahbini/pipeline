#!/usr/bin/env coffee
###
pipeline_evaluator.coffee — strict memo-aware (2025)
----------------------------------------------------
Unified evaluator + judge (flat-map schema)
Now consistent with new @step style, no defaults, and full memo integration.
###

fs        = require 'fs'
path      = require 'path'
yaml      = require 'js-yaml'
{ spawn } = require 'child_process'
CoffeeScript = require 'coffeescript'

banner = (msg) -> console.log "\n=== #{msg} ==="

# ======================================================
# MEMO (modern, minimal)
# ======================================================
class Memo
  constructor: ->
    @MM = {}
    @regexListeners = []

  saveThis: (key, value) ->
    @MM[key] = { value }
    for listener in @regexListeners when listener.regex.test(key)
      listener.callback key, value
    value

  theLowdown: (key) ->
    @MM[key] ?= { value: undefined }
    @MM[key]

  enableFilePersistence: (baseDir = process.cwd()) ->
    writeJSON = (p, obj) ->
      fs.mkdirSync(path.dirname(p), {recursive:true})
      fs.writeFileSync(p, JSON.stringify(obj, null, 2), 'utf8')
    writeCSV = (p, rows) ->
      return unless rows?.length
      keys = Object.keys(rows[0])
      buf = [keys.join(',')]
      for r in rows
        vals = (String(r[k] or '').replace(/,/g,';') for k in keys)
        buf.push vals.join(',')
      fs.mkdirSync(path.dirname(p), {recursive:true})
      fs.writeFileSync(p, buf.join('\n'), 'utf8')

    @regexListeners.push
      regex: /\.json$/i
      callback: (key, value) ->
        dest = path.join(baseDir, key)
        try writeJSON(dest,value); console.log "💾 Memo→JSON:", dest catch e then null

    @regexListeners.push
      regex: /\.csv$/i
      callback: (key, value) ->
        dest = path.join(baseDir, key)
        try writeCSV(dest,value); console.log "💾 Memo→CSV:", dest catch e then null

# ======================================================
# HELPERS
# ======================================================
loadYamlSafe = (p) -> if fs.existsSync(p) then yaml.load(fs.readFileSync(p,'utf8')) or {} else {}

deepMerge = (a,b) ->
  return a unless b?
  for own k,v of b
    if typeof v is 'object' and not Array.isArray(v)
      a[k] = deepMerge(a[k] or {}, v)
    else a[k] = v
  a

buildEnvOverrides = (prefix='CFG_') ->
  out = {}
  for own k,v of process.env when k.startsWith(prefix)
    parts = k.slice(prefix.length).split('__')
    node = out
    for i in [0...parts.length-1]
      node[parts[i]] ?= {}
      node = node[parts[i]]
    try node[parts.at(-1)] = JSON.parse(v) catch e then node[parts.at(-1)] = v
  out

hookConsoleToFds = (logOutFd, logErrFd) ->
  orig = { log: console.log, error: console.error }
  outS = fs.createWriteStream null, {fd: logOutFd}
  errS = fs.createWriteStream null, {fd: logErrFd}
  console.log = (args...) -> outS.write(args.join(' ')+'\n')
  console.error = (args...) -> errS.write(args.join(' ')+'\n')
  -> console.log=orig.log; console.error=orig.error

# ======================================================
# CONFIG + PIPELINE BUILDERS
# ======================================================
createEvaluateYaml = (EXEC) ->
  banner "🔧 Building evaluate.yaml"
  defPath = path.join(EXEC,'config','default.yaml')
  recipe  = path.join(EXEC,'recipes','eval_pipeline.yaml')
  unless fs.existsSync(recipe)
    throw new Error "Missing eval recipe: #{recipe}"
  defaults = loadYamlSafe(defPath)
  spec     = loadYamlSafe(recipe)
  envOv    = buildEnvOverrides()
  merged   = deepMerge(deepMerge(defaults,spec),envOv)
  outPath  = path.join(process.cwd(),'evaluate.yaml')
  fs.writeFileSync(outPath,yaml.dump(merged),'utf8')
  console.log "✅ evaluate.yaml →", outPath
  outPath

normalizeFlatPipeline = (spec) ->
  steps = {}
  for own k,v of spec when k isnt 'run' and typeof v is 'object'
    continue unless v?.run?
    deps = []
    if v.depends_on?
      if v.depends_on is 'never' or (Array.isArray(v.depends_on) and 'never' in v.depends_on)
        console.log "⏭️ skipping #{k}"
        continue
      deps = if Array.isArray(v.depends_on) then v.depends_on else [v.depends_on]
    steps[k] = {run:v.run,depends_on:deps,params:v}
  unless Object.keys(steps).length then throw new Error "No runnable steps"
  steps

buildDag = (steps) ->
  indeg={}; graph={}
  for own n of steps
    indeg[n]=0; graph[n]=[]
  for own n,d of steps
    for dep in d.depends_on or []
      if steps[dep]? then indeg[n]+=1; graph[dep].push n
  q=(k for own k,v of indeg when v is 0)
  order=[]
  while q.length
    n=q.shift(); order.push n
    for m in graph[n]
      indeg[m]-=1
      q.push(m) if indeg[m] is 0
  order

# ======================================================
# STEP RUNNERS
# ======================================================
isNewStyleStep = (scriptPath) ->
  try /\@step\s*=/.test(fs.readFileSync(scriptPath,'utf8')) catch e then false

runCoffeeStep = (stepName, scriptPath, env, logOutFd, logErrFd) ->
  new Promise (resolve,reject) ->
    proc = spawn('coffee',[scriptPath],
      cwd:process.cwd(), env:env, stdio:['ignore',logOutFd,logErrFd])
    proc.on 'exit', (c)-> if c is 0 then resolve() else reject new Error("#{stepName} failed (#{c})")

runCoffeeStepInline = (stepName, scriptPath, M, logOutFd, logErrFd) ->
  new Promise (resolve,reject) ->
    unhook = hookConsoleToFds(logOutFd,logErrFd)
    try
      src=fs.readFileSync(scriptPath,'utf8')
      sandbox={}
      CoffeeScript.run(src,{sandbox})
      step=sandbox.step
      unless step?.action? then throw new Error "Missing @step.action in #{stepName}"
      M.saveThis "status:#{stepName}","running"
      Promise.resolve(step.action(M,stepName)).then ->
        M.saveThis "status:#{stepName}","done"
        unhook(); resolve()
      .catch (e)-> M.saveThis "status:#{stepName}","failed"; unhook(); reject e
    catch e then unhook(); reject e

# ======================================================
# SINGLE RUN EVALUATOR
# ======================================================
evaluateCurrentRun = (EXEC) ->
  banner "Single-run mode"
  fs.mkdirSync 'logs', {recursive:true}
  logOutFd = fs.openSync(path.join('logs','eval.log'),'a')
  logErrFd = fs.openSync(path.join('logs','eval.err'),'a')
  try
    evalYaml = createEvaluateYaml(EXEC)
    spec = loadYamlSafe(evalYaml)
    steps = normalizeFlatPipeline(spec)
    order = buildDag(steps)
    console.log "Topo order:", order.join(' → ')
    M = new Memo()
    M.enableFilePersistence(path.join(process.cwd(),'eval_out'))
    M.saveThis 'evaluation.yaml', spec
    for name in order
      def=steps[name]; script=path.join(EXEC,def.run)
      env=Object.assign({},process.env,{CFG_OVERRIDE:evalYaml,STEP_NAME:name,EXEC})
      if isNewStyleStep(script)
        await runCoffeeStepInline(name,script,M,logOutFd,logErrFd)
      else
        await runCoffeeStep(name,script,env,logOutFd,logErrFd)
      M.saveThis "done:#{name}",true
    banner "🌟 Evaluation finished"
  finally
    try fs.closeSync(logOutFd); fs.closeSync(logErrFd) catch then null

# ======================================================
# COURTROOM
# ======================================================
discoverRuns = (root) ->
  (path.join(root,d) for d in fs.readdirSync(root) when fs.existsSync(path.join(root,d,'experiment.yaml')))

aggregateResults = (root) ->
  csvs=[]
  for d in discoverRuns(root)
    p=path.join(d,'eval_out','ablation_generations_summary.csv')
    continue unless fs.existsSync(p)
    txt=fs.readFileSync(p,'utf8').split(/\r?\n/).filter((x)->x.trim().length)
    continue unless txt.length>1
    headers=txt[0].split(',')
    vals=txt[1].split(',')
    row={}
    for i in [0...headers.length] then row[headers[i]]=vals[i]
    csvs.push Object.assign({run:d,name:path.basename(d)},row)
  csvs

writeJudgement = (root,rows) ->
  outJ=path.join(root,'judgement_summary.json')
  fs.writeFileSync(outJ,JSON.stringify(rows,null,2),'utf8')
  banner "Judgement written → #{outJ}"

# ======================================================
# MAIN
# ======================================================
main = ->
  EXEC=process.env.EXEC
  unless EXEC? and fs.existsSync(path.join(EXEC,'recipes','eval_pipeline.yaml'))
    console.error "❌ EXEC must point to repo root"; process.exit(1)
  target=process.argv[2] or process.cwd()
  process.chdir(target)
  if fs.existsSync('experiment.yaml')
    await evaluateCurrentRun(EXEC)
  else
    banner "Courtroom mode: #{target}"
    for dir in discoverRuns(target)
      banner "Evaluating #{dir}"
      process.chdir(dir)
      await evaluateCurrentRun(EXEC)
      process.chdir(target)
    res=aggregateResults(target)
    writeJudgement(target,res)
  return

main().catch (e)-> console.error "Fatal:",e.message; process.exit(1)