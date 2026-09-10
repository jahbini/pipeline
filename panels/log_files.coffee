###
  panels/log_files.coffee  —  framework-tier: <CWD>/logs listing
  ==============================================================

  Every pipeline run stamps logs under `<CWD>/logs/<recipe>_HH_MM.log`
  (and `.err`). This panel lists them, marking entries touched since
  the current run started as `is_fresh`. Newer names first (sort
  descending on path — for `<recipe>_HH_MM.log` that keeps the
  most-recent run at the top).
###

exports.panel =
  title:       'Logs'
  # 'custom' because the section needs an interactive "Delete Log Files"
  # button next to the file list. The client-side hook
  # PANEL_CUSTOM_RENDERERS.log_files (in ui/index.html) renders the
  # button + falls back to renderFiles() for the list itself. If a
  # future project's UI doesn't want the button, add its own hook.
  render_hint: 'custom'
  column:      'left'
  eager:       true
  poll_seconds: 5
  collapsed_by_default: true

  applies: (ctx) ->
    ctx.fs.existsSync(ctx.path.join(ctx.CWD, 'logs'))

  endpoint: (ctx) ->
    {fs, path, CWD, helpers} = ctx
    logDir = path.join(CWD, 'logs')
    return { files: [] } unless fs.existsSync(logDir)

    runStart = ctx.run?.started_at ? null
    rows = []
    for entry in (helpers.listFiles?(logDir) ? [])
      continue unless entry? and entry.is_dir isnt true
      rows.push helpers.describeOutputFile? "logs/#{entry.name}", runStart
    rows.sort (a, b) -> String(b.path).localeCompare String(a.path)
    { files: rows }
