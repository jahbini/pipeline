###
        tools/retry_policy.coffee  —  shared retry/backoff policy
        =========================================================

  Single source of truth for the "how many attempts, how long
  between them" policy used by any long-haul external call in
  this repo. Currently shared by:

  - `scripts/model/download_model.coffee` (HF git+lfs clone;
    synchronous — uses its own `Atomics.wait` sleep)
  - `meta/hfchat.coffee` (HF router chat completion; async —
    uses `withRetriesAsync` below)

  If you change the schedule, change it here. Both callers pick
  up the new values on next require.
###

# 3 attempts, 10 minutes between them. Matches the download
# script's original hardcoded schedule; verified 2026-08-13 to
# match its downloader wait comment ("Waiting 10 minutes before
# retry...").
MAX_RETRIES      = 3
SLEEP_BETWEEN_MS = 10 * 60 * 1000

# Async retry loop for Promise-returning work. `fn` is invoked
# with the 1-based attempt number and must return a Promise. A
# throw or rejection triggers a sleep-then-retry. On the last
# attempt the error is re-thrown to the caller.
#
# `shouldRetry(err, attempt)` (optional) may return false to
# stop retrying early (e.g. a 4xx that will never succeed).
withRetriesAsync = (fn, opts = {}) ->
  maxRetries  = opts.maxRetries  ? MAX_RETRIES
  sleepMs     = opts.sleepMs     ? SLEEP_BETWEEN_MS
  shouldRetry = opts.shouldRetry ? -> true
  label       = opts.label       ? 'withRetriesAsync'

  lastErr = null
  for attempt in [1..maxRetries]
    try
      return await fn(attempt)
    catch err
      lastErr = err
      if attempt >= maxRetries or not shouldRetry(err, attempt)
        throw err
      console.error "[#{label}] attempt #{attempt}/#{maxRetries} failed: #{err?.message ? err}"
      console.error "[#{label}] waiting #{Math.round(sleepMs / 1000)}s before retry..."
      await new Promise (resolve) -> setTimeout(resolve, sleepMs)
  throw lastErr

module.exports = {MAX_RETRIES, SLEEP_BETWEEN_MS, withRetriesAsync}
