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

path = require 'path'

@step =
  desc: "Write ungraded entrance certificate so human can run storacle."

  action: (L) ->
    pipeName = path.basename(process.cwd())

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

    # entrance_certificate is a makes-target (out/certificate.yaml). Hand it to
    # the ledger so the meta/yaml device materializes it. Writing the file via
    # fs.writeFileSync here (the prior behavior) was CLOBBERED by the runner
    # materializing the never-set memo value as the literal string `undefined`
    # — the 2026-11-09 "undefined certificate" bug. L.make is the contract.
    L.make 'entrance_certificate', cert
    console.log "[#{L.stepName}] wrote ungraded entrance certificate → out/certificate.yaml"
    L.done?()
    return
