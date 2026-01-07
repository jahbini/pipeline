# EXEC/meta/index.coffee
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts = {}) ->
  baseDir = __dirname

  files = fs.readdirSync(baseDir)
    .filter (f) ->
      f.endsWith('.coffee') and f isnt 'index.coffee'

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
