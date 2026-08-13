###
        meta/hfchat.coffee  —  Hugging Face router chat completions
        ===========================================================

  Third meta backend, alongside `sqlite.coffee` (structured DB
  keys) and the file backends (`json`/`jsonl`/`txt`/`csv`/`yaml`).

  Contract
  --------
  Any key matching `*.hfchat` is handled here. Writing a
  **request struct** to such a key triggers a POST to the HF
  router chat-completions endpoint; on success the memo entry
  hydrates to the parsed response JSON (the full response, not
  just message text — downstream steps pluck what they need).

  Steps never see the HTTP layer:

      L.make 'summarize.hfchat', {messages: [...]}     # kicks off POST
      # ... later, in a downstream step declaring it in `need:`
      resp = await L.need 'summarize.hfchat'           # blocks until 2xx
      text = resp.choices[0].message.content

  Request struct shape
  --------------------
  `{model, messages, ...}` — passed through verbatim as the JSON
  body. `messages` is required and is how we distinguish a
  fresh request from a hydrated response (see "async plumbing"
  below). `model` defaults from a single config location
  (`params/_global.yaml: hfchat_default_model`); a per-request
  `model` field overrides. The default is where you set the HF
  provider policy suffix — `:fastest`, `:cheapest`, or a named
  provider — so step code never encodes provider policy.

  Failure policy
  --------------
  - Missing `HF_TOKEN`, missing `messages`, or missing default
    model when the request omits one → synchronous throw at
    write time. The step fails immediately.
  - Non-2xx response → the memo entry's `notifier` rejects with
    an error carrying status and parsed body. Any downstream
    step that awaits (via `L.need`) throws with the same info.
    The token does NOT propagate — write-completion is gated
    on 2xx.
  - Transport error / 5xx: retried per `tools/retry_policy`
    (currently 3 attempts, 10-min backoff, same schedule as
    `download_model.coffee`). 4xx is not retried — it will
    never succeed.

  Async plumbing (why the handler has two branches)
  -------------------------------------------------
  Meta handlers on `Memo` are called both for the initial write
  (with the request struct) and for the subsequent
  self-injected write (with the response object, when the fetch
  completes). We tell them apart by presence of `messages`:
    - has `messages` → treat as a fresh request: kick off the
      fetch, clear the memo entry's `.value` so downstream
      `theLowdown` reads `undefined` and awaits the notifier.
    - no `messages`  → treat as pass-through: return the value
      unchanged so it lands as `entry.value`.
  The fetch's completion calls `M.saveThis(key, response)`,
  which fires the original notifier with the response and (via
  the pass-through branch) sets `entry.value = response`.

  Read semantics
  --------------
  `theLowdown` on an `.hfchat` key without a prior write returns
  `undefined` — there is no on-disk backing, and speculatively
  POSTing on a read would be surprising. Reads AFTER completion
  return the parsed response.
###

path = require 'path'
{withRetriesAsync} = require '../tools/retry_policy'

HF_ROUTER_URL = 'https://router.huggingface.co/v1/chat/completions'

module.exports = (M, opts = {}) ->

  # Resolve the default model at fetch time (not at load time)
  # so edits to params/_global.yaml between runs take effect
  # without a runner restart.
  resolveDefaultModel = ->
    globalParams = M.theLowdown("params/_global.yaml")?.value ? {}
    globalParams.hfchat_default_model ? null

  # Non-2xx → reject. 4xx not retried (won't succeed on retry);
  # 5xx and transport errors are retried by the caller's
  # `withRetriesAsync` loop.
  class HfchatError extends Error
    constructor: (msg, @status, @body) ->
      super msg

  doFetchOnce = (body) ->
    token = process.env.HF_TOKEN
    throw new Error "meta/hfchat: HF_TOKEN env var is not set" unless token

    res = await fetch HF_ROUTER_URL,
      method: 'POST'
      headers:
        'Authorization': "Bearer #{token}"
        'Content-Type':  'application/json'
      body: JSON.stringify(body)

    text = await res.text()

    if res.status < 200 or res.status >= 300
      parsed = null
      try parsed = JSON.parse(text) catch then parsed = text
      err = new HfchatError(
        "meta/hfchat: HF router returned #{res.status}: #{if typeof parsed is 'string' then parsed else JSON.stringify(parsed)}"
        res.status
        parsed
      )
      throw err

    try
      return JSON.parse(text)
    catch parseErr
      throw new Error "meta/hfchat: response was 2xx but not valid JSON: #{parseErr.message}"

  doFetchWithRetries = (key, body) ->
    withRetriesAsync(
      -> doFetchOnce(body)
      label: "hfchat:#{key}"
      shouldRetry: (err) ->
        # Retry transport errors and 5xx; skip 4xx (won't
        # succeed on retry).
        return true unless err instanceof HfchatError
        err.status >= 500
    )

  M.addMetaRule "hfchat",
    /\.hfchat$/,
    (key, value) ->
      # Read: no on-disk backing. Return whatever is already in
      # the memo entry (undefined if never written, response
      # object if the fetch completed).
      if value is undefined
        return M.MM[key]?.value

      # Pass-through branch: the fetch has completed and is
      # re-writing itself as a response object. No `messages` →
      # not a fresh request → land as-is.
      unless value? and typeof value is 'object' and Array.isArray(value.messages)
        return value

      # Fresh request. Validate and build the body.
      body = {}
      body[k] = v for own k, v of value
      unless body.model?
        body.model = resolveDefaultModel()
        unless body.model?
          throw new Error "meta/hfchat: request to '#{key}' has no model and params/_global.yaml has no hfchat_default_model"

      # Clear the memo entry's cached value so a `theLowdown`
      # between now and fetch completion returns `undefined`
      # (and any `need` awaits the notifier instead of seeing
      # the raw request struct).
      entry = M.MM[key]
      entry.value = undefined if entry?

      doFetchWithRetries(key, body)
        .then (response) ->
          # Re-enter saveThis; hits the pass-through branch,
          # resolves the notifier with `response`, sets
          # entry.value = response.
          M.saveThis key, response
        .catch (err) ->
          console.error "[hfchat] #{key} failed after retries:", err?.message ? err
          # Reject the notifier so any awaiter (L.need) throws.
          # `.catch(-> null)` on the replacement avoids
          # unhandledRejection noise from the notifier itself;
          # the awaiter still sees the rejection when it
          # `await`s.
          latest = M.MM[key]
          if latest?
            rejected = Promise.reject(err)
            rejected.catch -> null
            latest.notifier = rejected

      # Return undefined so saveThis leaves entry.value cleared.
      undefined
