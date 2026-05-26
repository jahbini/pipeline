#!/usr/bin/env coffee
###
              pipeline_runner.coffee  —  a micro-OS for AI experiments
              ===================================================================

  A tiny dependency-aware step runner for shell-friendly experiments. Pipelines
  are declared in YAML; each step declares what it `needs`, what it `makes`,
  and what it `depends_on`; the runner topologically sorts the DAG, wires
  artifacts between steps through a shared key/value store (the `Memo`), and
  records per-step state to disk so an interrupted run can be resumed.

  The runner is intentionally small and intentionally opinionated about a few
  things — those opinions are the **hard guarantees** below. They appear as
  comments above the code that enforces each one; treat them as load-bearing.

  Hard guarantees
  ---------------
  - `callMLX` exists on the `Memo` and is synchronous; it is *not* a
    meta-dispatch key. MLX is currently the only subprocess primitive the
    runner ships with — see `Memo::callMLX` for why it is a method instead of
    a stored value, and the "plugin candidate" note in §2 for why that will
    change when the runner becomes an npm module.
  - **Meta-dispatch** on the Memo is preserved for both read and write paths,
    so a key like `params/foo.yaml` transparently materializes from disk on
    first read via the meta handler registered in `meta/index.coffee`.
  - The fully-resolved `experiment.yaml` is written to the Memo **before** any
    step runs, so step ledgers see a consistent world from tick zero.
  - Step params (`params/<step>.yaml` keys) are written to the Memo **before**
    any step runs, for the same reason.
  - **State protocol**: one file per step at `state/step-<name>.json`. State
    is consulted *only* at startup. While running, the runner records
    `running` / `done` / `failed` to that file. `restart_here: true` is
    consumed at startup and downstream step state is **deleted**, so a stale
    "done" can never inhibit a re-run.
  - `Memo::saveThis` resolves a key's notifier for boolean values **every
    time** it is written — not just on first write. This is the single most
    important correctness fix in the runner; without it, `waitFor` chains
    silently stall on the second pass through a key.

  Roadmap for this file
  ---------------------
   1. Imports, EXEC / CWD split, and small utilities
   2. Python / MLX environment validation     ← the first plugin candidate
   3. Spec processing: deep merge, includes, UI-directive stripping
   4. Single-instance guard
   5. UI event recorder
   6. `StepStateStore` — per-step files, restart_here protocol
   7. `Memo` — meta-dispatch, notifier/resolver, `waitFor`, `callMLX`
   8. Experiment loading and the DAG (toposort, downstream walk)
   9. `StepLedger` — the surface a step actually sees (`need`, `make`,
      `param`, `peek`, `done`, `fail`, `callMLX`)
  10. `runStep` — sacred new-style loader + legacy spawn fallback
  11. `main()` — the orchestration story end-to-end
  12. Signal handlers
###

###
§1 — Module dependencies and roots
==================================================================

Standard library plus `js-yaml`; nothing else gets shipped to npm.
`CoffeeScript.register()` is what lets step files named `*.coffee` be
`require()`-d at runtime by the new-style step loader in `runStep`.
###
fs        = require 'fs'
path      = require 'path'
yaml      = require 'js-yaml'
{ spawn, spawnSync, execSync } = require 'child_process'
CoffeeScript = require 'coffeescript'
CoffeeScript.register()

###
**EXEC vs CWD — read this twice.**

The runner has *two* roots, and the distinction is load-bearing for the
extensibility story:

- `EXEC` is the **runner's home** — where this file lives, where the
  shipped `scripts/`, `config/`, `meta/`, and `requirements.txt` are
  found. When packaged as an npm module, this is the module install
  directory.
- `CWD` is the **project's home** — the directory the user ran the
  pipeline from. Per-project state (`state/`, `params/`,
  `experiment.yaml`, `override/*.yaml`, `.venv/`) lives here.

`EXEC` is overridable via the `EXEC` env var so a project can point at a
checked-out copy of the runner repo without symlinking. Anywhere you see
`path.join(EXEC, …)` we are reaching for *runner-shipped* assets;
anywhere you see `path.join(CWD, …)` we are reaching for *project-owned*
state. Keep that distinction clean — it is the seam along which
`scripts/` overriding and meta-plugin loading will eventually grow.
###
EXEC = process.env.EXEC ? path.dirname(__filename)
CWD  = process.cwd()

# BASE — the consuming project's root. When the runner is installed as an
# npm package, EXEC is `<base>/node_modules/@jahbini/pipeline`, and npm wipes
# `node_modules/` on every install — so a durable venv can NOT live in EXEC
# (nor in CWD, which is a transient pipe working dir). BASE is the directory
# that contains the `node_modules/` EXEC sits under, giving the project one
# stable place to keep `./.venv`. In the old monolith layout (runner lives at
# the project root, no node_modules ancestor) BASE == EXEC.
BASE = do ->
  marker = "#{path.sep}node_modules#{path.sep}"
  idx = EXEC.indexOf(marker)
  if idx isnt -1 then EXEC.slice(0, idx) else EXEC

###
Small utilities used throughout. `banner` is the loud section divider in
console output; `prefixLines` is how step stdout gets the `┆ stepName |`
gutter; `isPlainObject` is the one type check we need that doesn't lie
about `Array` or `null`.
###
banner = (msg) -> console.log "\n=== #{msg} ==="
prefixLines = (pfx, s) -> (s ? '').split(/\r?\n/).map((l)-> pfx + l).join("\n")
isPlainObject = (o) -> Object.prototype.toString.call(o) is '[object Object]'

###
**Script resolution — the `scripts/` overriding seam.**

A step's `run:` is a logical path under `scripts/`. The EXEC/CWD note
above promised this seam: a project may ship its own step script and
have it shadow a runner-bundled one. The candidate locations, in order:

  1. an absolute `run:` — the literal path (no `~` expansion)
  2. `<CWD>/scripts/<run>`  — project-owned (e.g. a step the project
     declared in its own `override/<recipe>.yaml`)
  3. `<EXEC>/scripts/<run>` — runner-bundled

`stepScriptCandidates` lists those locations so a caller can name them
in an error. `resolveStepScript` returns the first that **exists**, or
`null` — it does NOT fabricate a path. No fallback: when nothing
resolves the step fails where the script is needed (in `runStep`), with
a message that names `run:` and every location tried.
###
stepScriptCandidates = (runRef) ->
  ref = String(runRef ? '')
  return [] unless ref.length
  return [ref] if path.isAbsolute(ref)
  [path.join(CWD,'scripts',ref), path.join(EXEC,'scripts',ref)]

resolveStepScript = (runRef) ->
  for candidate in stepScriptCandidates(runRef) when fs.existsSync(candidate)
    return candidate
  null

###
§2 — Python / MLX environment validation
==================================================================

**This entire section is the first plugin candidate.** When the runner
becomes an npm module, MLX support moves out of the core and a project
opts in by declaring a runtime plugin. Until then, the runner resolves a
Python virtualenv from the first of `<CWD>/.venv`, `<BASE>/.venv`, or
`<EXEC>/.venv` that exists (see `resolvePython` and the `BASE` note above),
and expects the shipped `requirements.txt` (at `<EXEC>/requirements.txt`)
to pin exact versions of `mlx`, `mlx-lm`, and `mlx-metal`. The `<BASE>/.venv`
candidate is what lets a project keep one venv at its root with no per-pipe
`.venv` and nothing venv-related inside the npm-wiped `node_modules`.

