os   = require 'os'
path = require 'path'
{EventEmitter} = require 'events'
{BrokerClient} = require './broker_client'

# Thin UI-side cache fed by the runner's broker. Subscribes to the
# retained state/step/event topics so /api/status can serve from
# memory instead of re-reading 8+ JSON files per request. If the
# broker is unreachable (older runner, local-only mode), the cache
# stays empty and callers fall back to disk — behaviour-preserving.

# Default unix socket. Override via RUNNER_SOCK — lets a scratch broker
# be addressed for testing, and gives the future MARRIAGE switchboard a
# configurable endpoint. Production leaves it unset → the path below.
DEFAULT_SOCK = process.env.RUNNER_SOCK ? "#{process.env.HOME}/pipeline/state/runner.sock"

class StatusSource extends EventEmitter
  constructor: (opts={}) ->
    super()
    # The SSE endpoint (GET /api/events) attaches ~5 listeners per open
    # browser connection (run/step/event/lifecycle/memo). With a handful
    # of tabs that trips Node's default 10-listener leak warning, which
    # would be a false alarm — Stage 3 removes every listener on req
    # close and its verify asserts the count returns to baseline. Lift
    # the ceiling so genuine leaks still show (they'd climb without
    # bound) but normal fan-out is quiet.
    @setMaxListeners 200
    @sockPath   = opts.sockPath ? DEFAULT_SOCK
    @client     = null
    @connected  = false
    @ready      = false     # saw at least one retained state message
    @run        = null      # last ui-run payload
    @steps      = new Map() # stepName -> step state payload
    @events     = []        # ring buffer
    @eventsMax  = 200
    @lifecycle  = null
    @filterHost = opts.host ? null
    @filterPipe = opts.pipe ? null

  start: ->
    try
      @client = new BrokerClient @sockPath, "ui-#{process.pid}", 'ui-pipeline'
    catch err
      return false
    @client.on 'connect', => @connected = true
    @client.on 'close',   =>
      @connected = false
      # Socket close is the authoritative "runner down" signal. The
      # runner's 'exited' lifecycle publish fires in process.on('exit')
      # where async socket writes rarely flush, so it usually never
      # arrives — never trust lifecycle.phase alone for liveness.
      @lifecycle = Object.assign {}, (@lifecycle ? {}), {phase: 'disconnected', at: new Date().toISOString()}
      @emit 'lifecycle', @lifecycle
    @client.subscribe 'runner/+/+/state',       (topic, payload) => @_onState topic, payload
    @client.subscribe 'runner/+/+/step/+',      (topic, payload) => @_onStep  topic, payload
    @client.subscribe 'runner/+/+/event',       (topic, payload) => @_onEvent topic, payload
    @client.subscribe 'runner/+/+/lifecycle',   (topic, payload) =>
      @lifecycle = payload
      @emit 'lifecycle', payload
    # memo/# carries every reactive memo key the browser binds to. A
    # null payload is a retained-clear/deletion — forward it as-is so
    # downstream SSE clients can drop the key. (Unlike run/step/event
    # this is intentionally unfiltered: memo keys are host-local, not
    # pipe-scoped.)
    @client.subscribe 'memo/#', (topic, payload) =>
      @emit 'memo', {key: topic.replace(/^memo\//, ''), payload}
    @client.connect().catch (err) ->
      console.error "[ipc] status_source connect: #{err?.message ? err}" if process.env.IPC_DEBUG
    true

  _topicMatchesFilter: (parts) ->
    return true unless @filterHost or @filterPipe
    return false if @filterHost and parts[1] isnt @filterHost
    return false if @filterPipe and parts[2] isnt @filterPipe
    true

  _onState: (topic, payload) ->
    parts = topic.split '/'
    return unless @_topicMatchesFilter parts
    @run = payload
    @ready = true
    @emit 'run', payload

  _onStep: (topic, payload) ->
    parts = topic.split '/'
    return unless @_topicMatchesFilter parts
    name = parts[4]
    return unless name
    # Emit for every step subtopic, INCLUDING step/current, before the
    # current early-return below — the browser wants the live-step push
    # even though 'current' is deliberately not cached in @steps.
    @emit 'step', payload
    if name is 'current' then return
    if payload is null then @steps.delete name
    else @steps.set name, payload

  _onEvent: (topic, payload) ->
    parts = topic.split '/'
    return unless @_topicMatchesFilter parts
    @events.push payload
    @events.splice 0, @events.length - @eventsMax if @events.length > @eventsMax
    @emit 'event', payload

  isLive: -> @connected and @ready

  getRun: -> if @isLive() then @run else null

  getSteps: ->
    return null unless @isLive()
    rows = Array.from @steps.values()
    rows.sort (a, b) -> String(a.step ? '').localeCompare String(b.step ? '')
    rows

  getEvents: (max=80) ->
    return null unless @isLive()
    @events.slice Math.max(@events.length - max, 0)

  memoRequest: (op, args={}) ->
    return Promise.reject(new Error 'not_connected') unless @connected
    host = @filterHost ? '+'
    pipe = @filterPipe ? '+'
    @client.request "runner/#{host}/#{pipe}/meta/sqlite/req", Object.assign({op}, args)

module.exports = {StatusSource}
