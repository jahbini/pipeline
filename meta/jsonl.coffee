###
        meta/jsonl.coffee  —  JSON Lines (one object per line)
        =====================================================

  JSONL is the canonical wire format for "a stream of records" —
  used heavily by MLX training data, log shipping, and UI event
  streams. The value side of this meta device is always a
  **JavaScript array of objects**; on write each row is serialized
  to its own line.

  **Write semantics:** the destination file is truncated first,
  then each row is appended. The two-phase write (truncate then
  append) lets the implementation match how log shippers would
  themselves write the file, but it means a crash mid-write
  produces a half-empty file. Callers that need atomic JSONL
  should `make` the array into a `.json` key first and rename.

  Malformed rows on read are silently skipped — JSONL files are
  routinely concatenated and a partial last line is normal.
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
    readJSONL = (p) ->
      raw = readText(p); return undefined unless raw?
      out=[]
      for l in raw.split(/\r?\n/) when l.trim().length
        try out.push JSON.parse(l) catch then continue
      out
    # Reads: CWD → project BASE → runner EXEC. Writes: CWD only.
    resolveReadPath = (key) ->
      dest = path.join(baseDir, key)
      return dest if fs.existsSync(dest)
      viaBase = path.join(basePath, key)
      return viaBase if fs.existsSync(viaBase)
      viaExec = path.join(execDir, key)
      return viaExec if fs.existsSync(viaExec)
      dest

    M.addMetaRule "jsonl",
      /\.jsonl$/i,
      (key, value) ->
        if value is undefined
          return readJSONL(resolveReadPath(key))
        dest = path.join(baseDir, key)
        fs.mkdirSync(path.dirname(dest),{recursive:true})
        fs.writeFileSync(dest,'','utf8')
        for t in value
          fs.appendFileSync(dest, JSON.stringify(t)+"\n",'utf8')
        value