The validation is loud on purpose: a silent venv drift between projects
caused enough lost afternoons that we now refuse to start the pipeline
unless the installed packages match the pinned versions byte-for-byte.

It is NOT the runner's job to build or repair the venv — that belongs to
the upper-level installer (pipeline-demo / pipeline-pipes create
`<CWD>/.venv` from this `requirements.txt`). The runner only reports the
fault and stops: each error names what is wrong and where it looked, with
no remediation commands.
###

resolvePython = (baseDir = CWD) ->
  # Resolution order: the pipe working dir (baseDir, default CWD), then the
  # project BASE (durable venv home), then EXEC (monolith / fallback). BASE
  # and EXEC coincide in the monolith layout, so dedupe to keep the search —
  # and the error message — clean.
  roots = []
  for root in [baseDir, BASE, EXEC] when root not in roots
    roots.push root

  candidates = []
  for root in roots
    candidates.push path.join(root, '.venv', 'bin', 'python')
    candidates.push path.join(root, '.venv', 'bin', 'python3')

  for candidate in candidates when fs.existsSync(candidate)
    return candidate

  throw new Error [
    "No Python virtualenv found for this pipeline."
    "Looked for (in order): #{candidates.join(', ')}"
  ].join("\n")

loadPinnedRequirements = (requirementsPath, packageNames = []) ->
  unless fs.existsSync(requirementsPath)
    throw new Error "Missing requirements file: #{requirementsPath}"

  wantedNames = (String(name).toLowerCase() for name in packageNames)
  wanted = new Set(wantedNames)
  pins = {}

  for rawLine in fs.readFileSync(requirementsPath, 'utf8').split(/\r?\n/)
    line = rawLine.replace(/\s+#.*$/, '').trim()
    continue unless line.length
    continue if line.startsWith('#')
    continue unless line.includes('==')

    [name, version] = line.split('==', 2)
    continue unless name? and version?
    normalized = String(name).trim().toLowerCase()
    continue unless wanted.has(normalized)
    pins[normalized] = String(version).trim()

  missingPins = (name for name in wantedNames when not pins[name]?)
  if missingPins.length
    throw new Error "requirements.txt is missing exact pins for: #{missingPins.join(', ')}"

  pins

validatePythonEnvironment = (baseDir = CWD) ->
  pythonPath = resolvePython(baseDir)
  requirementsPath = path.join(EXEC, 'requirements.txt')
  pinned = loadPinnedRequirements requirementsPath, ['mlx', 'mlx-lm', 'mlx-metal']
  pyCode = """
import importlib.metadata as md
import json
import platform
import sys

names = ['mlx', 'mlx-lm', 'mlx-metal']
payload = {
  'python': sys.executable,
  'python_version': platform.python_version(),
  'versions': {},
  'missing': [],
}
for name in names:
  try:
    payload['versions'][name] = md.version(name)
  except md.PackageNotFoundError:
    payload['missing'].append(name)
print(json.dumps(payload))
"""

  result = spawnSync pythonPath, ['-c', pyCode], encoding:'utf8'
  if result.error?
    throw result.error
  if result.status isnt 0
    stderr = String(result.stderr ? result.stdout ? '').trim()
    throw new Error "Python environment validation failed: #{stderr or "exit #{result.status}"}"

  details = {}
  try details = JSON.parse(result.stdout) catch err
    throw new Error "Python environment validation returned invalid JSON: #{err.message}"

  if details.missing?.length
    throw new Error [
      "Python virtualenv at #{pythonPath} is missing required MLX packages: #{details.missing.join(', ')}"
      "Pinned by #{requirementsPath}: mlx==#{pinned['mlx']}, mlx-lm==#{pinned['mlx-lm']}, mlx-metal==#{pinned['mlx-metal']}"
    ].join("\n")

  mismatches = []
  for pkg, expected of pinned
    actual = details.versions?[pkg]
    continue if actual is expected
    mismatches.push "#{pkg} expected #{expected} but found #{actual ? 'missing'}"

  if mismatches.length
    throw new Error [
      "Python virtualenv at #{pythonPath} does not match #{requirementsPath}:"
      mismatches.join("\n")
    ].join("\n")

  {
    python: pythonPath
    python_version: details.python_version ? null
    requirements_path: requirementsPath
    packages: details.versions ? {}
  }

###
§3 — Spec processing
==================================================================

How a raw pipeline YAML becomes the fully-resolved `experiment` object
that the runner schedules against. Three primitives:

- `deepMerge` — recursive object merge with one twist: `null` in the
  source means "delete the key from target." That's the override
  syntax projects use to switch off a step they inherited from a base
  recipe.
- `stripUiDirectives` — the `[UI_*, …]` array sentinels are how the
  optional UI layer marks fields as form controls. The runner doesn't
  care about the UI; it just wants the underlying value. This walk
  collapses those sentinels into their plain values before the
  experiment is handed to the scheduler.
- `loadYamlSafe` / `expandIncludes` — recipe `include:` lists pull in
  base recipes (e.g. `base_ite.yaml`). Includes are deep-merged in
  declared order; later wins.
###

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

stripUiDirectives = (node) ->
  return node unless node?
  if Array.isArray(node)
    directive = node[0]
    if directive is 'UI_checkbox'
      return node[1] is true
    if directive is 'UI_dropdown'
      return if node.length >= 3 then node[2] else ''
    if directive is 'UI_textarea'
      return if node.length >= 2 then String(node[1] ? '') else ''
    return node.map (item) -> stripUiDirectives(item)
  if isPlainObject(node)
    out = {}
    for own k, v of node
      out[k] = stripUiDirectives(v)
    return out
  node

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

###
§4 — Single-instance guard
==================================================================

Two pipeline_runners writing to the same `state/` directory will
corrupt each other's per-step files. `ensureSingleInstance` scans `ps`
for sibling processes also running `pipeline_runner.coffee`; if any
are found it returns them and `main()` exits cleanly after recording
the conflict in `state/ui-run.json`. This is observational, not a
lock — racing startups can still both pass the check. The cost of a
real lock wasn't worth it for a teaching tool; the cost of *silent*
double-run was.

`isProcessAlive` is a `kill(pid, 0)` probe used when re-attaching to
an in-flight UI run.
###
ensureSingleInstance = ->
  try
    scriptPath = path.resolve(__filename)
    out = execSync('ps -Ao pid=,command=', encoding:'utf8')
    lines = out.split("\n").map((l)-> l.trim()).filter (l)-> l.length > 0
    others = []

    for line in lines
      match = line.match /^(\d+)\s+(.*)$/
      continue unless match?
      pid = Number(match[1])
      command = String(match[2] ? '')
      continue unless Number.isFinite(pid) and pid > 0
      continue if pid is process.pid
      continue unless command.includes('pipeline_runner.coffee')
      continue unless command.includes(scriptPath) or command.includes(path.basename(scriptPath))
      others.push
        pid: pid
        command: command

    if others.length > 0
      console.error "[pipeline_runner] another pipeline_runner.coffee is already active"
      for other in others
        console.error "[pipeline_runner] active pid=#{other.pid} cmd=#{other.command}"
      return others
  catch err
    console.error "[pipeline_runner] single-instance check failed:", String(err?.message ? err)
    null
  null

isProcessAlive = (pid) ->
  num = Number(pid)
  return false unless Number.isFinite(num) and num > 0
  try
    process.kill num, 0
    true
  catch
    false

###
§5 — UI event recorder
==================================================================

The runner emits a structured event stream the UI consumes; this is
the only place the runner *originates* UI state. Two files in
`state/`:

- `ui-events.jsonl` — append-only event log. Every `need`, `make`,
  `peek`, `param`, and step lifecycle transition becomes a row.
- `ui-run.json` — the current run's metadata (pid, pipeline name,
  status). Overwritten in place.

