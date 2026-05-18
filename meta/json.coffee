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
    baseDir = opts.baseDir ? process.cwd()
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')

    M.addMetaRule "json",
      /\.json$/i,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return readJSON(dest)
        writeText(dest, JSON.stringify(value,null,2))
        value

