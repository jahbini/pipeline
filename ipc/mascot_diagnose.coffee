# ── mascot_diagnose — route a pipe termination to the mascot (helper) LLM ──
#
# The mascot is the helper LLM (`HELPER_LLM_MODEL_DIR`, a Qwen3-4B-Instruct
# on the controller). It already exposes the three tools a termination
# needs: classify_failure, summarize_log, and schedule (→ a SCHEDULE_ACTION
# recommendation). Decision 2026-10-23: EVERY pipe termination — clean or
# not — is sent here for a diagnosis; the puppeteer's scheduler then
# decides what to do (restart / pause / hospital / graduate / …). We only
# diagnose + recommend; we never restart.
#
# Best-effort: each sub-call degrades to a safe default so a flaky mascot
# never blocks the controller. NB: helper_llm.runCapability already takes
# the file-based `gpu_claim` around each call, so the mascot serializes on
# the GPU on its own (independent of the memo `sys/gpu_lease`).
#
# Returns {category, confidence, summary, recommendation, target_pipe,
#          target_recipe, reason, raw}.

diagnose = (info = {}) ->
  helper    = require '../mlx/helper_llm'
  errorText = String(info.reason ? info.errorText ? '').trim()
  logTail   = String(info.logTail ? '').trim()
  pipe      = info.pipe ? 'unknown'
  phase     = info.phase ? '?'

  # A clean finish is a termination too, but not a failure. Still return a
  # diagnosis shape so the scheduler has a uniform input; recommend 'wait'
  # (the scheduler picks the next work for an idle, healthy pipe).
  if phase is 'exited' and not errorText.length
    return Promise.resolve
      category: 'done', confidence: 1.0
      summary: "pipe #{pipe} finished its recipe cleanly"
      recommendation: 'wait', target_pipe: pipe, target_recipe: null, reason: 'clean exit', raw: {}

  signal = errorText or "pipe #{pipe} terminated with phase=#{phase} and no error text"
  scenario = "Pipe '#{pipe}' on #{info.host ? 'peer'} terminated (phase=#{phase}, lastStep=#{info.lastStep ? '?'}). Error: #{errorText or '(none)'}. Pick the scheduler action."

  # SEQUENTIAL — never fire two mascot generations at once. node-mlx
  # runs one generation per process; `gpu_claim` is reentrant per-pid so
  # it does NOT serialize same-process calls, meaning a Promise.all here
  # would launch concurrent generates and hang. Await each in turn.
  Promise.resolve()
    .then -> helper.classify_failure(signal).catch (e) -> {category: 'unknown', confidence: 0, summary: "classify failed: #{e?.message ? e}"}
    .then (cls) ->
      sp = if logTail.length then helper.summarize_log(logTail).catch(-> null) else Promise.resolve(null)
      sp.then (sum) -> {cls, sum}
    .then ({cls, sum}) ->
      helper.schedule(scenario).catch((e) -> {action: 'escalate', reason: "schedule failed: #{e?.message ? e}"})
        .then (sch) -> {cls, sum, sch}
    .then ({cls, sum, sch}) ->
      category:       cls?.category ? 'unknown'
      confidence:     cls?.confidence ? null
      summary:        sum?.summary ? cls?.summary ? null
      recommendation: sch?.action ? 'escalate'
      target_pipe:    sch?.target_pipe ? pipe
      target_recipe:  sch?.target_recipe ? null
      reason:         sch?.reason ? null
      raw: {classify: cls, summarize: sum, schedule: sch}

module.exports = {diagnose}
