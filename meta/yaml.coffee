# meta/yaml.coffee
fs   = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    readJSON = (p) -> try JSON.parse(readText(p)) catch then undefined
    readText = (p) -> if fs.existsSync(p) then fs.readFileSync(p,'utf8') else undefined
    writeText = (p,s) -> fs.mkdirSync(path.dirname(p),{recursive:true}); fs.writeFileSync(p,s,'utf8')

    # ---- JSON ----
    M.addMetaRule "yaml",
      /\.yaml$/i,
      (key, value) ->
        dest = path.join(baseDir, key)
        if value is undefined
          return yaml.load readText dest 
        writeText dest, yaml.dump value
        value

