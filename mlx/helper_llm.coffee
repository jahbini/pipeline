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
runCapability = (capabilityName, taskPrompt, opts = {}) ->
  session   = await getSession()
  prefill   = thinkPrefillFor[capabilityName] ? ''
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
      outputText =
        if typeof ex.expected_output is 'string' then ex.expected_output
        else JSON.stringify(ex.expected_output)
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
  runCapability 'schedule', task, {maxTokens: 1500, temperature: 0.2}

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

# --- exports -------------------------------------------------------------
module.exports = {
  classify_failure
  summarize_log
  schedule
  grade_role
  grade_invariants
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
