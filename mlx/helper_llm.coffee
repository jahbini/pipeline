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

  # 2026-09-16: scheduling adviser. Given a pipe's recent-session history
  # and current state, recommend ONE structured action. Rules encode the
  # 7 canonical decisions from puppeteer/GPT/scheduling_helper.md;
  # ordering matters — first match wins so we get deterministic routing.
  schedule: """
    I read the pipe's recent sessions and current state, then walk this
    checklist to decide ONE action. First match wins:

      1. peer_active_now names a DIFFERENT pipe than target →
         wait (peer's writer is single-instance).

      2. recent_sessions has ≥3 consecutive crashed/error rows on the
         same recipe with the same error_signature, no successful run
         between them, AND (only for `no rows in build/train/train.jsonl`
         signature) there is NO successful reset row between them →
         reset (empty sqlite pattern).

      3. Same as (2) but the error signature is NOT the empty-sqlite
         signature (e.g. same MLX crash three times, same SAFETY_ABORT
         at the same ceiling three times) →
         hospitalize (retry loop is unproductive).

      4. Latest crash has SAFETY_ABORT with activeMem/ceiling ratio ≥ 2×,
         OR the pipe already has a raised_ceiling marker AND still
         crashed with SAFETY_ABORT →
         reject (model doesn't fit here).

      5. Latest crash has SAFETY_ABORT with ratio in [1×, 2×) AND no
         raised_ceiling marker →
         raise_ceiling (host has headroom).

      6. Elementary + training succeeded AND cross_pipe_signals shows
         a recent storacle probe with repetition_loop=true →
         graduate (small model overfits; can't fix via sampling).

      7. Legitimate healthy state — successful runs, no failure signal
         at the top of history, pipe in continue with unrun elementary →
         launch elementary. Or if nothing to do, wait.

      8. Recent success dominates. If recent_sessions[0] shows a
         successful terminal run (status='done' or 'success') for
         the same recipe, do NOT recommend an action predicated on
         older failures. Older crashes were superseded by the
         success at the top. Prefer `wait` (the recipe just finished
         and the human hasn't reviewed yet). Older-failure rules
         (needs_reset, hospitalize-after-N-crashes) apply ONLY when
         the top of history is NOT a matching success.

    Rule 9 — escalate when I don't know. If NONE of rules 1-8 apply
    cleanly to the input, OR the signals are contradictory (two rules
    both match but recommend different actions), OR the scenario shape
    doesn't resemble any example I've seen — pick `escalate` with a
    `reason` field naming exactly what's unclear. Do NOT invent a
    decision to fill the JSON when I'm uncertain. Escalating a healthy
    pipe is cheaper than executing a wrong destructive action.
    Concrete escalate triggers:
      - Recent sessions include a status value not in {done, success,
        crashed, error, running, shutdown, retry_after_idle}.
      - error_signature on a crash doesn't resemble any pattern in
        the seed examples.
      - Two rules from 1-8 both match this scenario but their actions
        differ (e.g. would recommend both raise_ceiling AND reject).
      - Cross-pipe signals are internally inconsistent (peer says
        idle but a session shows recipe running with recent
        started_at).
      - The scenario is missing fields I'd normally rely on
        (recent_sessions empty, or current_state not set).

    Rule 10 — always emit `confidence: 0..1` alongside action. 1.0 =
    the scenario matches a seed example exactly; 0.5 = I applied a
    rule but there are unusual details; below 0.3 I should probably
    have escalated. The auto-execute machinery uses this to gate
    dispatches; be honest.

    Anti-patterns I must NOT commit:
      - If peer_active_now is null (empty string / missing / null),
        the peer is IDLE. I do NOT choose `wait` and claim "peer
        busy" — that is a hallucination.
      - I do NOT default to `wait` when I am uncertain. If the input
        shows a specific failure pattern (SAFETY_ABORT, N-consecutive-
        crashes, degenerate-loop), I MUST match the pattern to its
        rule above and emit that rule's action — even if the seed
        examples for that action are fewer.
      - I do NOT invent state that isn't in the input. If
        pipe_markers is empty or a specific marker is null, I treat
        it as absent — I do NOT claim raised_ceiling was already
        applied when it wasn't.

    The reason field cites SPECIFIC evidence (which row indices in
    recent_sessions, what error_signature, what state marker).
    I emit one JSON line — no prose, no code fences.
  """

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
#
# Sequence per call:
#   1. First attempt at opts.temperature (default 0.2).
#   2. If parse fails AND the raw output looks truncated inside <think>
#      (no </think> present AND length near maxTokens char-budget), do a
#      rescue continuation: reconstruct the prompt including the injected
#      thinkPrefill and the partial output, append "time's up" + </think>
#      + {, generate ~250 more tokens, and prepend { to what comes back.
#      Preserves the reasoning the model already did; often lands JSON.
#   3. If rescue fails or wasn't triggered, retry once at temperature*0.4.
#   4. If that also fails, return {ok:false, raw, error}.
#
# See memory: thinking-budget-rescue.
_runCapabilityUnguarded = (capabilityName, taskPrompt, opts = {}) ->
  session   = await getSession()
  # 2026-09-23 (approach 2 / turn-prefill at inference). Callers can
  # now pass an override prefill in opts.thinkPrefill to inject
  # scenario-specific directive reasoning at the assistant turn head.
  # Falls back to the static thinkPrefillFor[cap] map otherwise.
  # See schedule() below for the KAG-aggregated prefill it builds.
  prefill   = opts.thinkPrefill ? thinkPrefillFor[capabilityName] ? ''
  baseTemp  = opts.temperature ? 0.2
  maxTokens = opts.maxTokens   ? 120
  topP      = opts.topP        ? 0.8

  attempt = (temp) ->
    result = await session.generate buildChatML(taskPrompt),
      maxTokens:    maxTokens
      temperature:  temp
      topP:         topP
      raw:          true
      no_thinking:  true
      thinkPrefill: prefill
    String(result.text ? '')     # PRE-strip so we can inspect the trajectory

  tryParse = (raw) ->
    return null unless raw
    try
      return JSON.parse stripThink(raw)
    catch
      return null

  # Two truncation shapes worth rescuing:
  #   (a) inside-think — no </think> in raw AND near budget: model is still
  #       reasoning and never committed. Inject "time's up" + </think> + {.
  #   (b) inside-JSON — </think> present but JSON.parse failed AND raw ends
  #       near budget: model committed to answering but ran out mid-JSON.
  #       Continue the partial JSON directly.
  # Char-budget ≈ 3.4 chars/token × maxTokens (empirical for Qwen3 English).
  rescueShape = (raw) ->
    return null unless raw
    return null unless raw.length >= Math.floor(3.0 * maxTokens)
    if /<\/think>/.test(raw) then 'json' else 'think'

  # Rescue (a): reconstruct the full prompt the first attempt saw and force a
  # </think> + { commit at the tail. session_api passes the raw prompt through
  # unmodified when no_thinking:false + thinkPrefill:'' (session_api.coffee:371-395).
  rescueInsideThink = (partialRaw) ->
    injected     = "<think>\n#{prefill}\n</think>\n\n"
    forceCommit  = "\n\nOK, time's up, answering now.\n</think>\n\n{"
    rescuePrompt = buildChatML(taskPrompt) + injected + partialRaw + forceCommit
    result = await session.generate rescuePrompt,
      maxTokens:    300
      temperature:  0.15
      topP:         topP
      raw:          true
      no_thinking:  false
      thinkPrefill: ''
    tail = String(result.text ? '').replace(/<\|im_end\|>[\s\S]*$/, '').trim()
    tail = tail.replace(/^\{+/, '')
    try
      return JSON.parse('{' + tail)
    catch
      return null

  # Rescue (b): thinking already closed, JSON started but got cut. Take the
  # partial output through the last `{`, ask the model to continue from where
  # it stopped. Splice head+continuation and parse.
  rescueInsideJson = (partialRaw) ->
    injected     = "<think>\n#{prefill}\n</think>\n\n"
    stripped     = stripThink partialRaw               # post-</think> tail
    # If stripped doesn't start with `{`, there's non-JSON preamble; keep
    # from the first `{` onward — that's what session output usually looks
    # like when JSON begins mid-line.
    idx = stripped.indexOf('{')
    return null if idx < 0
    head = stripped.slice(idx)
    rescuePrompt = buildChatML(taskPrompt) + injected + partialRaw
    result = await session.generate rescuePrompt,
      maxTokens:    300
      temperature:  0.1
      topP:         topP
      raw:          true
      no_thinking:  false
      thinkPrefill: ''
    tail = String(result.text ? '').replace(/<\|im_end\|>[\s\S]*$/, '').trim()
    candidate = head + tail
    try
      return JSON.parse candidate
    catch
      # Sometimes the model wraps up neatly if we just append a closing `}`
      try
        return JSON.parse(candidate.replace(/,?\s*$/, '') + '}')
      catch
        return null

  temps  = [baseTemp, baseTemp * 0.4]
  rawOut = null
  for temp, i in temps
    try
      rawOut = await attempt(temp)
    catch err
      return { ok: false, raw: null, error: "generate threw: #{String(err?.message ? err)}", capability: capabilityName }
    parsed = tryParse(rawOut)
    return Object.assign({ ok: true, capability: capabilityName }, parsed) if parsed?
    if i is 0
      shape = rescueShape(rawOut)
      if shape?
        try
          rescued =
            if shape is 'think' then await rescueInsideThink(rawOut)
            else                     await rescueInsideJson(rawOut)
          if rescued?
            return Object.assign({ ok: true, capability: capabilityName, rescued: shape }, rescued)
        catch _err
          null

  { ok: false, raw: rawOut, error: 'model did not return valid JSON', capability: capabilityName }

# 2026-09-25 (step 1 of puppeteer→mini migration): claim the GPU mutex
# around each helper capability call. Post-migration on the mini, writer
# pipes and the helper share one Metal device; without this claim they'd
# overlap and thrash GPU RAM (both are 4B-class ~2.5 GB VRAM). Pre-
# migration this claim is cheap (usually uncontended) but it validates
# the design end-to-end. Wrapper around _runCapabilityUnguarded so
# try/finally guarantees release regardless of which early-return path
# _runCapabilityUnguarded takes.
runCapability = (capabilityName, taskPrompt, opts = {}) ->
  gpuClaim   = require './gpu_claim'
  timeoutMs  = Number(opts.gpuClaimTimeoutMs ? process.env.GPU_CLAIM_TIMEOUT_MS ? 120_000)
  ticket     = null
  try
    ticket = await gpuClaim.claim { tag: "helper.#{capabilityName}", timeoutMs }
  catch err
    return { ok: false, error: "gpu_claim: #{err?.message ? err}" }
  try
    await _runCapabilityUnguarded capabilityName, taskPrompt, opts
  finally
    gpuClaim.release ticket

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

# --- CAPABILITY: schedule (2026-09-16) ----------------------------------
# Input: a scenario object describing one pipe's recent history + current
# state + cross-pipe signals. See puppeteer/GPT/scheduling_helper.md for
# the canonical input/output shapes.
# Output: {action, target_pipe, target_recipe, reason}
#
# Runtime callers pass an object; the helper JSON-serializes it into the
# prompt. Passing a pre-serialized string also works.

SCHEDULE_ACTIONS = [
  'reset'         # fire reset recipe on target_pipe
  'launch'        # fire target_recipe on target_pipe
  'hospitalize'   # flip target_pipe state to hospital
  'graduate'      # flip target_pipe state to graduated (positive terminus)
  'reject'        # flip target_pipe state to rejected (cemetery)
  'wait'          # no action; let current run continue
  'raise_ceiling' # bump SESSION_API_MEM_CEIL_MB, then retry
  'kill'          # kill the currently-running pipeline_runner on the peer
  'escalate'      # 2026-09-16: helper's "I don't know" signal. Routes
                   # pipe to hospital with reason prefix "helper
                   # escalation:" so humans can distinguish these from
                   # scheduler-triggered hospitalizations.
]

schedule = (scenario, opts = {}) ->
  # `opts.examples` — optional array of {input, expected_output} pairs
  # rendered as few-shot exemplars in the task prompt. Same pattern as
  # FEW_SHOT_CLASSIFY_FAILURE above. Used by the probe script and by
  # incremental-rehearsal training. If omitted, the task carries only
  # the rules (in thinkPrefillFor.schedule) and the scenario.
  actions = SCHEDULE_ACTIONS.join(', ')
  scenarioText =
    if typeof scenario is 'string' then scenario
    else JSON.stringify(scenario, null, 2)

  examples = opts.examples ? []
  fewShotBlock = ''
  if Array.isArray(examples) and examples.length > 0
    fewShotBlock = "\n\n    Examples:\n"
    for ex in examples
      inputText =
        if typeof ex.input is 'string' then ex.input
        else JSON.stringify(ex.input)
      # 2026-09-23 — Approach (1) from KAG steering discussion: wrap
      # each row's expected `reason` in a <think> block between Input
      # and Output. Qwen3-family models weight <think> content higher
      # than user-turn text, so the reasoning trace becomes an active
      # steering signal instead of buried metadata. Directive shape
      # ("the rule is X because Y") rather than contemplative — see
      # voice_findings_2026-09-21.md for why contemplative think blocks
      # cause the model to imitate rumination instead of deciding.
      #
      # expected_output shape: {action, target_pipe, target_recipe,
      #                         confidence, reason}. The reason is what
      #                         belongs inside <think>; the rest is the
      #                         Output line the model should learn to
      #                         emit AFTER thinking.
      expectedObj =
        if typeof ex.expected_output is 'string'
          try JSON.parse(ex.expected_output) catch then null
        else ex.expected_output
      reasonText = expectedObj?.reason ? null
      outputText =
        if typeof ex.expected_output is 'string' then ex.expected_output
        else JSON.stringify(ex.expected_output)
      if reasonText? and String(reasonText).trim().length
        fewShotBlock += "\n    Input:  #{inputText}\n    <think>\n    #{String(reasonText).trim()}\n    </think>\n    Output: #{outputText}\n"
      else
        fewShotBlock += "\n    Input:  #{inputText}\n    Output: #{outputText}\n"

  task = """
    You are a scheduling adviser for a puppeteer that runs LoRA training
    and evaluation recipes on peer machines. Given one pipe's recent
    session history and current state, reply with exactly one JSON
    object on one line — no prose, no markdown, no code fences.

    Allowed actions (pick exactly ONE):
      #{actions}

    Reply shape (all five keys required):
      {"action": "<one of the above>", "target_pipe": "<pipe name>", "target_recipe": "<recipe name or null>", "confidence": <0.0 to 1.0>, "reason": "<one paragraph explaining WHY, citing specific rows from recent_sessions and any state markers>"}
    #{fewShotBlock}
    Now decide for this scenario:

    Input:  #{scenarioText}
    Output:
  """
  # 2026-09-23 — Approach 2 with guards (v2 / third iteration).
  # v1 (approach 1, `<think>` inside few-shot examples): 3/7 canonicals,
  #                                                     flat with baseline.
  # v2 (approach 2, top-K reasons prepended to prefill): 4/7 canonicals,
  #                                                     but #9 regressed
  #                                                     from safe-wrong (wait)
  #                                                     to destructive-wrong
  #                                                     (reject on a 1.5×
  #                                                      SAFETY_ABORT that
  #                                                      should have been
  #                                                      raise_ceiling).
  # v3 (this): pair each retrieved case with an EXPLICIT PRECONDITION guard
  #            so the model can't fire an action whose guard doesn't hold.
  #            Guards are extracted from the seed corpus's reasoning
  #            structure (SAFETY_ABORT ratio bands, N-consecutive-crash
  #            counts, etc.) and are keyed by action name. When a top-K
  #            row's action has a known guard, that guard renders next to
  #            the case cue in the prefill.
  ACTION_GUARDS =
    reset:         'FIRE ONLY IF: ≥3 consecutive crashes with error_signature="no rows in build/train/train.jsonl" AND no successful reset row between them (empty-sqlite pattern).'
    hospitalize:   'FIRE ONLY IF: ≥3 consecutive crashes with the SAME non-empty-sqlite signature (Metal timeout, model_loader_attr, etc.) AND a successful reset row exists.'
    reject:        'FIRE ONLY IF: SAFETY_ABORT with active/ceiling ratio ≥ 2.0 (too_big band), OR pipe_markers.raised_ceiling is already set AND a SAFETY_ABORT still fires.'
    raise_ceiling: 'FIRE ONLY IF: SAFETY_ABORT with active/ceiling ratio in [1.0, 2.0) (soft-limit band) AND pipe_markers.raised_ceiling is null.'
    wait:          'FIRE ONLY IF: peer_active_now names a DIFFERENT pipe than target, OR pipe.state is SAT/graduated (auto-transition — do not touch), OR the recipe just succeeded (Rule 8: recent success dominates).'
    launch:        'FIRE ONLY IF: reset completed successfully AND elementary has not been re-attempted since AND peer is idle. Or: only prior failure was a retriable network error (single occurrence).'
    graduate:      'FIRE ONLY IF: elementary + training completed successfully AND a storacle probe surfaced repetition_loop_detected=true (small-model overfitting; sampling knobs cannot escape).'
    escalate:      'FIRE ONLY IF: no other rule\'s guard holds AND signals are novel or contradictory. Escalate names the specific missing rule so the corpus can grow.'
  runOpts = {maxTokens: 1500, temperature: 0.2}
  if Array.isArray(examples) and examples.length > 0
    basePrefill = thinkPrefillFor.schedule ? ''
    caseLines = []
    guardsSeen = {}
    for ex, i in examples[0...5]
      expectedObj =
        if typeof ex.expected_output is 'string'
          try JSON.parse(ex.expected_output) catch then null
        else ex.expected_output
      continue unless expectedObj?
      action = expectedObj.action ? '?'
      reason = String(expectedObj.reason ? '').replace(/\s+/g, ' ').trim()
      short  = reason[0...200]
      caseLines.push "- Case #{i+1} (→ #{action}): #{short}"
      guardsSeen[action] = true
    guardLines = []
    for action of guardsSeen
      g = ACTION_GUARDS[action]
      guardLines.push "- #{action}: #{g}" if g
    if caseLines.length
      dynamicPrefill = """
        These past cases are most-similar to the current scenario:
        #{caseLines.join('\n')}

        Each action has a PRECONDITION GUARD. I do NOT fire an action whose guard fails, no matter how similar a case looks:
        #{guardLines.join('\n')}

        I match strongest signals in the input against the guards above. First guard that holds is my action. If no guard holds, escalate (naming the missing rule). One JSON line, no prose.

        #{basePrefill}
      """
      runOpts.thinkPrefill = dynamicPrefill
  runCapability 'schedule', task, runOpts

# --- CAPABILITY: grade_role (2026-09-17) --------------------------------
# Input: one paragraph text + the expected role name (scene|arrival|
#        disturbance|reflection|realization).
# Output: {role: "<one of five>", fit: "good"|"weak"|"wrong", reason: "..."}
# Used by elementary_sat.structure_order check: reads back which role the
# paragraph actually PERFORMS, and how well it fits the expected role.

DIARY_ROLES = ['scene', 'arrival', 'disturbance', 'reflection', 'realization']

thinkPrefillFor.grade_role = """
  I classify this paragraph by which of five diary roles it PERFORMS,
  independent of its position in the letter:
    scene       — sets place/time; sensory/atmospheric; no plot conflict yet.
    arrival     — someone or something enters; may include quoted dialog.
    disturbance — conflict, complication, or bad news introduced.
    reflection  — narrator contemplates causes/motivations; interior monologue
                  about the situation.
    realization — insight, decision, or change of stance; often meta ("I'll
                  define happiness myself, thank you.").
  Then I score how well it fits the expected role: good | weak | wrong.
  Reply with one JSON object, no prose, no code fences.
"""

grade_role = (paragraphText, expectedRole, opts = {}) ->
  para = String(paragraphText ? '').trim()
  role = String(expectedRole ? '').trim().toLowerCase()
  role = 'scene' unless role in DIARY_ROLES
  task = """
    You are grading a paragraph from a diary letter (Jim → Friend). The
    diary format has five paragraphs in fixed order:
      1. scene   2. arrival   3. disturbance   4. reflection   5. realization

    Read the paragraph below and reply with exactly one JSON object on one
    line — no prose, no markdown, no code fences.

    Reply shape (all three keys required):
      {"role": "<scene|arrival|disturbance|reflection|realization>",
       "fit":  "<good|weak|wrong>",
       "reason": "<one short sentence>"}

    Expected role for this position: #{role}

    Paragraph:
    #{para}

    Output:
  """
  runCapability 'grade_role', task, {maxTokens: 300, temperature: 0.15}

# --- CAPABILITY: grade_invariants (2026-09-17) --------------------------
# Input: the whole letter body + array of invariant strings ("things that
#        must stay true").
# Output: {overall: "preserved"|"partial"|"broken",
#          per_invariant: [{invariant, status:"preserved"|"absent"|"contradicted", note}]}

thinkPrefillFor.grade_invariants = """
  I check each invariant against the letter. For each one I decide:
    preserved   — the letter honors it (may paraphrase; the fact holds).
    absent      — the letter never touches it; the fact is neither
                  present nor contradicted.
    contradicted — the letter says the opposite, or a mutually
                  exclusive version.
  Overall: preserved (all preserved), partial (at least one preserved,
  no contradictions), broken (any contradicted OR none preserved).
  Reply with one JSON object, no prose, no code fences.
"""

grade_invariants = (letterBody, invariants, opts = {}) ->
  letter = String(letterBody ? '').trim()
  invs   = if Array.isArray(invariants) then invariants else [String(invariants)]
  invList = invs.map((s, i) -> "  #{i + 1}. #{String(s).trim()}").join('\n')
  task = """
    You are grading a diary letter's fidelity to a list of invariants —
    facts that must stay true. Read the letter and each invariant, then
    reply with exactly one JSON object on one line — no prose, no
    markdown, no code fences.

    Reply shape (both keys required):
      {"overall": "<preserved|partial|broken>",
       "per_invariant": [
         {"invariant": "<verbatim>", "status": "<preserved|absent|contradicted>", "note": "<one short sentence>"}
       ]}

    Invariants:
    #{invList}

    Letter:
    #{letter}

    Output:
  """
  runCapability 'grade_invariants', task, {maxTokens: 800, temperature: 0.15}

# --- CAPABILITY: spine (2026-09-25) -------------------------------------
# Input:  brief (free-form theme / character / situation) + kind
#         ∈ {diary, story, spystory, voyage}.
# Output: {ok, kind, text, meta}. `text` is the raw spine content ready
#         to write to <spines>/<slug>.txt. This is a FREEFORM capability
#         (no JSON schema on the reply); the helper generates 500-2500
#         words of structured spine material given the brief.
#
# Why this exists: 2026-09-24 design directive — the helper LLM
# generates ALL story spines (diary, story, spystory, voyage) so peer
# pipes stop having to do dual-mode work. Consistency + reliable
# grading. See `writer/GPT/story/spine_library.md` + morning notes.
#
# Each kind has a different STRUCTURAL PREFILL that fixes the required
# section names and shape. The `brief` is what the human types in the
# UI — usually 1-3 sentences of character + situation. The helper
# fills every named section with 2-3 excerpt paragraphs.

SPINE_KINDS = ['diary', 'story', 'spystory', 'voyage']

SPINE_PREFILLS =
  # 5-part Jim-letter structure — same shape as
  # ~/writer/data/spines/susannas_song.txt. Sections named
  # scene / arrival / disturbance / reflection / realization,
  # each populated with 2-3 excerpt paragraphs written IN
  # Jim's voice.
  # 2026-09-25 (Path B): each section header is followed by an inline
  # <think>emotion directive</think> block that the downstream story-
  # generation model reads as its own mid-stream reasoning. The
  # per-section emotion tags are hardcoded — they're intrinsic to
  # the diary structure, not brief-dependent. Probe on 1.7B (2026-09-25)
  # confirmed inline think blocks work as beat-level steering at
  # small-model scale (3.5/4 clear hits on tommy-anger/walk-dread/
  # organ-grief; walk-dread and organ-grief also showed the think
  # block PROTECTS the model from repetition loops).
  diary: """
    I write a diary-letter spine in the same 5-section shape as the
    canonical Jim spines. The word "spine" does NOT appear in the
    output — it is the name of this template, not part of the letter.

    The five named sections in order are:
      scene         — everyday frame before events land.
      arrival       — the new thing / news that starts the letter's action.
      disturbance   — the complication that Jim wants to take about.
      reflection    — Jim's aside / gossip / philosophy turn.
      realization   — where the letter ends; what Jim now understands.

    Each of the 5 sections is semantically distinct from the others —
    reflection and realization are NOT the same thing, and their
    excerpts do not repeat.

    FORMAT — critical:
      Line 1: "You are Jim from St. John's, writing to a friend."
      Line 2: A short (2-3 sentence) framing paragraph naming who / what
              the letter is about.
      Then, for each of the 5 sections in order:
         section-name-lowercase-followed-by-a-colon-on-its-own-line
         a literal <think>...</think> block on its own line (see below)
         2 or 3 excerpt paragraphs, each 60-90 words, indented 2 spaces
      NO numbering. NO bullet points. NO markdown headers or bold.

    INLINE <think> STEERING — each section's think block carries
    THIS EXACT emotional register:
      scene       → <think>Register is settled, warmly digressive, unhurried gossip. Jim is comfortable and observational, not yet in motion.</think>
      arrival     → <think>Register sharpens with curiosity. Jim leans in, still warm but expectant. Something has landed.</think>
      disturbance → <think>Register is keenly attentive with a wobble underneath. Jim is not upset yet — he is drawn in, sensing there is something worth telling.</think>
      reflection  → <think>Register is meandering and associative. Jim steps into philosophy or gossip; the letter drifts into the "old man muses" tone.</think>
      realization → <think>Register is quietly conclusive, humble, a note landed. Jim now sees the small point of the letter; he does not force it.</think>

    Every excerpt is written IN Jim's voice: warm, wry, digressive,
    gossipy, third-hand. Jim is never inside another character's head.
    Southwick and Sandy are Jim's usual sources — they can be named as
    who told him what. Jim NEVER uses "I" to speak as anyone but himself.
  """

  # Narrative-story structure — for shortform fiction whose peer pipe
  # generates as one continuous story. 5 acts, each with 2-3 seed
  # paragraphs illustrating tone.
  story: """
    I write a story spine in 5 acts:
      setup         — establishes the character and their normal world.
      complication  — the disruption / stakes emerge.
      escalation    — pressure mounts; earlier choices harden.
      climax        — the moment of decision or confrontation.
      resolution    — how the character stands after the choice.
    Each act carries 2-3 short seed paragraphs (3-4 sentences each) written
    in the intended voice + register. The seeds are ORIENTATION — the peer
    pipe reads them to decide how the finished story sounds, so they hold
    tone, cadence, vocabulary, but do NOT hold the plot beat-for-beat.
    Section headers on their own line ending with a colon. No numbering.
  """

  # Spy-adventure structure — 5 acts oriented around a mission.
  spystory: """
    I write a spy-adventure spine in 5 acts:
      cover         — the operative's cover identity + the mission brief.
      contact       — the first meeting with an asset / mark / adversary.
      complication  — the plan begins to fail; something the operative did not expect.
      chase         — the physical/technical/social pursuit; kinetic beat.
      catch         — the resolution — extraction, capture, betrayal, or twist.
    Each act carries 2-3 short seed paragraphs (3-4 sentences each) that
    hold the operational tone, terse dialogue register, and physicality
    a spy story needs. Section headers on their own line ending with a
    colon. No numbering.
  """

  # Voyage / Celarien multi-chapter arc — a whole novel-length spine
  # expressed as chapter_purpose lines. Structured as acts×chapters.
  # Matches CELARIEN.md's 4-act × 4-chapter default (16 chapters).
  voyage: """
    I write a voyage spine as a 4-act × 4-chapter arc (16 chapter_purpose
    lines total). Each line is ONE crisp declarative sentence that names
    what the chapter must accomplish (character revelation, world reveal,
    beat landed, tone shift). No plot spoilers past the chapter itself.
    The 4 acts are named:
      Act I  — Departure   (chapters 1-4:   world-setup + inciting event)
      Act II — Passage     (chapters 5-8:   trials that reshape the traveler)
      Act III— Descent     (chapters 9-12:  crisis / lowest point)
      Act IV — Return      (chapters 13-16: transformation + homecoming)
    Structure: one line reading `## Act I — Departure`, then four lines
    reading `chapter_purpose: <one sentence>`. Repeat for each act.
    No numbering on chapters; the position under an act header is the
    chapter number. Sentences average 15-25 words. Vocabulary stays
    consistent with the brief's setting.
  """

# 2026-09-25 — Freeform variant of runCapability (no JSON schema).
# The spine capability generates 500-2500 words of structured text
# and doesn't want the runCapability's JSON-rescue machinery. Same
# GPU-claim guarantees, same session, plain text return.
_runFreeformUnguarded = (capabilityName, taskPrompt, opts = {}) ->
  session   = await getSession()
  prefill   = opts.thinkPrefill ? thinkPrefillFor[capabilityName] ? ''
  maxTokens = opts.maxTokens ? 2500
  temp      = opts.temperature ? 0.55
  topP      = opts.topP ? 0.9
  result = await session.generate buildChatML(taskPrompt),
    maxTokens:    maxTokens
    temperature:  temp
    topP:         topP
    raw:          true
    no_thinking:  true
    thinkPrefill: prefill
  stripThink String(result.text ? '')

runFreeform = (capabilityName, taskPrompt, opts = {}) ->
  gpuClaim  = require './gpu_claim'
  timeoutMs = Number(opts.gpuClaimTimeoutMs ? process.env.GPU_CLAIM_TIMEOUT_MS ? 120_000)
  ticket    = null
  try
    ticket = await gpuClaim.claim { tag: "helper.#{capabilityName}", timeoutMs }
  catch err
    return { ok: false, error: "gpu_claim: #{err?.message ? err}" }
  try
    text = await _runFreeformUnguarded capabilityName, taskPrompt, opts
    { ok: true, capability: capabilityName, text: String(text ? '').trim() }
  finally
    gpuClaim.release ticket

# Register the diary/story/spystory/voyage prefills under a single
# `spine` capability so the mutex tag is uniform. Kind-specific text
# lives in SPINE_PREFILLS; the runtime prefill is picked per call.
thinkPrefillFor.spine = ''  # dynamically filled by spine()

# --- Post-processor: diary <think> injection (Path A, 2026-09-25) --------
# Chat-tuned Qwen won't emit literal <think>...</think> in output when
# instructed to (it's a reserved metadata token). Solution: harness
# injects them deterministically after generation. Emotions are
# intrinsic to the section role — same for every diary — so this
# is a fixed table, not a per-brief computation.
#
# Downstream storacle / voice_test reads a spine that HAS real <think>
# blocks; the model treats each as its own mid-stream reasoning when
# generating the actual story text. Beat-level steering that survives
# from spine to story (evidence: think_steer_probe 3.5/4 on 1.7B).
DIARY_SECTION_EMOTIONS =
  scene:       "Register is settled, warmly digressive, unhurried gossip. Jim is comfortable and observational, not yet in motion."
  arrival:     "Register sharpens with curiosity. Jim leans in, still warm but expectant. Something has landed."
  disturbance: "Register is keenly attentive with a wobble underneath. Jim is not upset yet — he is drawn in, sensing there is something worth telling."
  reflection:  "Register is meandering and associative. Jim steps into philosophy or gossip; the letter drifts into the 'old man muses' tone."
  realization: "Register is quietly conclusive, humble, a note landed. Jim now sees the small point of the letter; he does not force it."

DIARY_SECTIONS = ['scene', 'arrival', 'disturbance', 'reflection', 'realization']

# 2026-09-25: extend Path A to story/spystory/voyage. Section names
# match the beat labels the SPINE_PREFILLS instruct the model to
# emit. Voyage clauses are per-Act (4 total), not per-chapter (16
# would be too many; per-Act is where the emotional arc lives).
SPINE_SECTION_NAMES =
  diary:    DIARY_SECTIONS
  story:    ['setup', 'complication', 'escalation', 'climax', 'resolution']
  spystory: ['cover', 'contact', 'complication', 'chase', 'catch']
  voyage:   ['departure', 'passage', 'descent', 'return']

# Injects <think>emotion</think> on its own line immediately after each
# section header. Recognizes headers that appear as a bare word or with
# a trailing colon, in any case, allowing for trailing whitespace.
# Only injects for sections in DIARY_SECTIONS. Never double-injects.
# Second-pass generation of per-section "observation → affect" clauses.
# 2026-09-25: fixed emotion table produced valid steering but no story
# hook — the clause said HOW Jim felt but not WHY, so downstream
# storacle got a mood without an anchor. Solution: after the diary
# body is written, ask the helper for one short clause per section
# grounded in what actually happens in that section. Fallback to the
# fixed table if the second pass returns garbage or is missing rows.
# Kept as its own function for two reasons: (a) called from spine()
# once per diary generation; (b) easy to swap for option 2 (inline
# emit) later without touching the injector's regex.
# Reject markers for clauses that drifted into poetry. 4B-Instruct
# defaults to soft-writer flourishes ("like a bell in a stone church",
# "as if the room had been holding its breath") — those defeat the
# whole point of a mid-stream steering directive, which is a plain
# factual anchor. A clause containing any of these substrings gets
# rejected and the derive step retries.
POETIC_MARKERS = [
  ' like a '
  ' like an '
  ' like the '
  ' as if '
  ' as though '
  ' — a '   # em-dash "— a signal" pattern
  ' – a '   # en-dash variant
  ' as a '
  ' as an '
]
isPoeticClause = (clause) ->
  return false unless clause?.length
  lc = ' ' + String(clause).toLowerCase() + ' '
  for marker in POETIC_MARKERS
    return true if lc.indexOf(marker) isnt -1
  false

deriveSpineThinkClauses = (kind, spineText, brief) ->
  return {} unless spineText?.length
  sections = SPINE_SECTION_NAMES[kind]
  return {} unless sections?.length
  who = switch kind
    when 'diary' then 'Jim'
    else              'the protagonist'
  sectionList = sections.join(' / ')
  exampleLines = sections.map((s) -> "      #{s}: because ..., #{who} ...").join('\n')
  clausePrompt = """
    You are producing INTERNAL steering directives for a downstream
    story generator. These are not prose. They are anchors.

    HARD RULES (violation = failure):
      1. NO similes. Do not write "like a X", "like an X", "like the X",
         "as if", "as though", "as a X".
      2. NO metaphors. Do not compare one thing to another. Do not
         say a thing "was" something it is not literally.
      3. NO em-dash asides, no "— a signal", no semicolons.
      4. BOTH halves of the clause — the observation AND the affect —
         must be plain factual language. Name concrete nouns and
         events already present in the section text.
      5. Short. If you cannot say it plainly, use fewer words.

    Below is a #{sections.length}-section #{kind} spine. For each
    section, produce ONE short clause of the form:

      because <one specific observation from THAT section>, #{who} <affect>

    The affect is a plain verb-phrase: feels uneasy / grows tender /
    gets curious / drifts into memory / lands quietly / hardens /
    hesitates / relaxes / sharpens / softens.

    EXAMPLES (good):
      scene: because Southwick has a beer and no place to be, Jim relaxes
      arrival: because the daughter says the organ played at 3am, Jim sharpens
    EXAMPLES (BAD — do not do this):
      scene: because the pipes were like old bones in the dark, Jim feels uneasy
      arrival: because the room hushed — a bell in a cave — Jim listens

    Output EXACTLY #{sections.length} lines, no blank lines, in
    this exact order, each prefixed with the section name (#{sectionList})
    and a colon:

#{exampleLines}

    Spine:
    #{spineText}
  """
  # Retry loop: if any clause reads poetic (matches POETIC_MARKERS),
  # regenerate. Cap at 3 attempts. Keep whichever attempt was cleanest.
  altRe = new RegExp "^\\s*(#{sections.join('|')})\\s*:\\s*(.+?)\\s*$", 'i'
  bestClauses = {}
  bestBadCount = Infinity
  for attempt in [1, 2, 3]
    result = await runFreeform "spine.#{kind}.think_clauses", clausePrompt,
      thinkPrefill: ''
      maxTokens:    500
      temperature:  0.35 + 0.1 * (attempt - 1)  # nudge sampling on retries
      topP:         0.9
    unless result?.ok
      continue
    clauses = {}
    for line in String(result.text ? '').split('\n')
      m = altRe.exec line
      continue unless m?
      clauses[m[1].toLowerCase()] = m[2].trim()
    badCount = 0
    badCount += 1 for own _, c of clauses when isPoeticClause(c)
    if badCount < bestBadCount
      bestClauses = clauses
      bestBadCount = badCount
    break if badCount is 0
  # Strip any surviving poetic clauses so the injector falls back to
  # the fixed affect table for those sections. Better a bland "attentive"
  # than a nonsense simile in a steering directive.
  for own section, clause of bestClauses when isPoeticClause(clause)
    console.warn "[spine.#{kind}.think_clauses] dropped poetic clause for '#{section}': #{clause}"
    delete bestClauses[section]
  bestClauses

# Back-compat wrapper for diary-only callers.
deriveDiaryThinkClauses = (diaryText, brief) ->
  deriveSpineThinkClauses 'diary', diaryText, brief

injectSpineThinkBlocks = (kind, text, overrides) ->
  return '' unless text?.length
  overrides ?= {}
  sections = SPINE_SECTION_NAMES[kind]
  return String(text) unless sections?.length
  lines = String(text).split '\n'
  out = []
  # Match a section name as a bare word or with trailing colon, in any
  # case. For voyage the model writes "## Act I — Departure" style
  # headers — the alternation includes the beat name (Departure etc.)
  # so we anchor on THAT, not the roman numeral, which the model has
  # been observed to typo (Act D — Return).
  altPat = sections.join('|')
  # Voyage headers are markdown "## Act I — Departure" — require the
  # `## Act <num> — ` prefix so the section word alone in body text
  # (e.g. "Passage" mentioned in prose) doesn't get falsely matched.
  # Diary / story / spystory use bare `SectionName:` headers.
  headerRe = if kind is 'voyage'
    new RegExp "^(\\s*)#+\\s*Act\\s+\\S+\\s*[—-]\\s*(#{altPat})\\s*(:?)\\s*(.*)$", 'i'
  else
    new RegExp "^(\\s*)(#{altPat})\\s*(:?)\\s*(.*)$", 'i'
  i = 0
  while i < lines.length
    line = lines[i]
    m = headerRe.exec line
    unless m?
      out.push line
      i += 1
      continue
    indent  = m[1] ? ''
    section = m[2].toLowerCase()
    colon   = m[3] ? ''
    rest    = (m[4] ? '').trim()
    # Overrides win when the second-pass derivation produced a clause
    # for this section; otherwise fall back to the diary affect table
    # (only defined for diary — other kinds emit a generic placeholder
    # if the second-pass parse missed a section).
    fallback = DIARY_SECTION_EMOTIONS[section] ? "attentive"
    emotion = overrides[section] ? fallback
    # Header goes on its own line so the <think> block sits between
    # header and content — that's the shape the downstream steering
    # relies on. Preserve the ORIGINAL header shape (e.g.
    # `## Act I — Departure` for voyage) by keeping the line prefix
    # up to where inline content starts. If content is inline, split
    # it off; otherwise keep the header line intact.
    headerLine = if rest.length then line.slice(0, line.length - rest.length).replace(/\s+$/, '') else line
    out.push headerLine
    # Peek ahead for existing <think> so re-processing is idempotent.
    hasInlineThink = rest.length and /^<think>/i.test(rest)
    if hasInlineThink
      out.push rest if rest.length
    else
      j = i + 1
      j += 1 while j < lines.length and lines[j].trim().length is 0
      hasNextThink = j < lines.length and /^\s*<think>/i.test(lines[j])
      unless hasNextThink
        out.push "<think>#{emotion}</think>"
      out.push rest if rest.length
    i += 1
  out.join '\n'

spine = (brief, kind, opts = {}) ->
  return { ok: false, error: "spine kind must be one of: #{SPINE_KINDS.join(', ')}" } unless kind in SPINE_KINDS
  return { ok: false, error: 'spine brief required (1-3 sentences describing character + situation)' } unless brief? and String(brief).trim().length
  brief = String(brief).trim()

  # Extra caller-supplied constraints (character name, setting era, etc.)
  extra = String(opts.constraints ? '').trim()

  # Prefill is the structural directive for this kind.
  prefill = SPINE_PREFILLS[kind]

  taskPrompt = """
    Generate a #{kind} spine following the structural rules in my think
    block. Nothing outside the sections — no title, no meta commentary.
    Output ONLY the spine content as it will be written to
    `#{kind}.txt`. Section headers use the exact names from the rules.

    Brief:
    #{brief}
    #{if extra.length then "\n    Additional constraints:\n    #{extra}" else ''}

    Spine:
  """

  # Spines vary in length by kind — diary is ~1200 words of excerpts,
  # voyage is ~400 words of chapter-purpose lines. Give voyage more
  # temperature (variety across 16 lines) and diary more room.
  runOpts =
    thinkPrefill: prefill
    maxTokens: switch kind
      when 'diary'    then 3000
      when 'story'    then 2400
      when 'spystory' then 2400
      when 'voyage'   then 1200
    temperature: switch kind
      when 'voyage' then 0.7
      else               0.55
    topP: 0.9

  result = await runFreeform "spine.#{kind}", taskPrompt, runOpts
  return result unless result.ok

  # Post-process: for diary, inject inline <think>emotion</think>
  # blocks after each section header (Path A, 2026-09-25). Model
  # writes CONTENT; harness writes STEERING. Other kinds pass through
  # unchanged for now — spystory / story may get similar treatment
  # in a follow-up once we prove the diary lifecycle end-to-end.
  processed = result.text
  postProcessed = false
  thinkClauses = null
  if SPINE_SECTION_NAMES[kind]?
    # Second pass: derive per-section "because X, <who> Y" clauses
    # from the just-generated spine body. Falls back silently for any
    # section the model didn't emit cleanly.
    thinkClauses = await deriveSpineThinkClauses kind, result.text, brief
    processed = injectSpineThinkBlocks kind, result.text, thinkClauses
    postProcessed = processed isnt result.text

  {
    ok:       true
    kind:     kind
    text:     processed
    meta:
      brief:            brief
      constraints:      extra
      generated_at:     new Date().toISOString()
      model_dir:        process.env.HELPER_LLM_MODEL_DIR ? DEFAULT_MODEL_DIR
      adapter_path:     DEFAULT_ADAPTER_PATH
      char_count:       processed.length
      raw_char_count:   result.text.length
      post_processed:   postProcessed
      think_clauses:    thinkClauses
      capability:       "spine.#{kind}"
  }

# --- exports -------------------------------------------------------------
module.exports = {
  classify_failure
  summarize_log
  schedule
  grade_role
  grade_invariants
  spine
  SPINE_KINDS
  SPINE_PREFILLS
  dispose
  # Escape hatch for future capabilities and for tests that want to hold
  # the session across many calls.
  getSession
  FAILURE_CATEGORIES
  SCHEDULE_ACTIONS
  DIARY_ROLES
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
      process.stderr.write "capabilities: classify_failure, summarize_log, schedule\n"
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
      when 'schedule'
        # `schedule` expects a scenario object; from CLI accept a JSON
        # string OR a path prefix (@...). The @-prefix handling above
        # already read the file into `input` as a string.
        parsed = try JSON.parse(input) catch then input
        await schedule(parsed)
      else
        process.stderr.write "unknown capability: #{capability}\n"
        process.exit 2
    process.stdout.write JSON.stringify(result) + '\n'
    dispose()
    process.exit(if result.ok then 0 else 1)
  main().catch (err) ->
    process.stderr.write "FATAL: #{String(err?.stack ? err)}\n"
    process.exit 1
