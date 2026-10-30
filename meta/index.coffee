###
            meta/index.coffee  —  the meta-device loader
            =====================================================

  A **meta device** is a function `(memo, opts) -> ...` that calls
  `memo.addMetaRule(name, regex, handler)` to teach the `Memo` what
  to do when a key matching `regex` is read or written. Every file
  in this directory exports one such function; `index.coffee`
  discovers them, sorts them, and invokes them in order.

  **Ordering is load-bearing.** `Memo::selectMetaHandler` returns
  the **first** rule whose regex matches a given key. That means:

  - `sqlite.coffee` is loaded **first** (see the sort callback
    below) so its compound `^(?:storyByID\{...\}|...)$` regex gets
    first crack at structured request keys. If it lost the race to
    a broader rule (e.g. `slash.coffee`), sqlite keys would be
    treated as file paths and silently corrupt.
  - The rest are loaded alphabetically. `slash.coffee` deliberately
    sorts last; it is the catch-all for "path-shaped key with no
    extension" and must lose to every more-specific rule.

  When the runner becomes an npm module, a project will be able to
  drop additional meta devices into a `meta/` directory alongside
  `experiment.yaml`. The loader will then walk both the shipped
  `EXEC/meta/` and the project `CWD/meta/`, with project devices
  winning on conflict.

  Failed devices are logged but do not abort load — a broken
  `sqlite.coffee` shouldn't prevent the runner from using `yaml`
  and `json`.
###

fs   = require 'fs'
path = require 'path'

module.exports = (M, opts = {}) ->
  baseDir = __dirname

  # Load order:
  #   1. sqlite.coffee  — compound request-key rules; must win against
  #                        broader filename-shape rules.
  #   2. pid_reap.coffee — narrow state-file rule; must win against
  #                        the plain .json catch-all so reaped reads
  #                        of state/ui-run.json and state/step-*.json
  #                        reach the reap handler.
  #   rest alphabetical, with slash.coffee (naked path) last by its
  #   own convention.
  priority = (name) ->
    return 0 if name is 'sqlite.coffee'
    return 1 if name is 'pid_reap.coffee'
    # ui.coffee must beat slash.coffee: `ui/intent/x` is a naked path that
    # slash's permissive catch-all would otherwise claim as a file. (2026-10-28)
    return 2 if name is 'ui.coffee'
    3
  files = fs.readdirSync(baseDir)
    .filter (f) ->
      f.endsWith('.coffee') and f isnt 'index.coffee'
    .sort (a, b) ->
      pa = priority(a); pb = priority(b)
      return pa - pb if pa isnt pb
      a.localeCompare b

  for f in files
    modPath = path.join(baseDir, f)
    try
      device = require(modPath)
      if typeof device is 'function'
        device(M, opts)
        console.log "🔌 meta device loaded:", f
      else
        console.warn "⚠️ meta device skipped (not a function):", f
    catch e
      console.error "❌ meta device failed:", f, e.message