**Boundary, load-bearing:** the UI is observational. It must never
affect scheduling. `summarizeValue` exists so events carry cheap
shape information (kind/count/bytes) without serializing large
artifact values into the event log.
###
summarizeValue = (value) ->
  kind = if value is null then 'null' else if Array.isArray(value) then 'array' else typeof value
  summary = { kind }
  if Array.isArray(value)
    summary.count = value.length
  else if typeof value is 'string'
    summary.bytes = value.length
  else if isPlainObject(value)
    summary.count = Object.keys(value).length
  summary

createUiRecorder = (memo, stateDir) ->
  relativeDir = path.relative(CWD, stateDir) or 'state'
  eventsKey = path.join(relativeDir, 'ui-events.jsonl')
  runKey = path.join(relativeDir, 'ui-run.json')

  recorder =
    reset: ->
      memo.saveThis eventsKey, []
      memo.saveThis runKey, {}

    event: (payload) ->
      row = Object.assign
        at: new Date().toISOString()
      , payload
      current = memo.theLowdown(eventsKey)?.value
      current = [] unless Array.isArray(current)
      rows = current.slice()
      rows.push row
      memo.saveThis eventsKey, rows
      row

    saveRun: (payload) ->
      row = Object.assign
        updated_at: new Date().toISOString()
      , payload
      memo.saveThis runKey, row
      row

    updateRun: (patch) ->
      current = memo.theLowdown(runKey)?.value
      current = {} unless isPlainObject(current)
      @saveRun Object.assign({}, current, patch)

  recorder

###
§6 — StepStateStore: one file per step, restart_here protocol
==================================================================

State lives at `<CWD>/state/step-<name>.json`, one file per step.
The shape:

    {
      step: "step3_table",
      status: "running" | "done" | "failed" | "shutdown",
      done: true | false,
      restart_here?: true,
      restart_consumed_at?: <ISO>,
      error?: <string>,
      started_at?: <ISO>,
      finished_at?: <ISO>,
      updated_at: <ISO>
    }

**Sacred state protocol — read this once and don't bend it.**

1. State is consulted **only at startup**. While the pipeline is
   running, the in-memory `Memo` is the source of truth for
   `done:<step>`. State files are written-through but never re-read.
2. `restart_here: true` is the user-facing way to say "begin again
   at this step." At startup the runner finds the first step with
   that flag set, deletes the state files for it and every
   downstream step, then clears the flag. This guarantees a stale
   "done" from a previous run cannot inhibit the re-run.
3. Pipeline-wide shutdown is recorded separately in
   `<CWD>/pipeline.json` with `{status: "shutdown", by, reason}`.
   On startup, a non-empty `pipeline.json` means "we crashed last
   time" and the runner exits immediately. Delete it to start fresh.

Step state file deletion is **the** recovery primitive. If you find
yourself adding an `--ignore-state` flag, you are working around
the protocol — fix `restart_here` or the meta handler instead.
###
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

  writePipelineShutdown: (info) ->
    payload =
      status: 'shutdown'
      by: info.by
      reason: info.reason
      timestamp: info.timestamp ? new Date().toISOString()
    fs.writeFileSync(
      path.join('.', 'pipeline.json'),
      JSON.stringify(payload, null, 2),
      'utf8'
    )

  readPipeline: ->
    p = path.join('.', 'pipeline.json')
    return null unless fs.existsSync(p)
    JSON.parse fs.readFileSync(p,'utf8')
###
§7 — Memo: meta-dispatch, notifier/resolver, waitFor, callMLX
==================================================================

The `Memo` is the runner's nervous system. Every artifact, every
parameter, every "is step N done" flag flows through it. Three
concepts make it work:

1. **Entries** carry a `value`, a `notifier` Promise that resolves
   on next write, a `resolver` function that does the resolving,
   and a `meta` handler chosen by key pattern.
2. **Meta-dispatch** lets a key transparently materialize from
   somewhere else (filesystem, sqlite, network). Handlers are
   registered with `addMetaRule(name, regex, handler)`; the first
   regex match wins. The handler is invoked on first read of an
   undefined key, and on every write. If it returns a value on
   write, that value replaces the one passed in (lets the meta
   handler canonicalize).
3. **Notifier/resolver** is how `waitFor` works: a step that
   `need`s an artifact `await`s the entry's notifier; the producing
   step `make`s the value, which calls `saveThis`, which resolves
   the notifier. This is plain JS Promises, no event emitter.

**Critical correctness fix — guard with your life.**

`saveThis` resolves the notifier for boolean values on **every**
write, not just the first one. This is the line marked `# <<<
CRITICAL FIX` below. Without it, a step that writes `done:N = true`
on a re-run after a previous `done:N = false` will not wake up
`waitFor` chains, and the pipeline silently stalls. We learned
this the hard way; do not "simplify" it away.

**callMLX is a method, not a key.**

Subprocess invocation must be synchronous and immediate from the
caller's perspective. Putting it through `saveThis` would mean the
caller has to `await` a notifier just to get back stdout, and the
result would live in the Memo forever. So it sits on the class as
a plain method. When the runner becomes an npm module this method
moves to the MLX plugin and the core `Memo` loses it.
###
class Memo
  constructor: ->
    @MM = {}
    @metaRules = []

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
      try
        rv = entry.meta(key, value)
      catch err
        throw new Error "[Memo.saveThis] meta write failed for #{key}: #{err?.message ? err}"
      entry.value = rv if rv?
      @_resolve(entry, value) if value is true or value is false
      return entry

    old = entry.resolver
    entry = @MM[key] = @_newEntry(key, value)
    try old?(value) catch then null
    try
      rv = entry.meta(key, value)
    catch err
      throw new Error "[Memo.saveThis] meta write failed for #{key}: #{err?.message ? err}"
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
      return if keys.some((k)=> @theLowdown(k).value is false)
      try andDo() catch then null

  addMetaRule: (name, regex, handler) ->
    @metaRules.push {name, regex, handler}

  selectMetaHandler: (key) ->
    for r in @metaRules when r.regex.test(key)
      return r.handler
    (k,v)-> return

  # ------------------------------------------------------------
  # Parameter resolution (authoritative)
  # ------------------------------------------------------------
  getStepParam: (stepName, key, defaultValue = undefined) ->
    stepParams =
      @theLowdown("params/#{stepName}.yaml").value ? {}

    globalParams =
      @theLowdown("params/_global.yaml").value ? {}

    if stepParams.hasOwnProperty key
      return stepParams[key]

    if globalParams.hasOwnProperty key
      return globalParams[key]

    return defaultValue

  callMLX: (cmdType, payload, dbug = false) ->
    buildArgs = (cmdType, params) ->
      args = ['-m','mlx_lm',cmdType]
      for k,v of params
        args.push "--#{k}" if k
        args.push v if v?
      args

    args = buildArgs(cmdType, payload)
    console.error "MLX args",args if dbug
    spawnSync = require('child_process').spawnSync
    res = spawnSync resolvePython(CWD), args, {encoding:'utf8'}
    console.error "MLX result" ,res if dbug
    
    if res.error?
      throw res.error
    if res.status isnt 0
      throw new Error "MLX failed: #{res.stderr ? res.stdout ? "exit #{res.status}"}"
    res.stdout

