###
        meta/json.coffee  —  JSON files as Memo keys
        =====================================================

  The JSON twin of `yaml.coffee`. `value is undefined` → read;
  otherwise → write `JSON.stringify(value, null, 2)`. No EXEC
  fallback — JSON state is always project-owned.

  Reads return `undefined` (not `null`) on a missing file, so a
  caller that wants to distinguish "file absent" from "JSON null"
  can.
###
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
    baseDir  = opts.baseDir  ? process.cwd()
    basePath = opts.basePath ? process.env.BASE ? baseDir
    execDir  = opts.execDir  ? process.env.EXEC ? baseDir
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')
    # Reads: CWD → project BASE → runner EXEC. Writes: CWD only.
    resolveReadPath = (key) ->
      dest = path.join(baseDir, key)
      return dest if fs.existsSync(dest)
      viaBase = path.join(basePath, key)
      return viaBase if fs.existsSync(viaBase)
      viaExec = path.join(execDir, key)
      return viaExec if fs.existsSync(viaExec)
      dest

    M.addMetaRule "json",
      /\.json$/i,
      (key, value) ->
        if value is undefined
          return readJSON(resolveReadPath(key))
        dest = path.join(baseDir, key)
        writeText(dest, JSON.stringify(value,null,2))
        value

