###
  tools/pipe_probe.coffee — filesystem probes about a pipe's state.

  Per CONVENTIONS "fs stinginess": "does this artifact exist" probes belong
  in a tool, not in a step script's body. Moved out of
  writer_scheduler_ite 2026-11-07 (the "dispatcher exception" its header
  claimed was never sanctioned — jahbini ruling, see CONVENTIONS).

  Tool contract: stateless, ordinary args in / values out, fs allowed.
###

fs   = require 'fs'
path = require 'path'

# The pipe's directory if it exists, else null.
resolvePipeDir = (pipesRoot, pipe) ->
  dir = path.join String(pipesRoot), String(pipe)
  if (try fs.existsSync(dir) and fs.statSync(dir).isDirectory() catch then false) then dir else null

# A recipe is "done" for a pipe when its characteristic artifact exists —
# the writer scheduler's no-hot-loop guard.
recipeDone = (pipeDir, recipe) ->
  nonEmpty = (p) -> try (fs.statSync(p).size > 0) catch then false
  switch recipe
    when 'newborn'
      # bootstrap-and-audition done ⇔ the entrance certificate was written
      # (mark_entrance_pending_ite). The pipe then sits in the crib for a
      # human grade (→ continue / rejected).
      fs.existsSync(path.join(pipeDir, 'out', 'certificate.yaml'))
    when 'elementary'
      # the whole point: elementary produced a usable LoRA adapter.
      fs.existsSync(path.join(pipeDir, 'build', 'adapter', 'adapters.safetensors'))
    when 'storacle'
      nonEmpty(path.join(pipeDir, 'out', 'storacle.txt'))
    when 'sat_ladder'
      nonEmpty(path.join(pipeDir, 'out', 'sat_history.jsonl'))
    else false

module.exports = {resolvePipeDir, recipeDone}