###
§8 — Experiment loading and the DAG
==================================================================

How a pipeline name (`"test"`, `"diary_ite"`, …) becomes a sorted
list of executable steps:

1. `resolveOverrideLayers` returns the override files that exist for
   this pipeline, low→high precedence: legacy `<CWD>/override.yaml`
   then recipe-scoped `<CWD>/override/<name>.yaml`. Nothing is copied
   or migrated.
2. `createExperimentObject` loads `<EXEC>/config/<name>.yaml`, expands
   its `include:` list, then deep-merges those override layers and
   finally `<CWD>/control_override.yaml`. Strips UI directives. The
   result is the canonical `experiment` written to `experiment.yaml`
   and into the Memo.
3. `discoverSteps` walks the experiment dict, picks out anything
   that looks like a step (has `run:` or `run_mlx`), and skips any
   step with `depends_on: never` — the runtime "off switch" for an
   inherited step.
4. `toposort` returns the Kahn-ordered step list. `downstreamMap`
   and `collectDownstream` are the inverse — used by
   `restart_here` to figure out which downstream state files to
   delete. `terminalSteps` are the sinks; the runner exits when
   all of them have a definite `true` or `false` `done:` value.

Artifact-key normalization (`needs`/`makes`) and dep normalization
are deliberately strict: a typo in `needs:` will fail loudly at
startup rather than silently produce an empty wait.
###
createExperimentObject = (configPath, overridePaths, controlOverridePath = null) ->
  recipe = expandIncludes loadYamlSafe(configPath), path.dirname(configPath)
  merged = deepMerge {}, recipe
  layers = if Array.isArray(overridePaths) then overridePaths else [overridePaths]
  for overridePath in layers when overridePath
    merged = deepMerge merged, loadYamlSafe(overridePath)
  if controlOverridePath? and fs.existsSync(controlOverridePath)
    merged = deepMerge merged, loadYamlSafe(controlOverridePath)
  return stripUiDirectives(merged)

###
**Override layers — non-destructive, documented precedence.**

`pipeline_architecture.md` describes legacy `override.yaml` and the
recipe-scoped `override/<recipe>.yaml` as two *distinct* merge layers —
legacy lower, recipe-scoped higher. We honor that by returning every
override file that exists, in ascending precedence, and letting
`createExperimentObject` deep-merge them in order.

This replaces the old "migrate legacy → recipe-scoped on first run, then
only ever read the copy" behavior, which silently froze a project's
`override.yaml`: once the copy existed, later edits to `override.yaml`
never reached `experiment.yaml`. The runner no longer writes or copies
anything here — the UI still owns `override/<recipe>.yaml` as its own
edit surface (`ui_server.coffee` `readOverride`).
###
resolveOverrideLayers = (pipelineName) ->
  layers = []
  legacyPath = path.join CWD, 'override.yaml'
  layers.push legacyPath if fs.existsSync legacyPath
  name = String(pipelineName ? '').trim()
  if name.length
    recipeOverridePath = path.join CWD, 'override', "#{name}.yaml"
    layers.push recipeOverridePath if fs.existsSync recipeOverridePath
  layers

normalizeDeps = (d) ->
  return [] unless d?
  return d.slice() if Array.isArray(d)
  return [d] if typeof d is 'string'
  []

normalizeArtifactKeys = (d) ->
  return [] unless d?
  return d.slice() if Array.isArray(d)
  return [d] if typeof d is 'string'
  throw new Error "needs/makes must be string or array"

discoverSteps = (spec) ->
  steps = {}
  for own k, v of spec
    continue unless isPlainObject(v)
    continue unless v.run? or v.run_mlx
    def = Object.assign {}, v
    deps = normalizeDeps(v.depends_on)
    if deps.length is 1 and String(deps[0]).toLowerCase() is 'never'
      console.log "⏭️  skipping step #{k} (depends_on: never)"
      continue
    def.depends_on = deps
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

###
§9 — StepLedger: the surface a step actually sees
==================================================================

A step script does not see the `Memo` directly. It receives a
`StepLedger` — a per-step facade with exactly the operations a
step is allowed to do:

    L.param(key, default?)        — read a param (step → global → default)
    L.need(artifactKey)           — read a declared input; awaits if absent
    L.peek(artifactKey, default?) — read maybe-present input, never blocks
    L.make(artifactKey, value)    — write a declared output
    L.done()                      — mark step success (idempotent)
    L.fail(err)                   — mark step failure (re-throws)
    L.callMLX(cmd, payload, dbg?) — synchronous MLX subprocess

**The contract is enforced.** `need`/`peek`/`make` all throw if
the artifact isn't declared in this step's `needs` or `makes`.
A step cannot reach across the wiring; the YAML is the only place
data flow is described.

Every ledger operation also emits a UI event (request → resolved /
waiting / default / missing / written), which is how the optional UI
visualizes step internals without any cooperation from the script.

`createStepLedger` also collapses MLX param aliases — legacy step
YAMLs used `temperature` / `max_tokens` / etc. and the ledger maps
them to the canonical `--temp` / `--max-tokens` CLI flags expected by
`mlx_lm`. New step YAMLs should use a nested `mlx:` block instead.

------------------------------------------------------------------

§10 — runStep: sacred new-style loader + legacy spawn
==================================================================

Two execution paths, in priority order:

1. **New-style (sacred)** — if the step's `run:` points at a
   `.coffee` file containing `@step =` (or `module.exports.step =`),
   the runner clears the `require` cache, imports it, and calls
   `step.action(L, n, M)` directly in this process. The script gets
   the ledger, can `await L.need(...)`, and returns a Promise. **Do
   not refactor this path through `spawn`** — the in-process model
   is what makes the `Memo` notifier/resolver wakeups synchronous
   across steps.
2. **Legacy spawn** — anything else gets `spawn`ed as a subprocess
   with `STEP_NAME`, `STEP_PARAMS_JSON`, and `CFG_OVERRIDE` in the
   env. stdout/stderr are prefixed with `┆ stepName |` and routed
   to the runner's own streams. The legacy path exists so a project
   can keep one-off Python or shell steps; new work should be
   new-style.

`primeStepMakes` is the small bridge between artifact declarations
and the Memo: before a step runs, any artifact it `makes` that has a
configured `target:` key is seeded from that target if it already
has a value (so a step re-run sees its prior output as its starting
state).
###
isNewStyleStep = (p) ->
  try /\@step\s*=/.test fs.readFileSync(p,'utf8') catch then false

