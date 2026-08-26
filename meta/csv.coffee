###
        meta/csv.coffee  —  CSV files (single-row writes)
        =====================================================

  **Asymmetric on purpose.**

  - Read returns an **array of objects**, one per row, keyed by
    the header row. Used by the test pipeline to verify a step
    produced a tabular summary.
  - Write accepts a **single object**, emits one header line and
    one data line. The asymmetry is because the original use case
    was "the runner makes one summary row per pipeline run"; if
    you need multi-row writes, accumulate the objects yourself
    and use `.jsonl` instead — or extend this device.

  CSV escaping is minimal: only fields containing `,`, `"`, or
  newline get quoted. No locale awareness, no BOM. The teaching
  example, not the production CSV writer.
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

    parseCSV = (text) ->
      lines = text.trim().split /\r?\n/
      return [] unless lines.length

      headers = lines.shift().split ','

      rows = []
      for line in lines
        cols = line.split ','
        obj = {}
        for h, i in headers
          obj[h] = cols[i] ? ''
        rows.push obj

      rows

    stringifyCSV = (obj) ->
      unless obj? and typeof obj is 'object' and not Array.isArray obj
        throw new Error "stringifyCSV expects a single object"

      keys   = Object.keys obj
      values = keys.map (k) ->
        v = obj[k] ? ''
        s = String v
        if /[",\n]/.test s
          '"' + s.replace(/"/g, '""') + '"'
        else
          s

      [
        keys.join ','
        values.join ','
      ].join "\n"

    M.addMetaRule "csv",
      /\.csv$/,
      (key, value) ->
        if value is undefined
          src = resolveReadPath(key)
          return undefined unless fs.existsSync src
          return parseCSV fs.readFileSync(src,'utf8')

        dest = path.join baseDir, key
        fs.mkdirSync path.dirname(dest), { recursive: true }
        fs.writeFileSync dest, stringifyCSV(value)
        value

