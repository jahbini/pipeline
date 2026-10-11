###
  mark_sat_pending_ite.coffee — write an ungraded SAT-scan certificate.

  Final step of elementary.yaml. Signals that LoRA training completed
  and the pipe is now ready for the human-driven SAT scan (parameter /
  adapter / chunk ablation sweep). Writes `out/certificate.yaml` with:
    stage: elementary
    grade.verdict: ''        # empty = ungraded marker
  The puppeteer's certificate_scan_ite picks this up, sets
  `cert_pending: true`, and the writer UI surfaces the pipe under
  "Needs certificate" with a link that launches the standalone
  `sat_scan` recipe.

  No ablation runs here — only a marker. The SAT scan runs later,
  launched by the human from the UI.
###

fs   = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

@step =
  desc: "Write ungraded SAT-scan certificate so human can run sat_scan."

  action: (L) ->
    pipeName = path.basename(process.cwd())
    outDir = path.join(process.cwd(), 'out')
    fs.mkdirSync outDir, {recursive: true}

    cert =
      pipe:  pipeName
      stage: 'elementary'
      test:  {}
      grade:
        verdict:   ''
        comments:  ''
        graded_at: null
        graded_by: null
      created_at: new Date().toISOString()
      created_by: 'mark_sat_pending_ite'

    certPath = path.join(outDir, 'certificate.yaml')
    fs.writeFileSync certPath, yaml.dump(cert), 'utf8'
    console.log "[#{L.stepName}] wrote ungraded SAT-scan certificate → #{certPath}"
    L.done?()
    return
