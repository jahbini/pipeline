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

DEFAULT_MODEL_DIR   = process.env.HELPER_LLM_MODEL_DIR ? '/Users/jahbini/models/Qwen/Qwen3-1.7B-mlx4'
DEFAULT_CACHE_MB    = Number(process.env.HELPER_LLM_CACHE_MB ? 512)
# 2026-09-14: optional LoRA adapter loaded on top of the base model.
# Trained by ~/pipeline/mlx/helper_train.coffee. Empty string / unset
# means base model only.
DEFAULT_ADAPTER_PATH = process.env.HELPER_LLM_ADAPTER_PATH ? ''

# --- session singleton ---------------------------------------------------
_session = null
_sessionPromise = null

getSession = ->
  return _session if _session?
  return _sessionPromise if _sessionPromise?
  { createSession } = require './session_api'
  createOpts =
    modelDir:     DEFAULT_MODEL_DIR
    cacheLimitMB: DEFAULT_CACHE_MB
  # Only pass adapterPath when it's actually set — session_api treats
  # empty string as "base, no adapter" but the intent is clearer here.
  createOpts.adapterPath = DEFAULT_ADAPTER_PATH if DEFAULT_ADAPTER_PATH.length > 0
  _sessionPromise = createSession createOpts
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
  # Take everything after the LAST </think>. If no </think>, strip
  # any leading <think> tokens (adapter-tuned models sometimes emit an
  # opener without a closer before jumping straight to the answer) and
  # try again. If the payload appears to be JSON, cut to the first `{`.
  m = s.match /[\s\S]*<\/think>\s*([\s\S]*)$/
  if m
    s = m[1]
  else
    # No </think>: drop every <think> opener; keep the tail.
    s = s.replace(/^\s*(?:<think>\s*)+/, '')
  s = s.replace(/<\|im_end\|>[\s\S]*$/, '').trim()
  # If the result starts with non-JSON preamble but a `{` appears
  # somewhere, cut to the first `{`. Preserves the JSON payload the
  # adapter actually emitted.
  brace = s.indexOf '{'
  s = s.slice(brace) if brace > 0 and not s.startsWith('{')
  s

# --- directive thinking prefills -----------------------------------------
# 2026-09-14: each capability can attach a `thinkPrefill` — the CONTENT
# of the <think>…</think> block session_api injects when raw+no_thinking
# are set. Qwen3 treats these tokens as its own chain-of-thought; the
# attention layers weight them when producing the answer.
#
# For classify_failure we spell out the routing rules explicitly. The
# model reads them as if it had already reasoned through the error and
# is about to emit the answer. This gets us structured routing without
# any training — the LoRA adapter can come later to sharpen edge cases.
#
# For summarize_log we don't inject rules — the task genuinely needs
# freeform reasoning about whichever log tail arrived.

thinkPrefillFor =
  # 2026-09-14: reasoning notes only. Concrete (input → output)
  # examples live in the task prompt itself (see FEW_SHOT_EXAMPLES
  # below) because the model treats a rich <think> block as "task
  # description" and generates fresh reasoning on top. Keep this
  # block TERSE — just the routing rules as already-decided facts.
  classify_failure: """
    I classify the input error into ONE category using these rules —
    first match wins:
      1. `reason=run_lora_train_ite` / `no-adapter` / missing adapter → no_adapter
      2. `Metal Command Buffer` / `GPU Timeout` / exit_code=143 → thermal_timeout
      3. `SIGABRT` with Metal / libc++abi → metal_abort
      4. `activeMB` / `spike` / `oom_killer` / `malloc failed` / exit_code=137 → oom
      5. `won't fit` / `disk full` / SAFETY-ABORT ratio ≥ 2× → too_big
      6. `run.status=running` and exit_code=undefined → soft_limit
      7. `curl` / `HTTP` / `hf_hub` / `git clone` → network
      8. Stack trace or `Error: [step_name]` → recipe_bug
      9. Otherwise → unknown (confidence ≤ 0.5)

    I emit one JSON line — no prose, no code fences.
  """
  summarize_log: ''  # freeform reasoning is what this capability needs

