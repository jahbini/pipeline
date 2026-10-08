os   = require 'os'
path = require 'path'
{BrokerClient} = require './broker_client'

# Thin UI-side cache fed by the runner's broker. Subscribes to the
# retained state/step/event topics so /api/status can serve from
# memory instead of re-reading 8+ JSON files per request. If the
# broker is unreachable (older runner, local-only mode), the cache
# stays empty and callers fall back to disk — behaviour-preserving.

DEFAULT_SOCK = "#{process.env.HOME}/pipeline/state/runner.sock"

class StatusSource
  constructor: (opts={}) ->
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
    @client.on 'close',   => @connected = false
    @client.subscribe 'runner/+/+/state',       (topic, payload) => @_onState topic, payload
    @client.subscribe 'runner/+/+/step/+',      (topic, payload) => @_onStep  topic, payload
    @client.subscribe 'runner/+/+/event',       (topic, payload) => @_onEvent topic, payload
    @client.subscribe 'runner/+/+/lifecycle',   (topic, payload) => @lifecycle = payload
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

  _onStep: (topic, payload) ->
    parts = topic.split '/'
    return unless @_topicMatchesFilter parts
    name = parts[4]
    return unless name
    if name is 'current' then return
    if payload is null then @steps.delete name
    else @steps.set name, payload

  _onEvent: (topic, payload) ->
    parts = topic.split '/'
    return unless @_topicMatchesFilter parts
    @events.push payload
    @events.splice 0, @events.length - @eventsMax if @events.length > @eventsMax

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
