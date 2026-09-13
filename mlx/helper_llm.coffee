# mlx/helper_llm.coffee
# ---------------------------------------------------------------------------
# Puppeteer-side "helper" LLM — a small local instruction-tuned model used
# for classifications, summarizations, and recommendations that the
# puppeteer's queue driver and UI want an opinion on. See
# ~/puppeteer/GPT/helper_llm_plan.md for the design intent.
#
# Contract:
#   helper = require('mlx/helper_llm')
#   result = await helper.classify_failure(errorText)
#     result: { ok: true, category, confidence, summary }
#          |  { ok: false, raw, error }
#
# Every capability returns the same envelope shape. Callers never have to
# guess whether the model produced parseable output — check `ok`, use the
# payload if true, log `raw` if false.
#
# CLI:
#   coffee mlx/helper_llm.coffee classify_failure "Metal Command Buffer ..."
#     → prints one line of JSON to stdout
#
# The session is lazy-loaded on first call and reused across the process
# lifetime. Model resident cost ≈ 1.9 GB on Qwen3-1.7B-mlx4 (verified
# 2026-09-13 on the laptop).

path = require 'path'

DEFAULT_MODEL_DIR = process.env.HELPER_LLM_MODEL_DIR ? '/Users/jahbini/models/Qwen/Qwen3-1.7B-mlx4'
DEFAULT_CACHE_MB  = Number(process.env.HELPER_LLM_CACHE_MB ? 512)

# --- session singleton ---------------------------------------------------
_session = null
_sessionPromise = null

getSession = ->
  return _session if _session?
  return _sessionPromise if _sessionPromise?
  { createSession } = require './session_api'
  _sessionPromise = createSession
    modelDir:     DEFAULT_MODEL_DIR
    cacheLimitMB: DEFAULT_CACHE_MB
  _session = await _sessionPromise
  _sessionPromise = null
  _session

dispose = ->
  return unless _session?
  try _session.dispose() catch then null
  _session = null

# --- prompt scaffolding --------------------------------------------------
# Wrap the caller's task text in Qwen's ChatML. The helper always runs in
# `raw: true` mode so we control the tokens exactly — this is what makes
# `no_thinking` work (see session_api §315 for the prefill trick).
buildChatML = (userText) ->
  """
  <|im_start|>user
  #{userText}<|im_end|>
  <|im_start|>assistant
  """

# Strip the `<think>...</think>` echo the model emits at the start of a
# `no_thinking` response. session_api prefills `<think>\n\n</think>\n\n`
# and Qwen1.7B echoes it once before the real answer. Also strip any
# trailing `<|im_end|>` if the model dropped one in.
stripThink = (text) ->
  s = String(text ? '')
  # Take everything after the LAST </think>. If no </think>, return trimmed input.
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  s = m[1] if m
  s.replace(/<\|im_end\|>[\s\S]*$/, '').trim()

# --- shared runner -------------------------------------------------------
# Every capability builds a task prompt, calls the model, strips the
# think prefix, tries JSON.parse, and returns a normalized envelope.
# On parse failure the runner retries once at a lower temperature; if
# that also fails, returns {ok:false, raw, error}.
runCapability = (capabilityName, taskPrompt, opts = {}) ->
  session = await getSession()

  attempt = (temp) ->
    result = await session.generate buildChatML(taskPrompt),
      maxTokens:   opts.maxTokens   ? 120
      temperature: temp
      topP:        opts.topP        ? 0.8
      raw:         true
      no_thinking: true
    stripThink result.text

  temps  = [opts.temperature ? 0.2, (opts.temperature ? 0.2) * 0.4]
  rawOut = null
  for temp in temps
    try
      rawOut = await attempt(temp)
    catch err
      return { ok: false, raw: null, error: "generate threw: #{String(err?.message ? err)}", capability: capabilityName }
    try
      parsed = JSON.parse rawOut
      return Object.assign({ ok: true, capability: capabilityName }, parsed)
    catch parseErr
      # try the lower-temp retry on next loop iteration
      continue

  { ok: false, raw: rawOut, error: 'model did not return valid JSON', capability: capabilityName }

# --- CAPABILITY: classify_failure ---------------------------------------
# Input: raw error text from spawn_log.error_text (or pipe_states.last_failure.error).
# Output: { category, confidence, summary }
#
# `category` is one of the fixed set; anything else the model coughs up
# should be treated as `unknown` by the caller. `confidence` is a
# self-reported 0..1; take with a grain of salt but useful for ranking.
# `summary` is one plain sentence for the puppeteer UI's needs_attention.hint.

