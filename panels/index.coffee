###
  panels/index.coffee  —  UI-panel registry loader
  ================================================

  Mirrors the shape of `meta/index.coffee`, but with three-tier
  resolution (CWD ↠ BASE ↠ EXEC) instead of a single directory.
  A panel is a file exporting `{title, render_hint, endpoint,
  applies?, column?, eager?, poll_seconds?}` — see
  `GPT/ui/panels.md` for the full contract.

  **Resolution tiers (BASE ↠ EXEC only; no CWD tier).** Per-pipe UI
  variation isn't a real requirement — all pipes in a project share
  one UI — so restricting to two tiers keeps the mental model tight.
  A pipe that needed a truly bespoke view would be a separate
  project.

  Usage from an `ui_server.coffee`:

    { load } = require '@jahbini/pipeline/panels'
    registry = load { CWD, BASE, EXEC, helpers }
    # registry.list()                    → [{name, title, render_hint, column}, …]
    # registry.get(name)                 → the panel export, or null
    # registry.data(name, ctxExtras)     → await endpoint result, or null
    # registry.eager(ctxExtras)          → {name: data, …} for panels
    #                                       with `eager: true`

  The loader is idempotent and location-anonymous — it does not care
  where it lives on disk, only what CWD/BASE/EXEC point at.
###

fs   = require 'fs'
path = require 'path'

# Framework-shipped panels live next to this file, so EXEC always
# resolves to __dirname's parent. But callers can override — this
# is what lets writer's UI use a different EXEC in dev.
DEFAULT_EXEC = path.resolve __dirname, '..'

# Walk one tier and collect {name → resolvedPath}. Ignores index.coffee
# (that's us) and non-.coffee files.
scanTier = (dir) ->
  return {} unless dir? and typeof dir is 'string' and dir.length
  return {} unless fs.existsSync(dir) and fs.statSync(dir).isDirectory()
  panelsDir = path.join(dir, 'panels')
  return {} unless fs.existsSync(panelsDir) and fs.statSync(panelsDir).isDirectory()
  out = {}
  for f in fs.readdirSync(panelsDir)
    continue unless f.endsWith('.coffee')
    continue if f is 'index.coffee'
    name = f.slice(0, -'.coffee'.length)
    out[name] = path.join(panelsDir, f)
  out

# Merge tiers BASE ↠ EXEC (BASE wins). CWD tier is intentionally
# absent — 2026-09-09 design decision: per-pipe UI overrides aren't
# a real requirement; all pipes in a project share one UI. Simpler
# mental model.
resolveTiers = ({BASE, EXEC}) ->
  execTier = scanTier(EXEC ? DEFAULT_EXEC)
  baseTier = scanTier(BASE)
  resolved = {}
  for name, p of execTier
    resolved[name] = {path: p, tier: 'EXEC'}
  for name, p of baseTier
    resolved[name] = {path: p, tier: 'BASE'}
  resolved

# Load a panel module and normalize its export shape. Failed loads
# are logged but do not abort — one broken panel shouldn't take the
# whole UI down.
loadPanel = (name, filePath) ->
  try
    mod = require filePath
    panel = mod.panel ? mod
    return null unless panel? and typeof panel is 'object'
    return null unless typeof panel.endpoint is 'function'
    {
      name
      title:         String(panel.title ? name)
      render_hint:   String(panel.render_hint ? 'text')
      column:        String(panel.column ? 'left')
      eager:         panel.eager is true
      poll_seconds:  Number(panel.poll_seconds ? 5)
      applies:       if typeof panel.applies is 'function' then panel.applies else null
      endpoint:      panel.endpoint
      _path:         filePath
    }
  catch err
    console.error "[panels] failed to load #{name} (#{filePath}): #{String(err?.message ? err)}"
    null

# Build the {name: fn} registry. `applies` gates inclusion; `helpers`
# is folded into every ctx so panels don't each re-implement listFiles
# etc.
exports.load = ({CWD, BASE, EXEC, helpers}) ->
  helpers ?= {}
  # CWD accepted only to fold into the panel's per-invocation ctx —
  # it is NOT scanned for panels. Panels live at BASE or EXEC only.
  tiers = resolveTiers {BASE, EXEC}
  panels = {}
  for name, {path: filePath, tier} of tiers
    loaded = loadPanel name, filePath
    continue unless loaded?
    ctxProbe = {CWD, BASE, EXEC, fs, path, helpers}
    if loaded.applies?
      try
        continue unless loaded.applies(ctxProbe)
      catch err
        console.error "[panels] applies() threw for #{name}: #{String(err?.message ? err)}"
        continue
    loaded.tier = tier
    panels[name] = loaded

  registry =
    list: ->
      for name, p of panels
        {name, title: p.title, render_hint: p.render_hint, column: p.column,
         eager: p.eager, poll_seconds: p.poll_seconds, tier: p.tier}

    get: (name) -> panels[name] ? null

    data: (name, ctxExtras = {}) ->
      p = panels[name]
      return null unless p?
      ctx = Object.assign {CWD, BASE, EXEC, fs, path, helpers}, ctxExtras
      try
        await Promise.resolve(p.endpoint(ctx))
      catch err
        console.error "[panels] #{name}.endpoint threw: #{String(err?.message ? err)}"
        null

    eager: (ctxExtras = {}) ->
      out = {}
      for name, p of panels when p.eager
        out[name] = await registry.data(name, ctxExtras)
      out

    # For audit — the resolution table. UI-server can dump this to
    # params/_panels.yaml at boot so a human sees which tier won.
    resolution: ->
      for name, p of panels
        {name, tier: p.tier, path: p._path}

  registry