createStepLedger = (memo, stepName, resolveArtifact, artifactSpecFor, uiRecorder = null) ->
  getDecls = ->
    stepP = memo.theLowdown("params/#{stepName}.yaml")?.value ? {}
    needs = normalizeArtifactKeys(stepP.needs ? [])
    makes = normalizeArtifactKeys(stepP.makes ? [])
    { needs, makes }

  debugEnabled = ->
    memo.getStepParam(stepName, 'debug_s') is true

  describeArtifact = (artifactKey) ->
    spec = artifactSpecFor artifactKey
    return artifactKey unless spec?
    if isPlainObject(spec)
      source = spec.source ? spec.key
      target = spec.target
      return "#{artifactKey} source=#{source}" if source?
      return "#{artifactKey} target=#{target}" if target?
      return artifactKey
    "#{artifactKey} source=#{spec}"

  debug = (parts...) ->
    return unless debugEnabled()
    console.log "[#{new Date().toISOString()}] [S #{stepName}]", parts...

  ui = (payload) ->
    try uiRecorder?.event Object.assign({ step: stepName }, payload) catch then null

  getStepParams = ->
    memo.theLowdown("params/#{stepName}.yaml")?.value ? {}

  legacyMlxAliases =
    generate:
      temperature: 'temp'
      max_tokens: 'max-tokens'
      min_tokens: 'min-tokens'
      top_p: 'top-p'
      top_k: 'top-k'
      max_kv_size: 'max-kv-size'
      repeat_penalty: 'repeat-penalty'
    lora:
      batch_size: 'batch-size'
      iters: 'iters'
      max_seq_length: 'max-seq-length'
      learning_rate: 'learning-rate'
    convert:
      q_bits: 'q-bits'
      q_group: 'q-group-size'
      dtype: 'dtype'
    fuse:
      dtype: 'dtype'

  getLegacyMlxConfig = (cmdType) ->
    aliases = legacyMlxAliases[cmdType] ? {}
    legacy = {}
    for own paramKey, cliKey of aliases
      value = memo.getStepParam stepName, paramKey
      legacy[cliKey] = value if value isnt undefined
    legacy

  getMlxConfig = (cmdType) ->
    stepParams = getStepParams()
    mlxCfg = stepParams.mlx
    merged = getLegacyMlxConfig(cmdType)
    return merged unless isPlainObject(mlxCfg)
    # Simple shape only:
    #   mlx:
    #     temp: 0.7
    #     max-tokens: 2000
    Object.assign merged, mlxCfg

  mergeMlxPayload = (cmdType, payload) ->
    merged = getMlxConfig(cmdType)
    for own k, v of (payload ? {})
      merged[k] = v
    merged

  ledger =
    stepName: stepName

    param: (key, defaultValue) ->
      debug "param request", key
      ui type:'param', phase:'request', key:key
      value = memo.getStepParam stepName, key
      if value is undefined and arguments.length >= 2
        debug "param default", key, defaultValue
        ui type:'param', phase:'default', key:key, value_summary:summarizeValue(defaultValue)
        return defaultValue
      if value is undefined
        debug "param missing", key
        ui type:'param', phase:'missing', key:key
        console.error "[#{stepName}] Missing required param '#{key}'"
        throw new Error "[#{stepName}] Missing required param '#{key}'"
      debug "param resolved", key, "(#{typeof value})", value
      ui type:'param', phase:'resolved', key:key, value_summary:summarizeValue(value)
      value

    getStepParam: (nameOrKey, key, defaultValue = undefined) ->
      if arguments.length >= 2
        return memo.getStepParam(nameOrKey, key, defaultValue)
      @param(nameOrKey, defaultValue)

    need: (artifactKey) ->
      { needs, makes } = getDecls()
      debug "need request", describeArtifact(artifactKey), "declared needs=", needs.join(','), "makes=", makes.join(',')
      ui type:'need', phase:'request', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey)
      declared = needs.includes(artifactKey) or makes.includes(artifactKey)
      throw new Error "[#{stepName}] Artifact '#{artifactKey}' must be declared in needs or makes" unless declared

      entry = memo.theLowdown artifactKey
      value = entry?.value
      if value is undefined and needs.includes(artifactKey)
        debug "need waiting", describeArtifact(artifactKey)
        ui type:'need', phase:'waiting', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey)
        value = await entry.notifier
        debug "need awakened", describeArtifact(artifactKey), "(#{typeof value})"

      if value is undefined
        debug "need missing", describeArtifact(artifactKey)
        ui type:'need', phase:'missing', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey)
        console.error "[#{stepName}] Missing required artifact '#{artifactKey}'"
        throw new Error "[#{stepName}] Missing required artifact '#{artifactKey}'"
      debug "need resolved", describeArtifact(artifactKey), "(#{typeof value})"
      ui type:'need', phase:'resolved', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey), value_summary:summarizeValue(value)
      value

    peek: (artifactKey, defaultValue = undefined) ->
      { needs, makes } = getDecls()
      debug "peek request", describeArtifact(artifactKey), "declared needs=", needs.join(','), "makes=", makes.join(',')
      ui type:'peek', phase:'request', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey)
      declared = needs.includes(artifactKey) or makes.includes(artifactKey)
      throw new Error "[#{stepName}] Artifact '#{artifactKey}' must be declared in needs or makes" unless declared

      entry = memo.theLowdown artifactKey
      value = entry?.value
      if value is undefined
        spec = artifactSpecFor artifactKey
        source = if isPlainObject(spec) then spec.source ? spec.key else spec
        target = if isPlainObject(spec) then spec.target else null

        if typeof source is 'string'
          debug "peek checking source key", source
          srcEntry = memo.theLowdown source
          value = srcEntry?.value
          if value isnt undefined
            memo.saveThis artifactKey, value
            debug "peek resolved from source key", describeArtifact(artifactKey), "(#{typeof value})"

        if value is undefined and typeof target is 'string'
          debug "peek checking target key", target
          targetEntry = memo.theLowdown target
          value = targetEntry?.value
          if value isnt undefined
            memo.saveThis artifactKey, value
            debug "peek resolved from target key", describeArtifact(artifactKey), "(#{typeof value})"

      if value is undefined
        debug "peek default", describeArtifact(artifactKey), defaultValue
        ui type:'peek', phase:'default', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey), value_summary:summarizeValue(defaultValue)
        return defaultValue
      debug "peek resolved", describeArtifact(artifactKey), "(#{typeof value})"
      ui type:'peek', phase:'resolved', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey), value_summary:summarizeValue(value)
      value

    make: (artifactKey, value) ->
      { makes } = getDecls()
      debug "make request", describeArtifact(artifactKey), "declared makes=", makes.join(',')
      ui type:'make', phase:'request', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey), value_summary:summarizeValue(value)
      throw new Error "[#{stepName}] Artifact '#{artifactKey}' must be declared in makes" unless makes.includes artifactKey
      memo.saveThis artifactKey, value
      debug "make wrote", describeArtifact(artifactKey), "(#{typeof value})"
      ui type:'make', phase:'written', artifact:artifactKey, artifact_detail:describeArtifact(artifactKey), value_summary:summarizeValue(value)
      value

    done: ->
      debug "done"
      ui type:'step', phase:'done'
      memo.saveThis "done:#{stepName}", true
      true

    fail: (err) ->
      debug "fail", String(err?.message ? err)
      ui type:'step', phase:'failed', error:String(err?.message ? err)
      memo.saveThis "done:#{stepName}", false
      throw err

    saveThis: (key, value) -> memo.saveThis key, value
    theLowdown: (key) -> memo.theLowdown key
    waitFor: (keys, andDo) -> memo.waitFor keys, andDo
    addMetaRule: (name, regex, handler) -> memo.addMetaRule name, regex, handler
    callMLX: (cmdType, payload, dbug) ->
      mlxDebug = if arguments.length >= 3 then dbug else @param('debug_mlx', false)
      finalPayload = mergeMlxPayload cmdType, payload
      debug "mlx request", cmdType, finalPayload
      memo.callMLX cmdType, finalPayload, mlxDebug

  ledger

