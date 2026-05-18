###
        meta/yaml.coffee  —  YAML files as Memo keys
        =====================================================

  The canonical meta device. Any Memo key ending in `.yaml`
  transparently becomes "read this YAML file" on get and "write
  this object as YAML" on set.

  **EXEC/CWD fallback for reads.** Unlike json/jsonl/txt, the
  yaml device falls back to `<EXEC>/<key>` if `<CWD>/<key>` is
  missing — this is what makes shipped recipes like
  `config/base_ite.yaml` readable from any project directory.
  Writes always go to `<CWD>/<key>` so the project never modifies
  the runner's installed files.

  This file is the smallest complete example of a meta device —
  read it once and you understand the pattern every other device
  in this directory follows.
###
fs   = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    execDir = process.env.EXEC ? baseDir
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    resolveReadPath = (key) ->
      dest = path.join(baseDir, key)
      return dest if fs.existsSync(dest)
      fallback = path.join(execDir, key)
      return fallback if fs.existsSync(fallback)
      dest
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')

    # `value is undefined` → read; otherwise → write. Reads use the
    # EXEC/CWD fallback above; writes always land in the project.
    M.addMetaRule "yaml",
      /\.yaml$/i,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return yaml.load readText(resolveReadPath(key))
        writeText dest, yaml.dump value
        value