FAILURE_CATEGORIES = [
  'too_big'         # model / weights too large for the peer's disk or memory
  'recipe_bug'      # something in the recipe raised or asserted
  'soft_limit'      # config-tunable ceiling hit (max_wait, max_tokens, etc.)
  'thermal_timeout' # Metal GPU timeout / thermal throttle
  'oom'             # out-of-memory, MLX or system
  'no_adapter'      # training reported done but adapter file missing
  'metal_abort'     # SIGABRT from Metal driver / kernel panic
  'network'         # download / HF / SSH connectivity
  'unknown'         # doesn't match any of the above
]

classify_failure = (errorText) ->
  cats = FAILURE_CATEGORIES.join(', ')
  task = """
    You are a pipeline-failure classifier. Read the error text below and
    reply with exactly one JSON object on one line — no prose, no markdown,
    no code fences.

    Allowed categories (pick exactly ONE):
      #{cats}

    Reply shape (all three keys required):
      {"category": "<one of the above>", "confidence": <0.0 to 1.0>, "summary": "<one short sentence>"}

    Error text:
    #{String(errorText ? '').trim()}
  """
  runCapability 'classify_failure', task, {maxTokens: 120, temperature: 0.2}

# --- CAPABILITY: summarize_log ------------------------------------------
# Input: raw text tail of a pipe's .err (or .log) file — as many lines
# as the caller wants to hand over. The helper caps input length at
# `maxInputChars` (default 8000, roughly 2k tokens) and keeps the TAIL —
# the recent lines are where the fatal signal lives; older lines are
# usually setup or bookkeeping noise.
#
# Output: { summary: "one or two sentences" }
# Feeds pipe_states.needs_attention.hint. Purpose: replace canned strings
# like "unknown failure — see error text, decide manually" with a real
# human-readable one-liner the puppeteer UI can surface.

summarize_log = (logText, opts = {}) ->
  maxInputChars = Number(opts.maxInputChars ? 8000)
  raw = String(logText ? '')
  # Keep the tail: fatal signals almost always live at the end of a log.
  tail = if raw.length > maxInputChars then raw.slice(-maxInputChars) else raw
  task = """
    You are a log-summarizer for a machine-learning pipeline. Read the log
    tail below and reply with exactly one JSON object on one line — no
    prose, no markdown, no code fences.

    Reply shape (single required key):
      {"summary": "<one or two sentences that explain what went wrong and where>"}

    Rules:
      - Focus on the LAST failure signal — earlier lines are usually setup.
      - Name the step or component if it's identifiable.
      - Prefer 60–160 characters. Never exceed 240.
      - If the log looks like a clean completion (no failure), summarize
        the outcome instead ("recipe completed X of Y stories", etc.).

    Log tail:
    #{tail.trim()}
  """
  runCapability 'summarize_log', task, {maxTokens: 200, temperature: 0.2}

# --- exports -------------------------------------------------------------
module.exports = {
  classify_failure
  summarize_log
  dispose
  # Escape hatch for future capabilities and for tests that want to hold
  # the session across many calls.
  getSession
  FAILURE_CATEGORIES
}

# --- CLI -----------------------------------------------------------------
# `coffee mlx/helper_llm.coffee classify_failure "error text..."`
# prints one line of JSON to stdout. Non-zero exit if ok=false.
if require.main is module
  main = ->
    [capability, arg...] = process.argv[2..]
    unless capability?
      process.stderr.write "usage: coffee helper_llm.coffee <capability> <arg-or-file...>\n"
      process.stderr.write "capabilities: classify_failure, summarize_log\n"
      process.stderr.write "  summarize_log accepts either literal text or a path prefixed with @: `@/path/to/log.err`\n"
      process.exit 2
    input = arg.join ' '
    # `@<path>` means: read input from file. Convenient for summarize_log
    # against real log tails without shell-quoting nightmares.
    if input.startsWith '@'
      fs = require 'fs'
      p = input.slice(1)
      input = fs.readFileSync(p, 'utf8')
    result = switch capability
      when 'classify_failure' then await classify_failure(input)
      when 'summarize_log'    then await summarize_log(input)
      else
        process.stderr.write "unknown capability: #{capability}\n"
        process.exit 2
    process.stdout.write JSON.stringify(result) + '\n'
    dispose()
    process.exit(if result.ok then 0 else 1)
  main().catch (err) ->
    process.stderr.write "FATAL: #{String(err?.stack ? err)}\n"
    process.exit 1