runStep = (n, def, exp, M, S, active, resolveArtifact, artifactSpecFor, uiRecorder = null) ->
  new Promise (res, rej) ->
    active.count += 1
    active.names ?= new Set()
    active.names.add n
    S.markRunning n
    try uiRecorder?.event type:'step', phase:'running', step:n catch then null

    finish = (ok, errMsg=null) ->
      active.count -= 1
      active.names?.delete n
      if ok
        wantsRestart = M.theLowdown("restart_here:#{n}")?.value is true
        if wantsRestart
          S.markDone n, restart_here:true
        else
          S.markDone n
        M.saveThis "done:#{n}", true
        try uiRecorder?.event type:'step', phase:'finished', step:n, status:'done' catch then null
        res(true)
      else
        shutdownInfo =
          status: 'shutdown'
          by: n
          reason: errMsg ? "failed"
          failed: true
          timestamp: new Date().toISOString()
        S.markFailed n, errMsg ? "failed"
        S.writePipelineShutdown shutdownInfo
        M.saveThis "pipeline:shutdown", shutdownInfo
        M.saveThis "done:#{n}", false
        try uiRecorder?.event type:'step', phase:'finished', step:n, status:'failed', error:String(errMsg ? "failed") catch then null
        rej new Error(String(errMsg ? "failed"))

    # **Script needed here — fail directly if it is missing.** No fallback
    # to a guessed path and no silent drop into the legacy spawn: when
    # `resolveStepScript` finds nothing, this is the point of use, so we
    # error with the `run:` value and every location tried. The human reads
    # the same `run:`/resolved location in `params/#{n}.yaml`.
    script = resolveStepScript(def.run)
    unless script?
      tried = stepScriptCandidates(def.run).join(', ') or '(none)'
      finish(false, "step #{n}: script not found for run '#{def.run}' (looked: #{tried})")
      return

    primeStepMakes = ->
      for artifactKey in (def.makes ? [])
        entry = M.theLowdown artifactKey
        continue if entry?.value isnt undefined

        spec = artifactSpecFor artifactKey
        continue unless isPlainObject(spec)
        target = spec.target
        continue unless typeof target is 'string'

        targetEntry = M.theLowdown target
        targetVal = targetEntry?.value
        continue if targetVal is undefined

        M.saveThis artifactKey, targetVal

    primeStepMakes()

    # ---- SACRED PATH ----
    if /\.coffee$/i.test(script) and isNewStyleStep(script)
      try delete require.cache[require.resolve(script)] catch then null
      step = require(script)?.step
      unless step?.action?
        finish(false, "Missing @step.action in #{script}")
        return
      try
        L = createStepLedger(M, n, resolveArtifact, artifactSpecFor, uiRecorder)
        pp=Promise.resolve(step.action(L,n,M))
        pp.then -> finish(true)
        pp.catch (e)-> finish(false, e.message)
      catch e 
        finish(false,e)
        throw e        
      return

    # legacy spawn (only for non-newstyle)
    interp = if /\.py$/i.test(script) then resolvePython(CWD) else 'coffee'
    proc = spawn interp, [script],
      env: Object.assign process.env,
        PYTHON: resolvePython(CWD)
        CFG_OVERRIDE: exp
        STEP_NAME: n
        STEP_PARAMS_JSON: JSON.stringify(def)
      stdio: ['ignore','pipe','pipe']

    proc.stdout.on 'data', (buf) -> process.stdout.write prefixLines("┆ #{n} | ", buf.toString())
    proc.stderr.on 'data', (buf) -> process.stderr.write prefixLines("! #{n} | ", buf.toString())
    proc.on 'error', (err) -> finish(false, err.message)
    proc.on 'exit', (c) ->
      if c is 0 then finish(true) else finish(false, "exit #{c}")

###
`installGetStepParam` overrides the `Memo`'s own `getStepParam`
method on the instance with a slightly looser variant (uses
truthy-check on the resolved value rather than `hasOwnProperty`).
**Known seam:** this duplicates the class-level `getStepParam`
defined inside `Memo`. They will diverge eventually — pick one
canonical implementation when the runner is extracted to npm. For
now the instance-level override is what `StepLedger.param` sees
through the ledger's bound `memo` reference.
###
installGetStepParam = (M) ->
  M.getStepParam = (stepName, key) ->
    stepP = M.theLowdown("params/#{stepName}.yaml")?.value
    return stepP[key] if stepP? and stepP[key]?

    globalP = M.theLowdown("params/_global.yaml")?.value
    return globalP[key] if globalP? and globalP[key]?

    undefined

###
UI integration design for artifact I/O
==================================================================

(This block is forward-looking design notes for the optional UI
layer. It documents the recommended Memo key shape and event stream
the UI should consume. The runner already emits these events via
the `createStepLedger` `ui(…)` calls in §9; the block below is the
spec the consumer should code against.)


`StepLedger.need(artifactKey)`, `StepLedger.peek(artifactKey, defaultValue)`,
and `StepLedger.make(artifactKey, value)` are the correct hook points for
UI-facing pipeline state because they sit exactly on the explicit
`needs` / `makes` contract between a step and its declared resources.

If a UI layer is added, emit structured state updates here rather than
inside individual step scripts. That keeps the UI deterministic and lets
the runner remain the single source of truth for resource flow.

Critical boundary:
- After meta devices are initialized, artifact persistence and artifact
  recovery must flow through Memo only.
- Do not add direct filesystem reads/writes for artifact sources or
  artifact targets inside the runner.
- If an artifact path needs support, add or extend the appropriate meta
  device instead of bypassing Memo.

Recommended UI memo keys:

  ui/steps/<stepName>/needs/<artifactKey>
    direction: "need"
    step: <stepName>
    artifact: <artifactKey>
    declared_in: "needs" | "makes"
    status: "waiting" | "resolved" | "defaulted" | "missing"
    used_default: true | false
    observed_at: <ISO timestamp>
    resolved_at: <ISO timestamp or null>
    value_summary:
      kind: "array" | "object" | "string" | "number" | "boolean" | "null" | "undefined"
      count: <array/object size if cheap>
      bytes: <string length if cheap>

  ui/steps/<stepName>/makes/<artifactKey>
    direction: "make"
    step: <stepName>
    artifact: <artifactKey>
    status: "written"
    observed_at: <ISO timestamp>
    value_summary: <same shape as above>

  ui/steps/<stepName>/peeks/<artifactKey>
    direction: "peek"
    step: <stepName>
    artifact: <artifactKey>
    status: "resolved" | "defaulted" | "missing"
    observed_at: <ISO timestamp>

