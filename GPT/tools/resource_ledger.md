# tools/resource_ledger.coffee — logical admission control

**File**: `tools/resource_ledger.coffee`
**Tests**: `test/resource_ledger_test.coffee` — `coffee test/resource_ledger_test.coffee`, 18/18 passing.

## What it is

A dependency-free CoffeeScript class that gates work behind pool and
windowed limits per named resource. Meta agents or step scripts hand it
a `submit()` with `needs:` and a `dispatch:` thunk; it decides
`running` / `waiting` / `rejected` and calls `dispatch()` when a slot
opens.

Ignorant of Memo, HTTP, MLX — a policy brain. First consumer is
`meta/hfchat.coffee` (planned integration) via HF-router admission
control. Future consumers register their own resources (mac-mini GPU,
local MLX memory, remote-run slots) and reuse the same class
unchanged.

## Estimation model

Two things get estimated per submit:

1. **memory_mb** — declared as `needs.memory_mb`, checked against the
   resource's pool capacity at admission.
2. **wallclock_seconds** — **not** a `needs:` entry. The caller passes
   it via `finish(id, {wallclock_seconds})`; the ledger folds each
   sample into a per-`(resource, owner)` rolling mean (last 20 samples)
   and returns that mean via `learnedLatency(resource, owner)` as the
   default estimate for future submits that omit it. Before any samples
   exist, a per-resource `wallclock_seconds_seed` is used (config
   default: 10).

Tokens are not tracked. If a backend needs per-minute token limits, add
a `windowed: {tokens_per_min: 60}` entry — the mechanism supports it.

## Admission order — smallest-first

On every rescan (after `submit` or `finish`), waiters are sorted by
total need (sum of `needs` values) and admitted in that order. Arrival
time is a tiebreaker only. A tiny step will not wait behind a huge one
it can fit around. Deliberately **not FIFO** — see test #14.

## Unique ids — one-shot submit/finish

Every `submit` uses a unique id. A submit with an id that's already
running or already finished rejects with `reject_duplicate_id` and its
`dispatch()` is never called. Two pipeline steps cannot share an id;
each submit has its own finish.

Duplicate or unknown-id `finish()` is a stderr warning and a no-op.

## Public API

```
new ResourceLedger(clock = -> Date.now()/1000)
addResource(name, limits, windowed = {}, seed = 10)
setOwnerLimit(owner, maxRunning)
submit({id, owner, resource, needs, dispatch}) → "running"|"waiting"|"rejected"
finish(id, actuals = {})                        # {wallclock_seconds, memory_mb}
learnedLatency(resource, owner)                 → seconds (rolling mean or seed)
report()                                        → {resources, running, waiting}
ledger                                          → append-only audit list
```

## Config shape (consumer's `params/_global.yaml`)

Meta agents that integrate the ledger read config from the memo:

```yaml
run:
  resources:
    hf-api:
      limits:   {concurrent: 2, memory_mb: 2048}
      windowed: {}
      wallclock_seconds_seed: 8
  owners:
    pipeline: 4
  default_owner: pipeline
  hfchat_default_memory_mb: 256
```

## Backward-compat rule (for meta agents integrating the ledger)

If the consumer's `params/_global.yaml` has no `resources.<name>`
block, the meta agent should behave exactly as before admission
control landed — no throw, no queue, direct dispatch. Existing recipes
must not change behavior until config opts in.
