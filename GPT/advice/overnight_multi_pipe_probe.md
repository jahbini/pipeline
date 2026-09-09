# Overnight multi-pipe test — do not write a shell driver

## The trap

The natural thing when asked "run oracle_ite → reembed_clean → train_lora
→ storacle on all ten pipes overnight" is to write a bash driver that
loops over pipes and shells out to `pipeline_runner` for each one, with
a `/tmp/status.txt` side-channel so the UI can see progress.

That's exactly what I did on 2026-09-07 (`/tmp/overnight_test.sh`,
`/tmp/overnight_v2.sh`). The user's response: *"you are in charge of
provisioning these pipes"*, followed by a rundown of my framework
violations. Read `GPT/CONVENTIONS.md` — no Python, no side channels,
notes in `GPT/` not `.claude/`.

## The proper mechanism

**`~/puppeteer/config/run_queue.yaml`** is exactly this feature. The
step (`~/puppeteer/scripts/queue_run_ite.coffee`) is iterative,
resumable, respects per-pipe human state (`pause`/`hospital`/`rejected`
skip), records per-entry `sqlite_diff` reports, and supports
`on_failure: stop | continue | defer`.

Express the overnight queue as a `queue:` list in an override:

```yaml
# ~/puppeteer/override/run_queue.yaml
pipeline: run_queue

queue_run_ite:
  peer: mini
  default_pipe: null   # every entry names its own pipe
  on_failure: continue # per-pipe fail-fast is done by omitting the pipe from later entries
  poll_interval_seconds: 5
  max_wait_seconds: 3600

  queue:
    - {pipe: hf__qwen__qwen3-0-6b, recipe: oracle_ite}
    - {pipe: hf__qwen__qwen3-0-6b, recipe: reembed_clean}
    - {pipe: hf__qwen__qwen3-0-6b, recipe: train_lora}
    - {pipe: hf__qwen__qwen3-0-6b, recipe: storacle,
        ui_values:
          storacle.story_id:    anna-played-piana-md
          storacle.prompt_text: 'Who does Anna love in {{{STORY}}}'
          storacle.llm.temperature: 0.7
      }
    # ...repeat per pipe...
```

Then launch the puppeteer with `pipeline: run_queue`. Queue state lives
in `~/puppeteer/state/queue_state.json`; the puppeteer UI shows it
directly, and a crash resumes at the entry that was running.

## What "fail-fast per pipe" looks like in this model

The 2026-09-07 shell driver had a "skip remaining recipes when one
fails" rule. In `run_queue`, the equivalent is `on_failure: defer` (bad
entries move to the end of the queue for one retry) OR having the queue
generator pre-filter by human state (`hf_scan.yaml` already does this
for the "elementary" queue). Do NOT invent a new fail-fast mechanism at
the queue layer.

## What NOT to do

- No `/tmp/*.sh` drivers.
- No `/tmp/status.txt` side channels — the UI reads `queue_state.json`.
- No `nohup coffee pipeline_runner.coffee` outside a puppeteer-managed
  launch (the puppeteer owns process orchestration, not bash).
- No direct edits to `pipe_states.json`; use `POST /api/pipe_state` on
  the puppeteer UI or the equivalent script.
