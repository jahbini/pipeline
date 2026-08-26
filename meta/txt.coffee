###
        meta/txt.coffee  —  plain text and Markdown
        =====================================================

  Matches both `.txt` and `.md`. Read returns the file contents
  verbatim; write accepts either a string or an array of strings.
  Arrays are joined with `\n` — handy for "build a paragraph from
  lines" without the caller threading the newline themselves.

  No structured projection: a non-string non-array value will be
  stringified with `String(value ? '')`, which is rarely what you
  want. Use `.json` or `.yaml` for structured data.
###
fs   = require 'fs'
path = require 'path'

module.exports = (M, opts={}) ->
    baseDir  = opts.baseDir  ? process.cwd()
    basePath = opts.basePath ? process.env.BASE ? baseDir
    execDir  = opts.execDir  ? process.env.EXEC ? baseDir
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

    M.addMetaRule "txt",
      /\.(txt|md)$/i,
      (key, value) ->
        if value is undefined
          return readText(resolveReadPath(key))

        text =
          if Array.isArray(value)
            value.join('\n')
          else
            String(value ? '')

        writeText(path.join(baseDir, key), text)
        value
