###
        meta/ui.coffee  —  the UI taskmaster's memo-mediated I/O seam
        =====================================================

  MARRIAGE step 1 (2026-10-28, jahbini-confirmed). See
  `pipeline/GPT/marriage.md` "THE CANONICAL GOAL".

  The fused node is ONE process with TWO taskmasters:
    1. the UI service — the taskmaster that NEVER dies; it reads commands
       from the HTML page AND from a distant puppeteer, and it starts
       the other taskmaster;
    2. the DAG runner — started by #1, runs the recipe (petri-net), uses
       the meta layer.
  Neither does direct I/O — both act through the memo + meta. This device
  is how the UI taskmaster "gets its info via the memo": every `ui/*` key
  read/written by a step, by the DAG runner, or by the browser transport
  flows through HERE — in the runner's IN-PROCESS memo, never a file, never
  the obsolete `ipc/` sqlite/broker memo.

  Contract — identical in shape to every meta device (see `yaml.coffee`):
    value === undefined  → READ  (return the current in-process value)
    otherwise            → WRITE (store it, notify, return it)
  The backing store is in-process and lives as long as the UI taskmaster
  (which never dies). No sqlite. No broker.

  Beyond the key rule, the device plants `M.ui` — the handle the long-lived
  UI service (the HTTP/SSE transport, wired in a later increment) binds to:
    M.ui.get(key) / M.ui.set(key, value)      read/write a ui/* key
    M.ui.snapshot()                           all ui/* keys (initial render)
    M.ui.subscribe(cb) -> unsubscribe         cb(key, value) on every write
  The browser's POSTs land as `ui/*` writes; the UI renders from `ui/*`
  reads; SSE pushes come off `subscribe`. Steps reach the UI ONLY through
  these keys (symmetric with how `meta/sqlite` exposes request-keys).

  ADDITIVE: standing this up changes nothing about today's HTTP serving.
  It only gives `ui/*` keys defined memo semantics and exposes `M.ui`.

  ORDERING: `index.coffee` loads this BEFORE `slash.coffee`. A key like
  `ui/intent/next_recipe` is a naked (extension-less) path that slash's
  permissive catch-all would otherwise claim as a FILE. `ui` must win.
###
{EventEmitter} = require 'events'
http = require 'http'
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
  store = {}                      # ui/<...> -> value  (in-process; never sqlite)
  bus   = new EventEmitter()
  bus.setMaxListeners 0           # many SSE clients may subscribe at once

  # Coalesced change notification (2026-10-28). A busy run mirrors EVERY
  # publish here (ui/state, ui/step/*, ui/event, ui/lifecycle); emitting +
  # SSE-broadcasting each one synchronously firehoses every browser tab. So we
  # collect dirty keys and flush the LATEST value per key on a short timer — a
  # burst collapses to ~one push/key per window. The `store` itself updates
  # IMMEDIATELY, so get()/snapshot()/theLowdown() are always current; only the
  # change→SSE push is batched. Low-frequency keys (the ward filter) just incur
  # a ~40ms delay (imperceptible).
  FLUSH_MS   = 40
  pending    = {}
  flushTimer = null
  flush = ->
    flushTimer = null
    keys = Object.keys pending
    snap = pending
    pending = {}
    for k in keys
      try bus.emit 'change', k, snap[k] catch then null
  schedule = ->
    return if flushTimer?
    flushTimer = setTimeout flush, FLUSH_MS

  # The meta rule: ui/* keys get in-process read/write semantics + a coalesced
  # change notification. value === undefined means read; anything else = write.
  # ui/* = UI state; sys/* = operator coordination (freeze, fleet_mode, presence).
  # BOTH are in-process in the shared memo — JSON-faithful + coalesced-pushed over SSE —
  # so the DAG runner, steps, and the browser all share one source of truth. (3.4)
  M.addMetaRule "ui",
    /^(ui|sys)\//,
    (key, value) ->
      if value is undefined
        return store[key]
      store[key] = value       # immediate — reads never wait on the flush
      pending[key] = value
      schedule()
      value

  # The seam the UI taskmaster (HTTP/SSE transport) binds to. Writes route
  # through the SAME memo path (`M.saveThis`) so steps, the DAG runner, and
  # the transport all share one source of truth for `ui/*`.
  M.ui =
    get:       (key) -> store[key]
    set:       (key, value) -> M.saveThis(key, value); value
    snapshot:  -> Object.assign {}, store
    keys:      -> Object.keys store
    del:       (key) ->
      delete store[key]
      try delete M.MM[key]
      pending[key] = undefined   # coalesced deletion push (value undefined → deleted)
      schedule()
      true
    subscribe: (cb) ->
      bus.on 'change', cb
      -> try bus.removeListener 'change', cb catch then null

  # meta/ui OWNS the UI serving (MARRIAGE step 1 — "the UI is an I/O device
  # handled by the meta system of the pipeline's memo"). The fused node's
  # UI-service taskmaster calls `M.ui.serve(port)`; the browser talks ONLY to
  # these routes, which read/write the SHARED in-process memo. No separate
  # ui_server, no broker for `ui/*`. Status (`ui/run`, `ui/step/*`, …) that the
  # DAG-runner taskmaster writes into the SAME memo streams out here for free.
  _readBody = (req) -> new Promise (resolve) ->
    chunks = []
    req.on 'data', (c) -> chunks.push c
    req.on 'end',  -> resolve Buffer.concat(chunks).toString('utf8')
    req.on 'error',-> resolve ''
  _sendJson = (res, code, obj) ->
    res.writeHead code, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'}
    res.end JSON.stringify(obj)
  # Static UI assets (batch 3.1): the fused node serves the real page shell.
  # CWD → BASE → EXEC fallback, mirroring ui_server.resolveUiAsset.
  _ctype = (p) ->
    return 'application/javascript; charset=utf-8' if /\.js$/.test p
    return 'text/css; charset=utf-8'               if /\.css$/.test p
    return 'text/html; charset=utf-8'              if /\.html?$/.test p
    return 'application/json; charset=utf-8'       if /\.json$/.test p
    return 'image/svg+xml'                         if /\.svg$/.test p
    'text/plain; charset=utf-8'
  _resolveUiAsset = (rel) ->
    cands = [path.join((opts.baseDir ? process.cwd()), 'ui', rel)]
    cands.push path.join(opts.basePath, 'ui', rel) if opts.basePath and opts.basePath isnt opts.execDir
    cands.push path.join(opts.execDir, 'ui', rel)  if opts.execDir
    for c in cands
      return c if (try fs.existsSync(c) catch then false)
    null
  _sendFile = (res, file, ctype) ->
    unless file? and (try fs.existsSync(file) catch then false)
      return _sendJson res, 404, {ok: false, error: 'asset not found'}
    try
      res.writeHead 200, {'Content-Type': ctype, 'Cache-Control': 'no-store'}
      res.end fs.readFileSync(file)
    catch err
      try _sendJson res, 500, {ok: false, error: String(err?.message ? err)} catch then null

  # Project-plugin support (batch 3.2). The project's `ui/project.coffee`
  # provides the rich routes (celarien, panels, peer_pipes, …). We load it
  # inside serve() (lazy) and hand it a MEMO-BACKED ctx: `ipcStatus`/
  # `subscribeBroker` map to the shared in-process memo, NOT the broker.
  _resolvePluginPath = (startDir) ->
    dir = startDir ? process.cwd()
    loop
      cand = path.join(dir, 'ui', 'project.coffee')
      return cand if (try fs.existsSync(cand) catch then false)
      parent = path.dirname(dir)
      break if parent is dir
      dir = parent
    null
  _readJson  = (p, fb) -> try JSON.parse(fs.readFileSync(p, 'utf8')) catch then fb
  _readText  = (p, fb) -> try fs.readFileSync(p, 'utf8') catch then fb
  _writeText = (p, t)  -> fs.mkdirSync(path.dirname(p), {recursive: true}); fs.writeFileSync(p, t, 'utf8')
  _listFiles = (dir)   -> try (fs.readdirSync(dir)) catch then []
  _memoIpcShim = ->
    connected: true
    memoRequest: (op, args={}) ->
      new Promise (resolve) ->
        switch op
          when 'get'        then resolve {value: M.theLowdown(args.key)?.value}
          when 'put'        then M.saveThis(args.key, args.value); resolve {ok: true, value: args.value}
          when 'del'        then (try delete M.MM[args.key]); resolve {ok: true}
          when 'get_prefix' then resolve {entries: ({key: k, value: e.value} for own k, e of M.MM when k.indexOf(args.prefix ? '') is 0)}
          else resolve {}
    on: (ev, cb) -> (if ev is 'memo' then M.ui.subscribe((k, v) -> try cb({key: k, payload: {value: v}})) else (-> ))
    client:
      subscribe: (t, cb) -> try M.ui.subscribe((k, v) -> cb(t, {value: v}))
      unsubscribe: (-> )
  _buildPluginCtx = (port) ->
    CWD:              opts.baseDir ? process.cwd()
    EXEC_ROOT:        opts.execDir
    BASE_ROOT:        opts.basePath ? opts.baseDir
    fs:               fs
    path:             path
    http:             http
    yaml:             (require 'js-yaml')
    spawn:            (require 'child_process').spawn
    sendJson:         _sendJson
    readRequestBody:  _readBody
    readJson:         _readJson
    readText:         _readText
    writeText:        _writeText
    resolveUiAsset:   _resolveUiAsset
    listFiles:        _listFiles
    # Shared library inventory (INVENTORY_BASH + parse) for the peer-pipes panel;
    # it SSH-enumerates model pipes on remote hosts. Null-safe if the module moves.
    pipeInventory:    (try require(path.join(opts.execDir, 'ui', 'pipe_inventory')) catch then null)
    describeOutputFile: (relativePath, runStart=null) ->
      full   = path.join((opts.baseDir ? process.cwd()), relativePath)
      exists = (try fs.existsSync(full) catch then false)
      stat   = if exists then (try fs.statSync(full) catch then null) else null
      mtime  = if stat? then stat.mtime.toISOString() else null
      fresh  = false
      if stat? and runStart?
        started = new Date(runStart)
        fresh = not Number.isNaN(started.getTime()) and stat.mtime.getTime() >= started.getTime()
      {name: path.basename(relativePath), path: relativePath, exists, size: (stat?.size ? null), mtime, is_fresh: fresh}
    normalizeUiRun:   (run) -> run   # fused: run is in-process, no separate pid to liveness-check
    UI_BIND_MODE:     (process.env.UI_BIND_MODE ? 'net')
    PORT:             port
    ipcStatus:        _memoIpcShim()
    subscribeBroker:  (topic, cb) -> (-> )               # single fused node — no cross-pipe broker; refine if needed

  # Status builder (3.5) — the rich /api/status the UI needs to know its CWD/pipe:
  # workspace + pipe{root,current,workspace,pipes[]} + run + pipeline_state + steps.
  _pipesRoot = -> path.join((opts.basePath ? opts.baseDir ? process.cwd()), 'pipes')
  _workspacePipeName = (wp) ->
    rel = try path.relative(_pipesRoot(), (wp ? opts.baseDir ? process.cwd())) catch then ''
    return null if not rel or rel.indexOf('..') is 0 or path.isAbsolute(rel) or rel is ''
    rel.split(path.sep)[0] ? null
  _listPipeDirs = ->
    root = _pipesRoot()
    return [] unless (try fs.existsSync(root) catch then false)
    ((try fs.readdirSync(root) catch then []).filter (n) -> (try fs.statSync(path.join(root, n)).isDirectory() catch then false)).sort (a, b) -> String(a).localeCompare String(b)
  _collectSteps = ->   # UI wants an ARRAY of row objects {step,status,started_at,...}
    sdir = path.join((opts.baseDir ? process.cwd()), 'state')
    # The on-disk step-<name>.json files PERSIST across recipes (startup state
    # restore reads them to skip unchanged steps). Filter to the CURRENT recipe's
    # step set so stale prior-run steps don't bleed into the panel. A step is a
    # top-level recipe key whose value is a plain object with run/run_mlx — the
    # same rule the DAG's discoverSteps uses, so the panel matches the flowchart.
    recipe = _parseRecipe(_controlPipeline())
    want = null
    if recipe and typeof recipe is 'object'
      want = {}
      for own k, v of recipe when v and typeof v is 'object' and not Array.isArray(v) and (v.run? or v.run_mlx?)
        want[k] = true
      want = null unless Object.keys(want).length
    rows = []
    for f in (try fs.readdirSync(sdir) catch then []) when /^step-(.+)\.json$/.test(f)
      name = f.replace(/^step-/, '').replace(/\.json$/, '')
      continue if want and not want[name]
      j = _readJson(path.join(sdir, f), null)
      continue unless j
      j.step ?= name
      rows.push j
    rows.sort (a, b) -> String(a.started_at ? a.updated_at ? '').localeCompare(String(b.started_at ? b.updated_at ? ''))
    rows
  _describeFiles = (relDir, re) ->   # renderFiles() wants objects, not bare names
    dir = path.join((opts.baseDir ? process.cwd()), relDir)
    now = Date.now()
    for f in ((try fs.readdirSync(dir) catch then []).sort()) when re.test(f)
      st = try fs.statSync(path.join(dir, f)) catch then null
      {name: f, path: "#{relDir}/#{f}", exists: true, size: (st?.size ? null), mtime: (st?.mtime?.toISOString() ? null), is_fresh: (st? and (now - st.mtimeMs) < 300000)}
  _controlPipeline = ->
    co = try (require 'js-yaml').load(fs.readFileSync(path.join((opts.baseDir ? process.cwd()), 'control_override.yaml'), 'utf8')) catch then null
    String(co?.pipeline ? '')
  _listRecipes = ->   # config/*.yaml across CWD(pipe) → BASE(project) → EXEC(shipped), most-specific wins
    seen = {}; out = []
    for [dir, source] in [[(opts.baseDir ? process.cwd()), 'pipe'], [opts.basePath, 'project'], [opts.execDir, 'shipped']] when dir
      for f in (try fs.readdirSync(path.join(dir, 'config')) catch then []) when /\.ya?ml$/.test(f)
        name = f.replace(/\.ya?ml$/, '')
        unless seen[name]
          seen[name] = true
          out.push {name, source}
    out.sort (a, b) -> String(a.name).localeCompare String(b.name)
  _recipeConfigText = (name) ->   # the recipe's config/<name>.yaml (read-only "background")
    return '' unless name
    for dir in [(opts.baseDir ? process.cwd()), opts.basePath, opts.execDir] when dir
      p = path.join(dir, 'config', "#{name}.yaml")
      return _readText(p, '') if (try fs.existsSync(p) catch then false)
    ''
  # The per-recipe ui_values FORM (3.6). Relocated scanUiFields: walk the parsed
  # recipe config for inline ['UI_checkbox'|'UI_dropdown'|'UI_textarea', …]
  # directives; objects recurse, non-directive arrays are leaves. The chosen
  # value comes from control_override.ui_values, else override/<recipe>.yaml,
  # else the directive's default.
  _getByPath = (root, dotted) ->
    return undefined unless root? and typeof dotted is 'string' and dotted.length
    node = root
    for part in dotted.split('.')
      return undefined unless node? and typeof node is 'object'
      node = node[part]
    node
  _parseYaml = (p) -> try (require 'js-yaml').load(fs.readFileSync(p, 'utf8')) catch then null
  _parseRecipe = (name) ->
    return null unless name
    for dir in [(opts.baseDir ? process.cwd()), opts.basePath, opts.execDir] when dir
      p = path.join(dir, 'config', "#{name}.yaml")
      return _parseYaml(p) if (try fs.existsSync(p) catch then false)
    null
  _loadDropdownOptions = (specPath) ->
    return [] unless typeof specPath is 'string' and specPath.length
    if specPath is 'adapters'
      buildDir = path.join((opts.baseDir ? process.cwd()), 'build')
      rows = [{key: '', label: '(base — no adapter)'}]
      if (try fs.existsSync(buildDir) catch then false)
        for name in ((try fs.readdirSync(buildDir) catch then []).sort()) when /^adapter($|_)/.test(name)
          full = path.join(buildDir, name)
          continue unless (try (fs.statSync(full).isDirectory() and fs.existsSync(path.join(full, 'adapter_config.json'))) catch then false)
          rows.push {key: "build/#{name}", label: (if name is 'adapter' then 'adapter (current)' else name)}
      return rows
    []
  _scanUiFields = (recipe, override, pendingUi={}) ->
    rows = []
    buildLabel = (p) ->
      parts = String(p ? '').split('.')
      if parts.length >= 2 then "#{parts[0]}: #{parts[parts.length - 1]}" else p
    walk = (node, prefix='') ->
      return unless node? and typeof node is 'object'
      if Array.isArray(node)
        directive = String(node[0] ? '')
        if directive is 'UI_checkbox'
          dv = node[1] is true
          cv = if Object::hasOwnProperty.call(pendingUi, prefix)
            pendingUi[prefix] is true
          else
            ov = _getByPath(override, prefix)
            if typeof ov is 'boolean' then ov else dv
          rows.push {path: prefix, label: buildLabel(prefix), type: 'checkbox', default_value: dv, value: cv}
        else if directive is 'UI_dropdown'
          sp = String(node[1] ? ''); dv = String(node[2] ? '')
          cv = if Object::hasOwnProperty.call(pendingUi, prefix)
            String(pendingUi[prefix] ? '')
          else
            ov = _getByPath(override, prefix)
            if typeof ov is 'string' then ov else dv
          rows.push {path: prefix, label: buildLabel(prefix), type: 'dropdown', default_value: dv, value: cv, source_path: sp, options: _loadDropdownOptions(sp)}
        else if directive is 'UI_textarea'
          dv = if node.length >= 2 then String(node[1] ? '') else ''
          cv = if Object::hasOwnProperty.call(pendingUi, prefix)
            String(pendingUi[prefix] ? '')
          else
            ov = _getByPath(override, prefix)
            if typeof ov is 'string' then ov else dv
          rows.push {path: prefix, label: buildLabel(prefix), type: 'textarea', default_value: dv, value: cv}
        # non-directive arrays are leaf data — do not recurse
      else
        for own k, v of node
          walk v, (if prefix then "#{prefix}.#{k}" else k)
    walk recipe
    rows
  _buildUiFields = ->
    sel = _controlPipeline()
    return [] unless sel
    recipe = _parseRecipe(sel)
    return [] unless recipe
    cwd = opts.baseDir ? process.cwd()
    override = _parseYaml(path.join(cwd, 'override', "#{sel}.yaml")) ? {}
    co = _parseYaml(path.join(cwd, 'control_override.yaml')) ? {}
    _scanUiFields(recipe, override, (co?.ui_values ? {}))
  _describeOutput = (rel, runStart=null) ->   # single-file descriptor (legacy describeOutputFile)
    full = path.join((opts.baseDir ? process.cwd()), rel)
    exists = (try fs.existsSync(full) catch then false)
    st = if exists then (try fs.statSync(full) catch then null) else null
    fresh = false
    if st? and runStart?
      started = new Date(runStart)
      fresh = not Number.isNaN(started.getTime()) and st.mtime.getTime() >= started.getTime()
    {name: path.basename(rel), path: rel, exists, size: (st?.size ? null), mtime: (st?.mtime?.toISOString() ? null), is_fresh: fresh}
  _readJsonlTail = (p, maxRows=80) ->   # legacy readJsonlTail — events timeline
    return [] unless (try fs.existsSync(p) catch then false)
    rows = []
    for line in (try fs.readFileSync(p, 'utf8') catch then '').split(/\r?\n/) when line.trim().length
      try rows.push JSON.parse(line) catch then null
    rows.slice Math.max(rows.length - maxRows, 0)
  _collectExpectedOutputs = (run) ->   # legacy collectExpectedOutputs → {out_files, diary_files}
    cwd = opts.baseDir ? process.cwd()
    runStart = run?.started_at ? null
    diaryDir = path.join(cwd, 'diary')
    diary = []
    if (try fs.existsSync(diaryDir) catch then false)
      for f in (try fs.readdirSync(diaryDir) catch then []) when (try fs.statSync(path.join(diaryDir, f)).isFile() catch then false)
        diary.push _describeOutput("diary/#{f}", runStart)
    recipe = _parseRecipe(run?.pipeline ? _controlPipeline())
    return {out_files: [], diary_files: diary} unless recipe
    outs = []; seen = {}
    for own key, spec of (recipe?.artifacts ? {}) when spec? and typeof spec is 'object' and typeof spec.target is 'string'
      target = String(spec.target)
      continue if seen[target] or /^diary\//.test(target)
      seen[target] = true
      outs.push _describeOutput(target, runStart)
    outs.sort (a, b) -> String(a.path).localeCompare String(b.path)
    {out_files: outs, diary_files: diary}
  _isAllowedFilePath = (rel) ->   # legacy isAllowedFilePath — viewer whitelist
    return false unless typeof rel is 'string' and rel.length
    n = path.normalize(rel)
    return false if n.startsWith('..') or path.isAbsolute(n)
    /^logs\//.test(n) or /^out\//.test(n) or /^diary\//.test(n) or /^build\//.test(n) or /^tested\//.test(n)
  _readViewerFile = (rel) ->   # legacy readViewerFile — body for the file modal
    return null unless _isAllowedFilePath(rel)
    full = path.join((opts.baseDir ? process.cwd()), rel)
    return null unless (try fs.existsSync(full) catch then false)
    st = try fs.statSync(full) catch then null
    return null unless st?.isFile?()
    {path: rel, size: st.size, mtime: st.mtime.toISOString(), text: _readText(full, '')}
  _buildStatus = ->
    cwd  = opts.baseDir ? process.cwd()
    base = opts.basePath ? cwd
    current = _workspacePipeName(cwd)
    # Rich run status: the UiRecorder writes state/ui-run.json (started_at/logdir/
    # id/hh_mm/finished_at); the in-process memo ui/run carries the live status.
    uiRunDisk = _readJson(path.join(cwd, 'state', 'ui-run.json'), {}) ? {}
    uiRunMemo = M.theLowdown('ui/run')?.value ? {}
    uiRun = Object.assign {}, uiRunDisk, uiRunMemo
    run = Object.assign({status: 'idle', pipeline: _controlPipeline(), cwd: cwd, exec: opts.execDir, pid: process.pid, started_at: (uiRun.started_at ? uiRun.at ? null), logdir: (uiRun.logdir ? null), is_process_alive: (uiRun.status is 'running'), is_attached: false}, uiRun)
    expected = _collectExpectedOutputs(run)
    uiCtl = _readJson(path.join(cwd, 'state', 'ui-control.json'), {}) ? {}
    loraRemaining = _readJson(path.join(cwd, 'out', 'lora_remaining_count.json'), null)
    oracleRemaining = _readJson(path.join(cwd, 'out', 'oracle_remaining_count.json'), null)
    # newest .log drives the "latest log" panel (legacy latestLogStem equivalent)
    logsDir = path.join(cwd, 'logs')
    newestLog = ((try fs.readdirSync(logsDir) catch then []).filter((f) -> /\.log$/.test f).map((f) -> {f, m: (try fs.statSync(path.join(logsDir, f)).mtimeMs catch then 0)}).sort((a, b) -> b.m - a.m)[0]?.f) ? null
    logStem = if newestLog then newestLog.replace(/\.log$/, '') else null
    tail = (p) -> try (t = fs.readFileSync(p, 'utf8'); if t.length > 20000 then t.slice(-20000) else t) catch then ''
    ok: true
    run: run
    pipeline_state: _readJson(path.join(cwd, 'pipeline.json'), null)
    workspace: {top_level: path.basename(base), pipe: current}
    pipe: {root: _pipesRoot(), current, workspace: cwd, pipes: ({name: n, is_active: n is current} for n in _listPipeDirs())}
    steps: _collectSteps()
    # Safe defaults for every field index.html's JS iterates — without these the
    # dashboard hits `undefined` (e.g. data.out_files.map) and the whole page
    # (top line included) fails to render. `controls.scope` drives body.scope-*.
    controls:
      scope: (if current then 'pipe-scope' else 'project-root')
      pipeline: _controlPipeline()
      pipelines_enriched: _listRecipes()
      ui_fields: _buildUiFields()
      control_override_text: _readText(path.join(cwd, 'control_override.yaml'), '')
      human_override_text: (if (s = _controlPipeline()) then _readText(path.join(cwd, 'override', "#{s}.yaml"), '') else '')
      recipe_text: _recipeConfigText(_controlPipeline())
      experiment_text: _readText(path.join(cwd, 'experiment.yaml'), '')
      continuous: (uiCtl.continuous is true)
      continuous_delay_seconds: (if Number(uiCtl.continuous_delay_seconds) is 20 then 20 else 60)
    merge_run: _readJson(path.join(cwd, 'state', 'merge-run.json'), null)
    out_files: expected.out_files
    diary_files: expected.diary_files
    log_files: _describeFiles('logs', /\.(log|err)$/)
    events: _readJsonlTail(path.join(cwd, 'state', 'ui-events.jsonl'))
    adapters: []
    panels: []
    latest_log: (if newestLog then tail(path.join(logsDir, newestLog)) else '')
    latest_err: (if logStem then tail(path.join(logsDir, "#{logStem}.err")) else '')
    latest_log_stem: logStem
    lora_remaining_count: loraRemaining
    oracle_remaining_count: oracleRemaining
    stories_remaining_count: (if oracleRemaining? then oracleRemaining else loraRemaining)
    pid: process.pid

  M.ui.serve = (serveOpts={}) ->
    port = Number(serveOpts.port ? process.env.UI_PORT ? 4300)
    host = String(serveOpts.host ? '0.0.0.0')
    # Load + mount the project plugin's routes with the memo-backed ctx (3.2).
    pluginRoutes = []; pluginCtx = null; pluginAugmentStatus = null
    try
      pluginPath = _resolvePluginPath(opts.baseDir ? process.cwd())
      if pluginPath
        plugin = require pluginPath
        try plugin.preStartup?()
        pluginCtx = _buildPluginCtx(port)
        _initResult = plugin.init?(pluginCtx)
        pluginRoutes = _initResult?.routes ? []
        pluginAugmentStatus = _initResult?.augmentStatus
        console.log "[meta/ui] mounted #{pluginRoutes.length} plugin route(s) from #{pluginPath}"
    catch err
      console.error "[meta/ui] plugin load failed:", (err?.stack ? err)
    tryPlugin = (req, res, pathname) ->
      for route in pluginRoutes when route?.handler
        continue if route.method and route.method isnt req.method
        hit = (route.path? and pathname is route.path) or (route.pathPrefix? and pathname.indexOf(route.pathPrefix) is 0)
        continue unless hit
        Promise.resolve(route.handler(req, res, pluginCtx)).catch (err) -> try _sendJson res, 500, {ok: false, error: String(err?.message ? err)} catch then null
        return true
      false
    srv = http.createServer (req, res) ->
      pathname = String(req.url ? '/').split('?')[0]
      try
        return if tryPlugin(req, res, pathname)   # plugin routes first (can shadow)
        if pathname is '/api/events'
          # SSE: initial snapshot + live coalesced pushes, straight off the memo.
          res.writeHead 200,
            'Content-Type':      'text/event-stream'
            'Cache-Control':     'no-cache'
            'Connection':        'keep-alive'
            'X-Accel-Buffering': 'no'
          send = (name, payload) -> try res.write "event: #{name}\ndata: #{JSON.stringify payload}\n\n" catch then null
          send 'hello', {ok: true}
          send 'memo', {key: k, value: v, version: null} for k, v of M.ui.snapshot()
          unsub = M.ui.subscribe (k, v) -> send 'memo', {key: k, value: v, version: null, deleted: v is undefined}
          hb = setInterval (-> try res.write ': ping\n\n' catch then null), 20000
          req.on 'close', -> clearInterval hb; try unsub?()
          return
        if pathname is '/api/ui'
          return _sendJson res, 200, {ok: true, entries: M.ui.snapshot()}
        if pathname.indexOf('/api/ui/') is 0
          raw = decodeURIComponent pathname.slice('/api/ui/'.length)
          return _sendJson(res, 400, {ok: false, error: 'key required'}) unless raw.length
          key = if raw.indexOf('ui/') is 0 then raw else "ui/#{raw}"
          if req.method is 'POST'
            body    = await _readBody req
            payload = try JSON.parse(body or '{}') catch then {}
            value   = if payload? and typeof payload is 'object' and payload.hasOwnProperty('value') then payload.value else payload
            M.saveThis key, value
            return _sendJson res, 200, {ok: true, key, value}
          return _sendJson res, 200, {ok: true, key, value: M.ui.get(key)}
        # Core ui_server-owned routes, relocated + memo-centric (batch 3.3):
        if pathname is '/api/launch' and req.method is 'POST'
          body = await _readBody req
          payload = try JSON.parse(body or '{}') catch then {}
          return _sendJson res, 503, {ok: false, error: 'no launcher wired'} unless M.ui.onLaunch?
          return _sendJson res, 200, M.ui.onLaunch(payload)
        if pathname is '/api/kill' and req.method is 'POST'
          # In-process kill: the DAG's completion tick watches `pipeline:shutdown`.
          M.saveThis 'pipeline:shutdown', {by: 'ui', reason: 'killed via /api/kill', failed: false, at: Date.now()}
          return _sendJson res, 200, {ok: true, killed: true}
        if pathname is '/api/status'
          status = _buildStatus()
          if pluginAugmentStatus?
            try await Promise.resolve(pluginAugmentStatus(status, pluginCtx)) catch err then null
          return _sendJson res, 200, status
        if pathname is '/api/file' and req.method is 'GET'
          q = try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('path') catch then null
          rel = String(q ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'path query param required'}) unless rel.length
          file = _readViewerFile(rel)
          return _sendJson(res, 404, {ok: false, error: "file not found or not allowed: #{rel}"}) unless file?
          return _sendJson res, 200, {ok: true, file: file}
        if pathname is '/api/pipeline_svg' and req.method is 'GET'
          # Default: render the CURRENT pipe's experiment.yaml as a DAG SVG.
          # With ?pipeline=<name>, preview that recipe's config/<name>.yaml graph
          # before a run. require.cache bust → renderer edits land without restart.
          cwd = opts.baseDir ? process.cwd()
          q = try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('pipeline') catch then null
          requested = String(q ? '').trim()
          try
            doc = null
            if requested.length
              doc = _parseRecipe(requested)
              unless doc?
                res.writeHead 404, {'Content-Type': 'text/plain; charset=utf-8'}
                return res.end "no config for recipe '#{requested}'"
            else
              expPath = path.join(cwd, 'experiment.yaml')
              unless (try fs.existsSync(expPath) catch then false)
                res.writeHead 404, {'Content-Type': 'text/plain; charset=utf-8'}
                return res.end 'no experiment.yaml yet — run the pipeline once, then reload.'
              doc = _parseYaml(expPath)
            scriptPath = path.join(opts.execDir, 'pipeline_svg.coffee')
            delete require.cache[require.resolve(scriptPath)] if require.cache[require.resolve(scriptPath)]?
            {renderSvg} = require scriptPath
            svg = renderSvg doc
            res.writeHead 200, {'Content-Type': 'image/svg+xml; charset=utf-8', 'Cache-Control': 'no-store'}
            return res.end svg
          catch err
            res.writeHead 500, {'Content-Type': 'text/plain; charset=utf-8'}
            return res.end "[pipeline_svg] #{err?.message ? err}"
        if pathname is '/api/adapters' and req.method is 'GET'
          try
            options = _loadDropdownOptions('adapters')
            iters = []
            for opt in options when typeof opt?.label is 'string'
              m = opt.label.match /@(\d+)/
              iters.push Number(m[1]) if m
            trained = options.filter (o) -> o? and o.key? and o.key.length > 0
            return _sendJson res, 200, {ok: true, adapters: options, summary: {has_trained: trained.length > 0, top_iter: (if iters.length then Math.max(iters...) else null), count: trained.length}}
          catch err
            return _sendJson res, 500, {ok: false, error: String(err?.message ? err)}
        if pathname is '/api/step_detail' and req.method is 'GET'
          cwd = opts.baseDir ? process.cwd()
          q = try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('name') catch then null
          name = String(q ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'name required'}) unless name.length
          return _sendJson(res, 400, {ok: false, error: "invalid step name: #{name}"}) if name.includes('/') or name.includes(path.sep) or name in ['.', '..']
          stateFile = path.join(cwd, 'state', "step-#{name}.json")
          paramsFile = path.join(cwd, 'params', "#{name}.yaml")
          state = null; stateErr = null
          if (try fs.existsSync(stateFile) catch then false)
            try state = JSON.parse(fs.readFileSync(stateFile, 'utf8')) catch err then stateErr = String(err?.message ? err)
          paramsText = null; paramsErr = null
          if (try fs.existsSync(paramsFile) catch then false)
            try paramsText = fs.readFileSync(paramsFile, 'utf8') catch err then paramsErr = String(err?.message ? err)
          return _sendJson res, 200, {ok: true, name, state, state_error: stateErr, state_path: path.relative(cwd, stateFile), params_text: paramsText, params_error: paramsErr, params_path: path.relative(cwd, paramsFile)}
        if pathname is '/api/step_restart' and req.method is 'POST'
          cwd = opts.baseDir ? process.cwd()
          body = await _readBody req
          p = try JSON.parse(body or '{}') catch then {}
          name = String(p?.name ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'name required'}) unless name.length
          return _sendJson(res, 400, {ok: false, error: "invalid step name: #{name}"}) if name.includes('/') or name.includes(path.sep) or name in ['.', '..']
          if (M.theLowdown('ui/run')?.value?.status is 'running')
            return _sendJson res, 200, {ok: true, attached: true, note: 'a run is already active; restart_here NOT set (would race). Kill the run first, then retry.'}
          expPath = path.join(cwd, 'experiment.yaml')
          return _sendJson(res, 400, {ok: false, error: 'no experiment.yaml — run the pipeline once before using restart'}) unless (try fs.existsSync(expPath) catch then false)
          experiment = _parseYaml(expPath)
          return _sendJson(res, 500, {ok: false, error: 'cannot parse experiment.yaml'}) unless experiment?
          hasStep = false
          for own k, v of experiment when k not in ['run', 'artifacts', 'pipeline'] and v? and typeof v is 'object' and v.run?
            hasStep = true if k is name
          return _sendJson(res, 404, {ok: false, error: "step '#{name}' not found in experiment.yaml"}) unless hasStep
          marked = false
          stateFile = path.join(cwd, 'state', "step-#{name}.json")
          if (try fs.existsSync(stateFile) catch then false)
            try
              st = JSON.parse(fs.readFileSync(stateFile, 'utf8'))
              st.restart_here = true
              st.updated_at = new Date().toISOString()
              fs.writeFileSync stateFile, JSON.stringify(st, null, 2), 'utf8'
              marked = true
            catch err
              return _sendJson res, 500, {ok: false, error: "cannot update #{path.relative(cwd, stateFile)}: #{err?.message ? err}"}
          removedPj = false
          if (try fs.existsSync(path.join(cwd, 'pipeline.json')) catch then false)
            try (fs.unlinkSync(path.join(cwd, 'pipeline.json')); removedPj = true) catch then null
          return _sendJson(res, 503, {ok: false, error: 'no launcher wired'}) unless M.ui.onLaunch?
          launch = M.ui.onLaunch({pipeline: _controlPipeline(), restart: true})
          return _sendJson res, 200, {ok: (launch?.ok ? false), name, restart_here_marked: (if marked then [name] else []), already_unmarked: (if marked then [] else [name]), removed_pipeline_json: removedPj, pid: launch?.pid, status: launch?.status, error: launch?.error}
        if pathname is '/api/save_good_adapter' and req.method is 'POST'
          cwd = opts.baseDir ? process.cwd()
          body = await _readBody req
          p = try JSON.parse(body or '{}') catch then {}
          name = String(p?.name ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'name required'}) unless name.length
          return _sendJson(res, 400, {ok: false, error: 'invalid name: letters, digits, _, -, . only'}) unless /^[A-Za-z0-9._-]+$/.test(name) and name not in ['.', '..']
          expPath = path.join(cwd, 'experiment.yaml')
          return _sendJson(res, 400, {ok: false, error: 'no experiment.yaml — run the pipeline once first'}) unless (try fs.existsSync(expPath) catch then false)
          experiment = _parseYaml(expPath)
          return _sendJson(res, 500, {ok: false, error: 'cannot parse experiment.yaml'}) unless experiment?
          sourceStep = null; sourcePath = null
          for own k, v of experiment when k not in ['run', 'artifacts', 'pipeline'] and v? and typeof v is 'object' and v.run?
            ap = v.adapter_path
            if typeof ap is 'string' and ap.trim().length
              sourceStep = k; sourcePath = ap.trim(); break
          return _sendJson(res, 400, {ok: false, error: 'no step in experiment.yaml has adapter_path set'}) unless sourcePath?
          absSource = if path.isAbsolute(sourcePath) then sourcePath else path.join(cwd, sourcePath)
          return _sendJson(res, 404, {ok: false, error: "adapter file not found: #{path.relative(cwd, absSource)}"}) unless (try fs.existsSync(absSource) catch then false)
          sourceIsFile = (try fs.statSync(absSource).isFile() catch then false)
          configDir = if sourceIsFile then path.dirname(absSource) else absSource
          weightsSource = if sourceIsFile then absSource else path.join(absSource, 'adapters.safetensors')
          configSource = path.join(configDir, 'adapter_config.json')
          return _sendJson(res, 404, {ok: false, error: "adapter weights not found: #{path.relative(cwd, weightsSource)}"}) unless (try fs.existsSync(weightsSource) catch then false)
          return _sendJson(res, 404, {ok: false, error: "adapter_config.json not found in #{path.relative(cwd, configDir)}"}) unless (try fs.existsSync(configSource) catch then false)
          destDir = path.join(cwd, 'build', 'good_adapters', name)
          return _sendJson(res, 409, {ok: false, error: "a good adapter named '#{name}' already exists (#{path.relative(cwd, destDir)})"}) if (try fs.existsSync(destDir) catch then false)
          try
            fs.mkdirSync destDir, {recursive: true}
            fs.copyFileSync weightsSource, path.join(destDir, 'adapters.safetensors')
            fs.copyFileSync configSource, path.join(destDir, 'adapter_config.json')
            meta = {saved_at: new Date().toISOString(), saved_as: name, source_pipe: path.basename(cwd), source_step: sourceStep, source_adapter_path: sourcePath, source_weights_abs: weightsSource, source_config_abs: configSource}
            fs.writeFileSync path.join(destDir, 'meta.json'), JSON.stringify(meta, null, 2), 'utf8'
          catch err
            return _sendJson res, 500, {ok: false, error: String(err?.message ? err)}
          return _sendJson res, 200, {ok: true, name, source: "step #{sourceStep}: #{sourcePath}", destination: path.relative(cwd, destDir)}
        if pathname is '/api/merge_pipe' and req.method is 'POST'
          return _sendJson res, 501, {ok: false, error: 'merge feature not available on the fused node (writeStory-specific startMerge/merge_sqlite_dbs.coffee not ported)'}
        if pathname.startsWith('/api/run/') and req.method is 'GET'
          return _sendJson res, 501, {ok: false, error: 'run-detail evaluation (buildRunEvaluation) not yet ported to the fused node'}
        # Secondary core routes (batch 3.3b), fused-simple + memo-centric:
        if pathname is '/api/control' and req.method is 'POST'
          body = await _readBody req
          p = try JSON.parse(body or '{}') catch then {}
          obj = {pipeline: String(p.pipeline ? '')}
          obj.ui_values = p.ui_values if p.ui_values? and typeof p.ui_values is 'object'
          for k in ['scene', 'arrival', 'disturbance', 'reflection', 'realization'] when p[k]?
            obj[k] = String(p[k])
          try _writeText path.join((opts.baseDir ? process.cwd()), 'control_override.yaml'), (require 'js-yaml').dump(obj)
          return _sendJson res, 200, {ok: true, control_override: obj}
        if pathname is '/api/human_override' and req.method is 'POST'
          body = await _readBody req
          p = try JSON.parse(body or '{}') catch then {}
          recipe = String(p.pipeline ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'pipeline required'}) unless recipe.length and recipe.indexOf('/') < 0 and recipe.indexOf('..') < 0
          text = if typeof p.human_override_text is 'string' then p.human_override_text else ''
          dest = path.join((opts.baseDir ? process.cwd()), 'override', "#{recipe}.yaml")
          try _writeText dest, text
          return _sendJson res, 200, {ok: true, recipe, override_path: dest}
        if pathname is '/api/clear_logs' and req.method is 'POST'
          dir = path.join((opts.baseDir ? process.cwd()), 'logs')
          try (fs.rmSync(path.join(dir, f), {force: true}) for f in (try fs.readdirSync(dir) catch then [])) catch then null
          return _sendJson res, 200, {ok: true, cleared: 'logs'}
        if pathname is '/api/clear_output' and req.method is 'POST'
          dir = path.join((opts.baseDir ? process.cwd()), 'out')
          try (fs.rmSync(path.join(dir, f), {recursive: true, force: true}) for f in (try fs.readdirSync(dir) catch then [])) catch then null
          return _sendJson res, 200, {ok: true, cleared: 'out'}
        if pathname is '/api/clear_pipeline_state' and req.method is 'POST'
          cwd = opts.baseDir ? process.cwd()
          try fs.unlinkSync path.join(cwd, 'pipeline.json') catch then null
          sdir = path.join(cwd, 'state')
          try (fs.unlinkSync(path.join(sdir, f)) for f in (try fs.readdirSync(sdir) catch then []) when /^step-.*\.json$/.test(f)) catch then null
          return _sendJson res, 200, {ok: true, cleared: 'pipeline_state'}
        if pathname is '/api/find_active_runner'
          run = M.theLowdown('ui/run')?.value ? null
          return _sendJson res, 200, {ok: true, active: (run?.status is 'running'), run}
        if pathname is '/api/shutdown_ui' and req.method is 'POST'
          _sendJson res, 200, {ok: true, shutting_down: true}
          setTimeout (-> process.exit 0), 100
          return
        if pathname is '/api/recipe_flowchart'
          q = try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('recipe') catch then null
          name = String(q ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'recipe query param required'}) unless name.length and /^[A-Za-z0-9_.-]+$/.test(name)
          cands = [path.join((opts.baseDir ? process.cwd()), 'flowchart', "#{name}.md")]
          cands.push path.join(opts.basePath, 'flowchart', "#{name}.md") if opts.basePath and opts.basePath isnt opts.execDir
          cands.push path.join(opts.execDir, 'flowchart', "#{name}.md") if opts.execDir
          for c in cands when (try fs.existsSync(c) catch then false)
            return _sendFile res, c, 'text/markdown; charset=utf-8'
          return _sendJson res, 404, {ok: false, error: "no flowchart for '#{name}'"}
        # /api/sqlite/<request-key> — dispatch a meta/sqlite request key through the
        # ONE shared memo (it already has meta/sqlite loaded for this pipe's CWD).
        # Powers the SQLite observability panels in index.html (fetchSqliteRequest).
        # The /diff variant surfaces the meta layer's specific validation error;
        # the generic variant swallows errors → 404 (legacy `runSqliteRequest`).
        if pathname is '/api/sqlite/diff'
          since = String((try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('since') catch then '') ? '').trim()
          return _sendJson(res, 400, {ok: false, error: 'since=<run_id|ISO-timestamp|change_id> is required'}) unless since.length
          isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(since)
          isInt  = /^\d+$/.test(since)
          isIso  = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(since)
          unless isUuid or isInt or isIso
            return _sendJson res, 400, {ok: false, error: "since='#{since}' is not a uuid, ISO 8601 timestamp, or change_id", accepted_shapes: ['uuid', 'ISO-8601-timestamp', 'change_id']}
          try
            value = M.theLowdown("changesSince{#{since}}.json")?.value
          catch err
            return _sendJson res, 400, {ok: false, error: String(err?.message ? err), since}
          return _sendJson(res, 404, {ok: false, error: 'change-log diff did not resolve', since}) if value is undefined
          return _sendJson res, 200, {ok: true, since, diff: value}
        if pathname.indexOf('/api/sqlite/') is 0
          raw = pathname.slice('/api/sqlite/'.length)
          try
            requestKey = decodeURIComponent(raw)
          catch
            return _sendJson res, 400, {ok: false, error: 'invalid request key encoding'}
          value = try M.theLowdown(requestKey)?.value catch then undefined
          return _sendJson(res, 404, {ok: false, error: 'request key did not resolve', request: requestKey}) if value is undefined
          return _sendJson res, 200, {ok: true, request: requestKey, value}
        # /api/manifest — agent bootstrap (what this pipe offers). Lean vs legacy:
        # recipe includes are NOT expanded here (steps defined via includes won't
        # appear), which is fine — no browser code fetches this; it's for agents.
        if pathname is '/api/manifest'
          cwd = opts.baseDir ? process.cwd()
          recipeManifest = (name) ->
            recipe = _parseRecipe(name)
            return null unless recipe?
            steps = []; artifacts = []
            for own key, val of recipe
              continue unless val? and typeof val is 'object' and not Array.isArray(val)
              if val.run? or val.run_mlx?
                steps.push {name: key, run: val.run ? null, depends_on: val.depends_on ? [], needs: val.needs ? [], makes: val.makes ? [], desc: val.desc ? null}
            if recipe.artifacts? and typeof recipe.artifacts is 'object'
              for own aKey, aSpec of recipe.artifacts
                artifacts.push Object.assign({name: aKey}, (if typeof aSpec is 'object' then aSpec else {value: aSpec}))
            {name, steps, artifacts}
          recipeNames = (r.name for r in _listRecipes())
          byName = {}
          for name in recipeNames
            m = recipeManifest(name)
            byName[name] = m if m?
          sqliteRequests = try (require path.join(opts.execDir, 'meta', 'sqlite.coffee')).requestNames ? [] catch then []
          return _sendJson res, 200, {ok: true, manifest: {
            base: (opts.basePath ? opts.baseDir)
            exec: opts.execDir
            cwd: cwd
            active_pipe: _workspacePipeName(cwd)
            recipes: {available: recipeNames, by_name: byName}
            sqlite_requests: sqliteRequests
            includes_expanded: false
          }}
        # /api/memo — the browser routes sys/* (and non-ui/*) here. Backed by the ONE
        # shared memo M; sys/* is now in-process (rule above), so JSON-faithful. (3.4)
        if pathname is '/api/memo'
          prefix = String((try (new URL(String(req.url ? ''), 'http://127.0.0.1')).searchParams.get('prefix') catch then '') ? '')
          return _sendJson res, 200, {entries: ({key: k, value: e.value, version: null} for own k, e of M.MM when e.value isnt undefined and k.indexOf(prefix) is 0)}
        if pathname.indexOf('/api/memo/') is 0
          key = decodeURIComponent pathname.slice('/api/memo/'.length)
          return _sendJson(res, 400, {ok: false, error: 'key required'}) unless key.length
          if req.method is 'POST'
            body = await _readBody req
            p = try JSON.parse(body or '{}') catch then {}
            value = if p? and typeof p is 'object' and p.hasOwnProperty('value') then p.value else p
            M.saveThis key, value
            return _sendJson res, 200, {ok: true, key, value, version: null}
          if req.method is 'DELETE'
            existed = (M.ui.get(key) isnt undefined) or M.MM[key]?
            M.ui.del key
            return _sendJson res, (if existed then 200 else 404), {ok: existed, key}
          val = M.theLowdown(key)?.value
          return _sendJson(res, 404, {ok: false, error: 'not found'}) if val is undefined
          return _sendJson res, 200, {value: val, version: null, updated_at: null, updated_by: null}
        # static UI assets — the real page shell (batch 3.1)
        if pathname is '/' or pathname is '/index.html'
          return _sendFile res, _resolveUiAsset('index.html'), 'text/html; charset=utf-8'
        if pathname.indexOf('/ui/') is 0
          return _sendFile res, _resolveUiAsset(pathname.slice('/ui/'.length)), _ctype(pathname)
        _sendJson res, 404, {ok: false, error: 'not found'}
      catch err
        try _sendJson res, 500, {ok: false, error: String(err?.message ? err)} catch then null
    srv.listen port, host, -> try serveOpts.onListen?(port, host)
    srv

  M.ui