Recommended append-only event stream:

  ui/events/<monotonic id>
    type: "artifact_need" | "artifact_make"
    step: <stepName>
    artifact: <artifactKey>
    phase: "start" | "resolved" | "defaulted" | "written" | "error"
    at: <ISO timestamp>

Implementation notes:
- Emit "start" before awaiting a missing `need`.
- Emit "resolved" once the artifact value is available.
- Emit a required-param error when `param(key)` has no configured value and no explicit default.
- Emit "written" immediately before or after `saveThis` in `make`.
- Keep summaries cheap and deterministic; do not deep-inspect large values.
- Never require step scripts to know about UI keys.
- Keep UI state observational only; it must not affect scheduling.
###

###
§11 — main(): the orchestration story end-to-end
==================================================================

The full life of a run, in the order things happen:

  a. **Single-instance check.** If another `pipeline_runner.coffee`
     is alive, record the conflict in `state/ui-run.json` and exit
     cleanly. (§4)

  b. **Python/MLX validation.** Refuse to start unless the project
     `.venv` matches the pinned `requirements.txt`. (§2)

  c. **Memo construction + meta loader.** `require(EXEC/meta)` is
     `meta/index.coffee`; it registers all the meta rules
     (`params/*.yaml`, sqlite, txt, csv, …) against this Memo.
     Order matters — first regex match wins.

  d. **Env keys.** A handful of `env/*` keys (`EXEC`, `CWD`,
     `PYTHON`, `HH_MM`, `LOGDIR`, …) are saved into the Memo so
     steps can read them without touching `process.env` directly.

  e. **Override resolution + experiment build.** Read
     `control_override.yaml` (or legacy `override.yaml`) to find
     the pipeline name, then build the merged experiment object
     and persist it to both `experiment.yaml` and the Memo.

  f. **Step discovery + invariant enforcement.** Every step must
     declare `needs:` and `makes:` explicitly — undeclared
     artifacts produce a startup error, never a silent miss. A
     duplicate `makes:` (two steps producing the same artifact)
     also errors at startup.

  g. **Pipeline shutdown check.** A non-empty `pipeline.json`
     means we crashed; exit immediately so the user can inspect
     before re-running.

  h. **`restart_here` consumption.** At most one step is allowed
     to carry `restart_here: true`. The runner finds it, computes
     the downstream set via `collectDownstream`, deletes those
     state files, and clears the flag. (§6)

  i. **Startup state restore.** For every step *not* in the
     restart set, read its state file and seed `done:<step>` in
     the Memo accordingly. Restart-set steps get an undefined
     `done:` so they will actually run.

  j. **DAG scheduling.** For each step, register a `waitFor` on
     its dependencies' `done:` keys; when they all flip true,
     wire inputs (`resolveArtifact`), run the step, then
     materialize outputs.

  k. **Completion tick.** Every 2s, check whether all terminal
     steps have a definite done state. If yes, exit with the
     right code and update `ui-run.json`. If a shutdown was
     written mid-flight, honor it immediately.