# 2026-09-14: few-shot exemplars — 11 (input → output) pairs covering
# every category. Rendered inside the task prompt where they belong
# (see the classify_failure body). Concrete examples plus concise
# <think> rules is the combination the model handles best.
FEW_SHOT_CLASSIFY_FAILURE = """
    Examples:

    Input:  "peer pipeline_state=shutdown run.status=failed exit_code=1 logdir=elementary_10_11 reason=run_lora_train_ite"
    Output: {"category":"no_adapter","confidence":0.9,"summary":"Elementary shutdown during train_lora — likely no adapter written"}

    Input:  "Metal Command Buffer execution failed: Caused GPU Timeout Error"
    Output: {"category":"thermal_timeout","confidence":0.9,"summary":"Metal GPU timeout — process terminated"}

    Input:  "Elementary training terminated with exit_code=143"
    Output: {"category":"thermal_timeout","confidence":0.85,"summary":"SIGTERM (exit_code=143) — mini likely thermal-throttled"}

    Input:  "libc++abi: terminating due to uncaught exception of type std::runtime_error: [METAL] SIGABRT in libmetal"
    Output: {"category":"metal_abort","confidence":0.9,"summary":"Metal driver SIGABRT — kernel crash"}

    Input:  "activeMB spike exceeded 16000 MB ceiling during reembed_chunks_clean"
    Output: {"category":"oom","confidence":0.9,"summary":"activation memory spike during reembed_chunks_clean"}

    Input:  "Process killed by oom_killer, exit_code=137"
    Output: {"category":"oom","confidence":0.9,"summary":"SIGKILL from oom_killer (exit_code=137)"}

    Input:  "SAFETY ABORT activeMemMB=48000 > ceiling 20000 — model won't fit here (ratio 2.4x)"
    Output: {"category":"too_big","confidence":0.9,"summary":"Model does not fit on peer — 2.4× the memory ceiling"}

    Input:  "peer pipeline_state=(none) run.status=running exit_code=undefined logdir=elementary_09_00 reason=(none)"
    Output: {"category":"soft_limit","confidence":0.85,"summary":"Peer poll gave up while runner appeared alive — max_wait tripped"}

    Input:  "curl: (7) Failed to connect to huggingface.co port 443: Connection timed out"
    Output: {"category":"network","confidence":0.95,"summary":"Failed to connect to huggingface.co"}

    Input:  "Error: [oracle_ask_sqlite] Missing required param 'model_dir'"
    Output: {"category":"recipe_bug","confidence":0.9,"summary":"oracle_ask_sqlite step raised a missing-param Error"}

    Input:  "unspecified failure with no diagnostic markers"
    Output: {"category":"unknown","confidence":0.3,"summary":"No identifying markers in the error text"}
"""

# --- shared runner -------------------------------------------------------
# Every capability builds a task prompt, calls the model, strips the
# think prefix, tries JSON.parse, and returns a normalized envelope.
# On parse failure the runner retries once at a lower temperature; if
# that also fails, returns {ok:false, raw, error}.
runCapability = (capabilityName, taskPrompt, opts = {}) ->
  session = await getSession()
  prefill = thinkPrefillFor[capabilityName] ? ''

  attempt = (temp) ->
    result = await session.generate buildChatML(taskPrompt),
      maxTokens:    opts.maxTokens   ? 120
      temperature:  temp
      topP:         opts.topP        ? 0.8
      raw:          true
      no_thinking:  true
      thinkPrefill: prefill
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
    #{FEW_SHOT_CLASSIFY_FAILURE}
    Now classify this input:

    Input:  "#{String(errorText ? '').trim()}"
    Output:
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
  # 2026-09-14: export the prefill map so helper_train.coffee can bake
  # the SAME <think> content into training rows and keep the training-
  # inference distribution aligned.
  thinkPrefillFor
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
