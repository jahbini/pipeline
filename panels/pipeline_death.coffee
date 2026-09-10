###
  panels/pipeline_death.coffee  —  framework-tier: pipeline.json
  =============================================================

  When the runner crashes it writes `<CWD>/pipeline.json` with the
  reason. A non-empty pipeline.json halts the next launch until
  removed (UI "Erase pipeline.json" button, or `rm ./pipeline.json`).
  See GPT/pipeline_runner.md § "state/ ↔ params/ correspondence".

  Panel returns null when there's no death record — the client can
  suppress the panel entirely in that case, which is what makes
  "Pipeline Death" invisible during a healthy run.
###

exports.panel =
  title:       'Pipeline Death'
  # 'custom' because the section needs an interactive "Erase
  # pipeline.json" button. The client-side hook
  # PANEL_CUSTOM_RENDERERS.pipeline_death (in ui/index.html) toggles
  # between the death-info box + button and an empty-state hint.
  render_hint: 'custom'
  # 'before-outputs' places it at the very top of the left column,
  # ahead of Outputs. Falls back to '#dynamic-panels' in projects
  # whose HTML shell doesn't declare that named slot.
  column:      'before-outputs'
  eager:       true
  poll_seconds: 3

  applies: -> true

  endpoint: (ctx) ->
    {fs, path, CWD, helpers} = ctx
    p = path.join CWD, 'pipeline.json'
    return { has_death: false } unless fs.existsSync(p)
    record = helpers.readJson? p, null
    return { has_death: false } unless record?
    {
      has_death: true
      status:    String(record.status ? '')
      by:        String(record.by ? '')
      reason:    String(record.reason ? '')
      timestamp: String(record.timestamp ? '')
    }
