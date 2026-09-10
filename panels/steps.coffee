###
  panels/steps.coffee  —  framework-tier: state/step-*.json summary
  ================================================================

  Every step writes `<CWD>/state/step-<name>.json` recording status,
  started_at, finished_at, duration_ms, and a summary. This panel
  surfaces those as a sortable table so a human can see at a glance
  which steps are done / running / crashed.

  See GPT/pipeline_runner.md § "state/ ↔ params/ correspondence".
###

exports.panel =
  title:       'Steps'
  # 'custom' — the existing `renderSteps` bespoke renderer (in
  # ui/index.html) also feeds `refreshPipelineGraph`, so we keep the
  # rich row shape rather than compressing to the generic table
  # renderer. Row objects are passed through untouched from the
  # underlying state/step-*.json files.
  render_hint: 'custom'
  # 'after-history' places it between Run History and Stories.
  column:      'after-history'
  eager:       true
  poll_seconds: 5

  applies: (ctx) ->
    ctx.fs.existsSync(ctx.path.join(ctx.CWD, 'state'))

  endpoint: (ctx) ->
    {fs, path, CWD, helpers} = ctx
    stateDir = path.join CWD, 'state'
    return { rows: [] } unless fs.existsSync(stateDir)

    names = fs.readdirSync(stateDir).filter (n) -> /^step-.*\.json$/.test(n)
    rows = []
    for name in names
      row = helpers.readJson? path.join(stateDir, name), {}
      continue unless row?
      rows.push row
    rows.sort (a, b) -> String(a.step ? '').localeCompare String(b.step ? '')
    { rows: rows }
