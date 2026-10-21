#!/usr/bin/env coffee
# switchboard.coffee — standalone per-host broker + memo daemon.
#
# The broker used to live inside the pipeline_runner, so the memo kv
# store and the SSE seam only existed while a pipeline happened to be
# running (UI_MEMO.md "Broker placement"). This daemon makes the broker
# RESIDENT: launchd keeps it up, so `ui/*` memo keys, retained run
# state, and the ui_server's /api/events stream work at idle — the
# memo-based UI no longer depends on a runner being alive.
#
# It owns:
#   - the Broker (pub/sub + RPC routing + retained messages)
#   - the Memo sqlite (single writer → coherent versions/CAS/history)
# on the same unix socket the runner/ui_server already use. The runner
# (see wire.coffee) now attaches as a CLIENT when this daemon is up, and
# falls back to hosting its own broker only when it isn't.
#
# Env: RUNNER_SOCK overrides the socket path, MEMO_DB the sqlite path
# (both default to ~/pipeline/state/*). Loopback/unix-socket only — the
# trust boundary is the host.

{Broker} = require './broker'
{Memo}   = require './memo'

SOCK = process.env.RUNNER_SOCK ? "#{process.env.HOME}/pipeline/state/runner.sock"
MEMO = process.env.MEMO_DB    ? "#{process.env.HOME}/pipeline/state/memo.sqlite"

broker = new Broker(SOCK)
memo   = null

broker.on 'listening', (p) ->
  try
    memo = new Memo MEMO, broker
    memo.installHandlers()
    n = memo.rehydrate()
    console.log "[switchboard] up at #{p}; memo #{MEMO} rehydrated #{n} key(s)"
  catch err
    console.error "[switchboard] memo init failed: #{err?.message ? err}"

broker.on 'error', (err) ->
  console.error "[switchboard] broker error: #{err?.message ? err}"

broker.on 'dispatch_error', (err) ->
  console.error "[switchboard] dispatch error: #{err?.message ? err}"

shutdown = (sig) ->
  console.log "[switchboard] #{sig} — closing"
  try memo?.close()
  try broker.close()
  process.exit 0

process.on 'SIGTERM', -> shutdown 'SIGTERM'
process.on 'SIGINT',  -> shutdown 'SIGINT'

broker.listen()
