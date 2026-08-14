# meta/hfchat — Hugging Face router chat completions

**File**: `meta/hfchat.coffee`
**Suffix**: `*.hfchat`
**Retry policy**: `tools/retry_policy.coffee` (3 attempts, 10-min
backoff — shared with `scripts/model/download_model.coffee` via
duplicated constants; the async twin `withRetriesAsync` lives here)

## Contract

A key matching `*.hfchat` routes to this handler. Writing a **request
struct** — `{model?, messages, ...}` — kicks off a POST to
`https://router.huggingface.co/v1/chat/completions`; the memo entry
hydrates to the parsed response JSON when the fetch completes.

Consumer pattern in a step:

```coffee
L.saveThis "myThing.hfchat",
  messages: [{role: 'user', content: '...'}]
# ... later, in a downstream step that declares it in `need:`:
resp = await L.need 'myThing.hfchat'
text = resp.choices[0].message.content
```

## Request shape

`{model?, messages, ...}` — passed through verbatim as the JSON body.
`messages` is required; its presence is how the handler tells a fresh
request from the re-entrant response write (see "Async plumbing"
below).

`model` defaults from `params/_global.yaml:hfchat_default_model` — the
single source of truth for the provider policy suffix (`:fastest`,
`:cheapest`, named provider). Resolved at dispatch time so a config
edit takes effect on the next request without a runner restart. A
`model` field in the request overrides.

## Failure policy

- Missing `HF_TOKEN`, missing `messages`, or missing default model
  when the request omits one → synchronous throw at write time. The
  step fails immediately.
- Non-2xx response → the entry's notifier **rejects** with an error
  carrying status + parsed body. Downstream `L.need` throws with the
  same info. The token does not propagate — completion is gated on 2xx.
- Transport error or 5xx → retried per `tools/retry_policy` (3
  attempts, 10-min backoff). 4xx is not retried — it will never
  succeed. Final failure rejects the notifier as above.

## Async plumbing (why the handler has two branches)

Memo handlers on `Memo` are sync `(key, value) -> value` functions.
`hfchat` needs to do async work, so:

1. **Fresh-request branch** (`value.messages` present): validate,
   clear the memo entry's `.value` so `theLowdown` returns
   `undefined` and awaiters block on `.notifier`, kick off the fetch,
   return `undefined` (saveThis leaves `entry.value` cleared).
2. **Pass-through branch** (no `messages`): the fetch has completed
   and is re-writing itself via `M.saveThis(key, response)`. Return
   the response object as-is so it lands as `entry.value` and the
   original notifier fires with it.

Rejection replaces `entry.notifier` with `Promise.reject(err)` (plus a
suppressing `.catch(->)` on the replacement) so downstream `await`
throws while unhandled-rejection noise stays out of the log.

## Read semantics

`theLowdown` on an `.hfchat` key with no prior write returns
`undefined`. No on-disk backing; speculatively POSTing on read would
be surprising. After completion, reads return the parsed response.

## Config

Live in the recipe's `run:` block (goes to `params/_global.yaml`):

```yaml
run:
  hfchat_default_model: meta-llama/Llama-3.3-70B-Instruct:cheapest
```

Env: `HF_TOKEN` required.

## First consumer

`~/writer/pipes/story/scripts/simplify_chunks_ite.coffee` — wraps
each hfchat round-trip in a local `ResourceLedger` for admission
control (see `~/writer/GPT/resource_ledger.md`). The ledger lives in
the writer project, not here — this meta handler is unaware of it.
