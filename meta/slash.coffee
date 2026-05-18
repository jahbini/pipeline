###
        meta/slash.coffee  —  catch-all for path-shaped keys
        =====================================================

  **The fallback.** Any key that:

  - contains at least one `/` (so it looks like a path), **and**
  - does **not** end in a file extension (no `.json`, `.yaml`, …)

  …falls into this handler. Read returns the file contents as text;
  write accepts a Buffer (written raw) or any other value (written
  as `JSON.stringify(value, null, 2)`).

  **Loaded last.** This regex is intentionally permissive, so it
  must lose to every more-specific rule. The sort callback in
  `index.coffee` enforces "sqlite first, everything else alpha,
  slash last" — slash sorts after json/jsonl/txt/yaml naturally.
  Do not add a rule with a regex broader than this one.
###
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')


    M.addMetaRule "slash",
      /^(?=.*\/)(?!.*\.[A-Za-z0-9]{1,8}$).+$/,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return readText(dest)
        fs.mkdirSync(path.dirname(dest),{recursive:true})
        data = if Buffer.isBuffer(value) then value else JSON.stringify(value,null,2)
        fs.writeFileSync(dest,data)
        value

