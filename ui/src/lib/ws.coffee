import { writable } from 'svelte/store'

export socketStatus = writable('disconnected')
export memoStore = writable({})

connect = (url = 'ws://localhost:8765') ->
  ws = new WebSocket(url)

  ws.onopen = ->
    socketStatus.set('connected')
    console.log 'WS connected'

  ws.onclose = ->
    socketStatus.set('disconnected')
    console.log 'WS closed'

  ws.onerror = (e) ->
    socketStatus.set('error')
    console.error 'WS error', e

  ws.onmessage = (msg) ->
    try
      data = JSON.parse(msg.data)
      if data.type is 'memo'
        memoStore.update (m) ->
          m[data.key] = data.value
          m
    catch e
      console.warn 'WS parse error:', msg.data

  ws

export { connect }
