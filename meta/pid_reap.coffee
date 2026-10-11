###
        meta/pid_reap.coffee  —  reap-on-read for pid-tagged state
        ===============================================================

  State files written by the runner carry a `pid` (ui-run.json) or
  `pid` on each step state (step-<name>.json). The runner's clean-
  exit handler flips `status: 'running'` → `'died'`, but SIGKILL /
  OOM / power-loss bypass it, leaving the files lying about aliveness.

  This device teaches the Memo to reconcile that lie on EVERY read:

    - matches `state/ui-run.json` and `state/step-*.json`
    - on read: load the JSON; if the recorded pid is dead but
      `status` is one of {launching, running, skipped, killing},
      flip `status: 'died'`, stamp `exit_detected_at`, write the
      correction back to disk, return the corrected object.
    - on write: pass through to the plain JSON writer.

  Because this rule sits in `meta/`, every reader that goes through
  the Memo — pipeline_runner steps, UI panels, agent surface — gets
  the reconciled view automatically. There is no "reap in two
  places" problem; the logic lives here once.

  Ordering: this rule must beat `json.coffee` for its matching keys.
  `meta/index.coffee` sorts by filename after sqlite; `pid_reap`
  sorts before `json` alphabetically ('j' < 'p' is FALSE — 'j'
  comes first, so plain-json wins by default). To avoid the race,
  we also expose `reapOnDisk(stateDir)` as a plain function the
  ui_server can call directly from `buildStatus()` — same code
  path either way.

  Export shape:
    module.exports = (M, opts) ->   # meta-device loader (same shape as json.coffee)
      M.addMetaRule 'pid_reap', <regex>, <handler>
    module.exports.reapOnDisk = (stateDir) -> …
###
fs   = require 'fs'
path = require 'path'

ALIVE_STATUSES = ['launching', 'running', 'skipped', 'killing']

isProcessAlive = (pid) ->
  num = Number(pid)
  return false unless Number.isFinite(num) and num > 0
  try
    process.kill num, 0
    true
  catch
    false

# Core: given a parsed state object + path on disk, flip status to
# 'died' and persist if the file is lying. Returns the (possibly
# corrected) object. Idempotent — a non-lying file is untouched.
reapObject = (obj, filePath) ->
  return obj unless obj? and typeof obj is 'object'
  return obj unless obj.status in ALIVE_STATUSES
  pid = Number(obj.pid ? 0)
  return obj unless pid > 0
  return obj if isProcessAlive(pid)
  nowIso = new Date().toISOString()
  corrected = Object.assign {}, obj,
    status:           'died'
    done:             false
    exit_detected_at: obj.exit_detected_at ? nowIso
    finished_at:      obj.finished_at      ? nowIso
    reason:           obj.reason           ? "pid #{pid} dead at read time"
  if filePath
    try fs.writeFileSync filePath, JSON.stringify(corrected, null, 2), 'utf8'
    catch
      null
  corrected

# Walk every state/*.json under `stateDir` and reap in place. Called
# by ui_server.buildStatus so direct fs readers see fresh data too.
reapOnDisk = (stateDir) ->
  return unless stateDir and fs.existsSync(stateDir)
  try names = fs.readdirSync(stateDir)
  catch then return
  for name in names when (name is 'ui-run.json') or /^step-.*\.json$/.test(name)
    p = path.join(stateDir, name)
    try obj = JSON.parse fs.readFileSync(p, 'utf8')
    catch then continue
    reapObject obj, p
  return

# Meta-device entry point. Registered FIRST (ahead of json.coffee)
# by sorting pid_reap.coffee ahead of json.coffee in meta/index's
# loader — see the explanatory note at the top. The rule returns
# the reaped object on read; writes delegate to plain JSON stringify.
loader = (M, opts = {}) ->
  baseDir = opts.baseDir ? process.cwd()
  M.addMetaRule 'pid_reap',
    # Matches state/ui-run.json AND state/step-*.json (no deeper paths).
    /^state\/(ui-run|step-[^\/]+)\.json$/,
    (key, value) ->
      filePath = path.join(baseDir, key)
      if value is undefined
        obj = null
        try obj = JSON.parse fs.readFileSync(filePath, 'utf8')
        catch
          return undefined
        return reapObject obj, filePath
      # Write path: plain JSON mirror. The runner may legitimately
      # write a 'running' status; don't reap on write.
      fs.mkdirSync path.dirname(filePath), { recursive: true }
      fs.writeFileSync filePath, JSON.stringify(value, null, 2), 'utf8'
      value

module.exports = loader
module.exports.reapOnDisk  = reapOnDisk
module.exports.reapObject  = reapObject
module.exports.isProcessAlive = isProcessAlive
