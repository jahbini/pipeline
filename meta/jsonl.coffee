# meta/jsonl.coffee
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')
    readJSONL = (p) ->
      raw = readText(p); return undefined unless raw?
      out=[]
      for l in raw.split(/\r?\n/) when l.trim().length
        try out.push JSON.parse(l) catch then continue
      out

    # ---- JSONL ----
    M.addMetaRule "jsonl",
      /\.jsonl$/i,
      (key, value) ->
        dest = path.join(baseDir, key)
        if ! value
          return readJSONL(dest)
        fs.mkdirSync(path.dirname(dest),{recursive:true})
        fs.writeFileSync(dest,'','utf8')
        for t in value
          fs.appendFileSync(dest, JSON.stringify(t)+"\n",'utf8')
        value
