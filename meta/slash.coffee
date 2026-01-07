# meta/slash.coffee
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

