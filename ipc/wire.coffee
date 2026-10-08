os   = require 'os'
path = require 'path'
{Broker} = require './broker'
{Memo}   = require './memo'

# Additive wiring: starts the in-process broker + memo for the runner
# and installs publish-after-write hooks on StepStateStore (S) and the
# ui recorder (U). Disk writes are unchanged — publishes fire AFTER
# the existing fs.writeFileSync returns, so a crash-mid-write still
# leaves disk authoritative.

DEFAULT_SOCK = "#{process.env.HOME}/pipeline/state/runner.sock"
DEFAULT_MEMO = "#{process.env.HOME}/pipeline/state/memo.sqlite"

derivePipe = (cwd) ->
  # Common layout: .../pipes/<pipe>/<run-dir>. Fall back to basename of CWD.
  parts = cwd.split path.sep
  i = parts.lastIndexOf 'pipes'
  return parts[i+1] if i >= 0 and parts[i+1]
  path.basename cwd

wireRunner = (S, U, opts={}) ->
  host = opts.host ? os.hostname().split('.')[0]
  pipe = opts.pipe ? derivePipe (opts.cwd ? process.cwd())
  base = "runner/#{host}/#{pipe}"

  broker = null
  memo   = null
  try
    broker = new Broker(opts.sockPath ? DEFAULT_SOCK).listen()
  catch err
    console.error "[ipc] broker failed to listen: #{err?.message ? err}"
    return {broker:null, memo:null, host, pipe}

  try
    memo = new Memo (opts.memoPath ? DEFAULT_MEMO), broker
    memo.installHandlers()
    nRehydrated = memo.rehydrate()
    console.log "[ipc] broker up at #{opts.sockPath ? DEFAULT_SOCK}; memo rehydrated #{nRehydrated} keys"
  catch err
    console.error "[ipc] memo init failed: #{err?.message ? err}"

  safePub = (topic, payload, retain=true) ->
    try broker.publish topic, payload, retain:retain
    catch err then console.error "[ipc] publish #{topic} failed: #{err?.message ? err}"

  # Advertise lifecycle immediately so late-joining UIs see us.
  safePub "#{base}/lifecycle", {phase:'running', pid:process.pid, host, pipe, since:new Date().toISOString()}, true

  # ── Patch StepStateStore.write ───────────────────────────
  origWrite = S.write.bind(S)
  S.write = (n, obj) ->
    payload = origWrite n, obj
    safePub "#{base}/step/#{n}", payload, true
    safePub "#{base}/step/current", {step:n, status:payload.status, done:payload.done, at:payload.updated_at}, true
    payload

  origDelete = S.delete.bind(S)
  S.delete = (n) ->
    ok = origDelete n
    safePub "#{base}/step/#{n}", null, true if ok
    ok

  # ── Patch ui recorder ────────────────────────────────────
  if U
    origSaveRun = U.saveRun.bind(U)
    U.saveRun = (payload) ->
      row = origSaveRun payload
      safePub "#{base}/state", row, true
      row

    origEvent = U.event.bind(U)
    U.event = (payload) ->
      row = origEvent payload
      safePub "#{base}/event", row, false
      row

  cleanup = ->
    safePub "#{base}/lifecycle", {phase:'exited', pid:process.pid, host, pipe, at:new Date().toISOString()}, true
    try memo?.close()
    try broker?.close()

  process.on 'exit', -> try cleanup()

  {broker, memo, host, pipe, base}

module.exports = {wireRunner}
