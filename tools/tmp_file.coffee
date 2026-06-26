###
  tmp_file.coffee  —  tool (S.tools.tmp_file)
  =====================================================
  Reached from step scripts as:
      S.tools.tmp_file.<entrypoint>(args...)

  Tool contract (see GPT/CONVENTIONS.md § "Tools"):
    - stateless: no module-level mutables, no warm-up
    - takes ordinary args; receives no runner-injected objects
    - may do filesystem I/O — `remove` unlinks a file; the tool
      remembers nothing between calls
    - never a recipe step

  Why this exists:
    Two step scripts (oracle_ask_sqlite, voice_similarity_ite) ask
    MLX `cache_prompt` to write a K/V safetensors file into the OS
    tmp dir, read it back through `cache_embedding`, then unlink it.
    Each was building its own path with
    `path.join os.tmpdir(), "..._#{pid}_#{...}.safetensors"` and
    catching its own unlink errors. Folding into one tool lets both
    steps drop their `path` / `os` / `fs` requires.

  The lifecycle deliberately stays in the step's hands (not the
  cache_embedding tool's): in the oracle case the same temp file is
  consumed twice — once by cache_embedding for the embedding, once
  by `mlx_lm generate --prompt-cache-file` to continue from the
  cached prompt. The step is the only place that knows when both
  reads are done. So this tool only mints the path and removes the
  file; the step decides the timing.

  `make` does NOT create the file. It returns a path string that the
  caller (typically `S.callMLX 'cache_prompt'`) is expected to write
  into. This matches the existing semantics of the call sites being
  migrated.
###
fs = require 'fs'
os = require 'os'
path = require 'path'

# Mint an absolute temp-file path. The path is unique to this process
# and call (pid + monotonic counter + Date.now()). The file is NOT
# created; caller writes it.
#   prefix : short identifier baked into the basename for log readability
#            (e.g. "oracle_cache", "voice_eval")
#   ext    : extension WITHOUT the leading dot (e.g. "safetensors")
#            defaults to "tmp"
counter = 0
make = (prefix, ext = 'tmp') ->
  pfx = String(prefix ? 'tmp_file').replace(/[^A-Za-z0-9_-]+/g, '_')
  e   = String(ext).replace(/^\.+/, '').replace(/[^A-Za-z0-9_-]+/g, '_')
  e   = 'tmp' unless e.length
  counter += 1
  name = "#{pfx}_#{process.pid}_#{Date.now()}_#{counter}.#{e}"
  path.join os.tmpdir(), name

# Best-effort unlink. Returns true if the file was removed, false on
# any error (most commonly: file doesn't exist because MLX never
# produced it, or the process died before make/write completed).
# Stragglers in tmpdir are harmless — the OS reaps them periodically.
remove = (filepath) ->
  return false unless filepath?
  try
    fs.unlinkSync filepath
    true
  catch
    false

# `counter` lives at module scope but it's a *monotonic id*, not data
# that survives across runs (the module is loaded per-step via the
# proxy, and the runner clears require cache between loads — but even
# if it didn't, `pid + Date.now() + counter` is unique per call within
# a process and that's all `make` guarantees). The tool contract bans
# state that affects *observable behavior* between calls; an id-counter
# whose only purpose is uniqueness in the filename is not that kind of
# state. (Documenting this explicitly so a future reader doesn't flag
# it as a contract violation.)

module.exports = {
  make
  remove
}
