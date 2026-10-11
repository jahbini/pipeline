###
  mark_entrance_pending_ite.coffee — write an ungraded entrance certificate.

  Final step of newborn.yaml. Replaces the embedded storacle audition.
  Writes `out/certificate.yaml` with:
    stage: newborn
    grade.verdict: ''        # empty = ungraded marker
  The puppeteer's certificate_scan_ite picks this up on its next pass,
  sets `cert_pending: true` on the pipe's state entry, and the writer
  UI surfaces the pipe under "Needs certificate" with a link that
  launches the standalone storacle recipe for human-driven testing.

  No model inference happens here — only a marker is written. The
  storacle test runs later, launched by the human from the UI, so the
  prompt/story can be adjusted per candidate rather than frozen at
  recipe-definition time.
###

fs   = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

@step =
  desc: "Write ungraded entrance certificate so human can run storacle."

  action: (L) ->
    pipeName = path.basename(process.cwd())
    outDir = path.join(process.cwd(), 'out')
    fs.mkdirSync outDir, {recursive: true}

    cert =
      pipe:  pipeName
      stage: 'newborn'
      test:
        prompt_text: 'Who does Anna love in {{{STORY}}}?'
        story_id:    'anna-played-piana-md'
      grade:
        verdict:   ''
        comments:  ''
        graded_at: null
        graded_by: null
      created_at: new Date().toISOString()
      created_by: 'mark_entrance_pending_ite'

    certPath = path.join(outDir, 'certificate.yaml')
    fs.writeFileSync certPath, yaml.dump(cert), 'utf8'
    console.log "[#{L.stepName}] wrote ungraded entrance certificate → #{certPath}"
    L.done?()
    return
