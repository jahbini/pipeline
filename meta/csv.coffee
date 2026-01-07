# meta/csv.coffee
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')

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
        dest = path.join baseDir, key

        if value is undefined
          return undefined unless fs.existsSync dest
          return parseCSV fs.readFileSync(dest,'utf8')

        fs.mkdirSync path.dirname(dest), { recursive: true }
        fs.writeFileSync dest, stringifyCSV(value)
        value