###
main = ->
  otherRunners = ensureSingleInstance()
  if otherRunners?.length
    stateDir = path.join(CWD, 'state')
    fs.mkdirSync(stateDir, {recursive:true})
    uiRunPath = path.join(stateDir, 'ui-run.json')
    current = {}
    if fs.existsSync(uiRunPath)
      try current = JSON.parse(fs.readFileSync(uiRunPath, 'utf8')) catch then current = {}
    if isProcessAlive(current?.pid)
      current.status = 'running'
      current.reason = 'attached to existing pipeline_runner.coffee'
    else
      current.status = 'skipped'
      current.finished_at = new Date().toISOString()
      current.reason = 'another pipeline_runner.coffee is already active'
    current.other_runners = otherRunners
    fs.writeFileSync uiRunPath, JSON.stringify(current, null, 2), 'utf8'
    process.exit(0)

  pythonEnv = validatePythonEnvironment(CWD)

  M = new Memo()
  metaLoader = require path.join(EXEC, 'meta')
  metaLoader(M, { baseDir: CWD })
  S = new StepStateStore path.join(CWD,'state')
  U = createUiRecorder M, path.join(CWD,'state')
  U.reset()

  M.saveThis "env/EXEC", EXEC
  M.saveThis "env/CWD",  CWD
  M.saveThis "env/PYTHON", pythonEnv.python
  M.saveThis "env/PYTHON_VERSION", pythonEnv.python_version if pythonEnv.python_version?
  M.saveThis "env/REQUIREMENTS_TXT", pythonEnv.requirements_path
  M.saveThis "env/MLX_PACKAGES", pythonEnv.packages
  M.saveThis "env/HH_MM", process.env.HH_MM if process.env.HH_MM?
  M.saveThis "env/LOGDIR", process.env.LOGDIR if process.env.LOGDIR?

  controlOverridePath = path.join(CWD,'control_override.yaml')
  controlOverride = loadYamlSafe controlOverridePath
  legacyOverride = loadYamlSafe path.join(CWD, 'override.yaml')
  pipelineName = controlOverride.pipeline ? legacyOverride.pipeline
  unless pipelineName?
    console.error "control_override.yaml or legacy override.yaml missing pipeline"
    process.exit(1)

  overrideLayers = resolveOverrideLayers pipelineName
  configPath = path.join(EXEC,'config',"#{pipelineName}.yaml")
  experiment = createExperimentObject configPath, overrideLayers, controlOverridePath
  U.saveRun
    pipeline: pipelineName
    pid: process.pid
    cwd: CWD
    exec: EXEC
    hh_mm: process.env.HH_MM ? null
    logdir: process.env.LOGDIR ? null
    started_at: new Date().toISOString()
    status: 'running'
  if experiment.run?.model and experiment.run?.loraLand
    modelDirName = experiment.run.model.replace /\//g, '--'
    targetDir    = path.resolve experiment.run.loraLand, modelDirName
    M.saveThis 'modelDir', targetDir
  fs.writeFileSync path.join(CWD, 'experiment.yaml'), yaml.dump(experiment, lineWidth: 120, noRefs: true), 'utf8'
  M.saveThis 'experiment.yaml',experiment

  steps  = discoverSteps experiment
  artifacts = experiment.artifacts ? {}
  throw new Error "experiment.artifacts must be an object" unless isPlainObject(artifacts)
  order  = toposort steps
  graph  = downstreamMap steps
  finals = terminalSteps steps


  # ---------------- GLOBAL PARAMS (AUTHORITATIVE) ----------------
  globalParams = experiment.run ? {}
  fs.mkdirSync(path.join(CWD,'params'), {recursive:true})
  M.saveThis "params/_global.yaml", globalParams

  installGetStepParam M

  pipeState = S.readPipeline()
  if pipeState?.status is 'shutdown'
    banner "🛑 PIPELINE PREVIOUSLY SHUT DOWN"
    console.log "  by:", pipeState.by
    console.log "  reason:", pipeState.reason
    process.exit(0)

  active = {count: 0, names: new Set()}

  # ---------------- STEP PARAMS ----------------
  producedBy = {}
  for n in order
    unless Object.prototype.hasOwnProperty.call(steps[n], 'needs')
      throw new Error "Step '#{n}' must declare needs: []"
    unless Object.prototype.hasOwnProperty.call(steps[n], 'makes')
      throw new Error "Step '#{n}' must declare makes: []"
    steps[n].needs = normalizeArtifactKeys(steps[n].needs).sort()
    steps[n].makes = normalizeArtifactKeys(steps[n].makes).sort()
    for k in steps[n].makes
      throw new Error "Artifact '#{k}' is produced by multiple steps: #{producedBy[k]} and #{n}" if producedBy[k]?
      producedBy[k] = n
    # Surface the executable script location alongside the step's declared
    # `run:` so a human comparing `state/` against `params/` can see exactly
    # which file the runner resolved (`null` = not found, so the step will
    # fail when it runs). This records; it does NOT pre-validate — a step
    # restored as `done` is still skipped, and the bad location here is the
    # clue to clear its state file or fix the override.
    steps[n].run_resolved = resolveStepScript(steps[n].run) if steps[n].run?
    M.saveThis "params/#{n}.yaml", steps[n]

  # ---------------- ARTIFACT WIRING ----------------
  resolveArtifact = (artifactKey) ->
    spec = artifacts[artifactKey]
    throw new Error "Artifact '#{artifactKey}' not declared in experiment.artifacts" unless spec?
    if isPlainObject(spec) and spec.hasOwnProperty('value')
      return spec.value
    source = if isPlainObject(spec) then spec.source ? spec.key else spec
    target = if isPlainObject(spec) then spec.target else null
    unless source?
      if producedBy[artifactKey]?
        producerStep = producedBy[artifactKey]
        producerDone = M.theLowdown("done:#{producerStep}")?.value is true
        outEntry = M.theLowdown(artifactKey)
        outVal = outEntry.value
        return outVal if outVal isnt undefined
        if producerDone and typeof target is 'string'
          targetEntry = M.theLowdown(target)
          targetVal = targetEntry.value
          return targetVal if targetVal isnt undefined
        outVal = await outEntry.notifier if outVal is undefined
        return outVal
      throw new Error "Artifact '#{artifactKey}' missing source/value declaration"
    srcEntry = M.theLowdown(source)
    val = srcEntry.value
    val = await srcEntry.notifier if val is undefined
    val

  materializeArtifact = (artifactKey, value) ->
    spec = artifacts[artifactKey]
    return unless spec?
    target = if isPlainObject(spec) then spec.target else null
    if target?
      M.saveThis(target, value)
    M.saveThis(artifactKey, value)

  wireInputsForStep = (stepName) ->
    for k in (steps[stepName].needs ? [])
      v = await resolveArtifact(k)
      M.saveThis k, v

  collectOutputsForStep = (stepName) ->
    for k in (steps[stepName].makes ? [])
      e = M.theLowdown(k)
      throw new Error "Step #{stepName} missing required output #{k}" if e.value is undefined
      await materializeArtifact(k, e.value)

  # ---- remainder of main() UNCHANGED ----
  # (startup restore, scheduling, tick loop, etc.)
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

  scheduled = new Set()
  # ---------------- EXECUTION (DAG scheduling) ----------------
  for n in order
    do (n) ->
      deps = steps[n].depends_on or []
      start = ->
        return if M.theLowdown("pipeline:shutdown").value?
        # **Re-run fix — keep this comment.**
        # Always record the step as scheduled, *before* the
        # already-done early-return. The completion tick uses
        # `scheduled.has(f)` to decide whether a final step counts
        # toward "are we done yet?"; a step that was restored as
        # done at startup never enters this function past the
        # early-return, so without this line a fully-completed
        # state directory would hang the runner forever on the
        # next invocation.
        scheduled.add n
        return if M.theLowdown("done:#{n}").value is true
        try U.event type:'step', phase:'scheduled', step:n catch then null
        artifactSpecLookup = (artifactKey) -> artifacts[artifactKey]
        Promise.resolve(wireInputsForStep(n))
          .then -> runStep(n, steps[n], experiment, M, S, active, resolveArtifact, artifactSpecLookup, U)
          .then -> collectOutputsForStep(n)
          .catch (e) ->
            console.error "! Step #{n} error:", e.message
      if deps.length is 0
        start()
      else
        M.waitFor (deps.map((d)->"done:#{d}")), start

  # ---------------- Completion tick (no hanging on unresolved Promises) ----------------
  tick = ->
    sd = M.theLowdown("pipeline:shutdown").value
    if sd?
      S.writePipelineShutdown sd
      exitCode = if sd.failed is true then 1 else 0
      U.updateRun
        status: if sd.failed is true then 'failed' else 'shutdown'
        shutdown: sd
        finished_at: new Date().toISOString()
      banner if sd.failed is true then "💥 PIPELINE FAILED" else "🛑 PIPELINE SHUTDOWN"
      console.log "  by:", sd.by
      console.log "  reason:", sd.reason
      process.exit(exitCode)

    doneFinals = true
    anyFail = false
    for f in finals
      unless scheduled.has f
        doneFinals = false
        continue
      v = M.theLowdown("done:#{f}").value
      if v isnt true and v isnt false then doneFinals = false
      if v is false then anyFail = true

    if doneFinals and active.count is 0
      if anyFail
        U.updateRun
          status: 'failed'
          finished_at: new Date().toISOString()
        banner "💥 Pipeline finished with failures (final: #{finals.join(', ')})"
        process.exit(1)
      else
        U.updateRun
          status: 'done'
          finished_at: new Date().toISOString()
        banner "🌟 Pipeline finished (final: #{finals.join(', ')})"
        process.exit(0)

    setTimeout(tick, 2000)

  tick()

  ###
  §12 — Signal handlers
  ==================================================================

  `SIGUSR1` prints the currently-active step names without exiting —
  a hand-rolled `kill -USR1 <pid>` from another terminal is the
  cheapest way to ask "what's the runner doing right now?"

  `SIGTERM` / `SIGINT` print the same active list and then exit with
  the conventional 143 / 130 codes. **Note:** these exit the runner
  immediately — in-flight subprocesses keep going until they notice
  their parent is gone. Clean cancellation of a long step is a
  protocol the runner does not currently provide; if you need one,
  add a `cancel:<step>` Memo key the step polls.
  ###
  printActiveSteps = (signalName) ->
    names = Array.from(active.names ? [])
    banner "📶 Signal received: #{signalName}"
    if names.length
      console.log "  active (#{names.length}):", names.join(', ')
    else
      console.log "  active (0): none"

  process.on 'SIGUSR1', ->
    printActiveSteps('SIGUSR1')

  process.on 'SIGTERM', ->
    printActiveSteps('SIGTERM')
    process.exit(143)

  process.on 'SIGINT', ->
    printActiveSteps('SIGINT')
    console.log "\n(CTRL+C) Exiting..."
    process.exit(130)

# **Entry point.** Run only when invoked directly (`coffee
# pipeline_runner.coffee` or the `pipeline` bin). When the file is
# `require`d instead — e.g. a test harness exercising the spec-merge in
# isolation — we skip `main()` and expose the internals below for the
# caller to drive. `ui_server.coffee` *spawns* the runner as a
# subprocess, so it never trips this guard.
main() if require.main is module

module.exports = {
  deepMerge
  stripUiDirectives
  loadYamlSafe
  expandIncludes
  createExperimentObject
  resolveOverrideLayers
  stepScriptCandidates
  resolveStepScript
  resolvePython
  EXEC
  BASE
  CWD
}
