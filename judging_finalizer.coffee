###
  judging_finalizer.coffee
  Evaluates multiple training runs in a "daily" directory,
  runs their evaluation pipelines, computes scores,
  and issues a final judgment.
###

fs   = require 'fs'
path = require 'path'
{ spawnSync } = require 'child_process'

DAILY_DIR = process.argv[2]
if not DAILY_DIR
  console.error "Usage: coffee judging_finalizer.coffee /path/to/daily"
  process.exit(1)

EVALUATOR = path.join(process.env.EXEC ? '.', 'pipeline_evaluator.coffee')

# Run evaluator in subdir
runEvaluator = (subdir) ->
  console.log "▶️ Evaluating #{subdir}"
  proc = spawnSync "coffee", [EVALUATOR], cwd: subdir, stdio: 'inherit'
  return proc.status is 0

# Parse JSON analysis (from eval_out/analysis.json)
loadAnalysis = (subdir) ->
  f = path.join(subdir, 'eval_out', 'analysis.json')
  if fs.existsSync(f)
    try
      return JSON.parse(fs.readFileSync(f, 'utf8'))
    catch e
      console.error "! Bad analysis.json in #{subdir}", e.message
  null

# Heuristic scoring function
scoreRun = (analysis) ->
  return 0 unless analysis?.by_mode?.length

  # Example: score = (lexical diversity) – (memorization rate penalty)
  # Take averages across modes
  div = 0; mem = 0; n = 0
  for mode in analysis.by_mode
    div += (mode.distinct2_mean ? 0)
    mem += (mode.mem_sub_rate ? 0)
    n += 1
  avgDiv = if n then div/n else 0
  avgMem = if n then mem/n else 0

  raw = avgDiv*100 - avgMem*50
  Math.round(raw*100)/100

# Main loop
runs = fs.readdirSync(DAILY_DIR).filter (f) ->
  fs.statSync(path.join(DAILY_DIR, f)).isDirectory()

results = []
for run in runs
  runPath = path.join(DAILY_DIR, run)
  continue unless fs.existsSync(path.join(runPath, 'eval_out'))

  ok = runEvaluator(runPath)
  continue unless ok

  analysis = loadAnalysis(runPath)
  score = scoreRun(analysis)
  results.push { run, score, analysis }

# Rank runs
results.sort (a,b) -> b.score - a.score

# Outputs
finalJson = path.join(DAILY_DIR, 'final_scores.json')
fs.writeFileSync(finalJson, JSON.stringify(results, null, 2), 'utf8')

finalMd = path.join(DAILY_DIR, 'final_report.md')
md = "# Final Judgment Report\n\n"
for r, i in results
  tag = if i is 0 then "🏆 Champion of the Directory" else ""
  md += "## #{r.run} #{tag}\n"
  md += "- Score: #{r.score}\n"
  if r.analysis?
    md += "- Distinct2: #{r.analysis.by_mode.map((m)->m.distinct2_mean).join(', ')}\n"
    md += "- Memorization: #{r.analysis.by_mode.map((m)->m.mem_sub_rate).join(', ')}\n"
  md += "\n"

fs.writeFileSync(finalMd, md, 'utf8')

console.log "🌟 Judgment complete."
console.log "→ #{finalJson}"
console.log "→ #{finalMd}"
