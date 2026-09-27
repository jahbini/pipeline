###
  scripts/spine/spine.coffee  —  SPINE pipeline step
  ==================================================
  Generates a story spine (diary / story / spystory / voyage) by
  calling helper_llm.spine() with a brief + optional constraints,
  runs the second-pass "because X, <who> Y" clause derivation, and
  writes both the raw spine (with injected <think> blocks) and the
  provenance manifest to the pipe's out/ directory.

  Also copies the finished spine to the canonical spine library at
  ~/writer/data/spines/<slug>_<kind>.txt so downstream storacle /
  voice_test runs find it in a stable place.

  Contract:
    needs: []
    makes: spine_text, spine_meta
    params:
      kind         → 'diary' | 'story' | 'spystory' | 'voyage'
      brief        → 1-3 sentence character + situation description
      constraints  → optional additional constraints (voice, POV, etc.)
      slug         → filename prefix for the spine library copy
###

fs   = require 'fs'
path = require 'path'
os   = require 'os'

helper = require '../../mlx/helper_llm'

@step =
  desc: "Generate a story spine via helper_llm.spine(kind, brief, constraints)"

  action: (L) ->
    kind        = String(L.param('kind', '') ? '').trim().toLowerCase()
    brief       = String(L.param('brief', '') ? '').trim()
    constraints = String(L.param('constraints', '') ? '').trim()
    slug        = String(L.param('slug', 'spine') ? 'spine').trim()

    validKinds = ['diary', 'story', 'spystory', 'voyage']
    unless kind in validKinds
      throw new Error "[#{L.stepName}] kind must be one of: #{validKinds.join(', ')} (got: #{kind})"
    unless brief.length
      throw new Error "[#{L.stepName}] brief must be a non-empty string"

    console.log "[spine] kind=#{kind} slug=#{slug} brief.chars=#{brief.length}"

    t0 = Date.now()
    result = await helper.spine brief, kind, {constraints}
    unless result?.ok
      throw new Error "[#{L.stepName}] helper.spine returned error: #{result?.error ? 'unknown'}"

    elapsed = ((Date.now() - t0) / 1000).toFixed(1)
    thinkCount = (result.text.match(/<think>/g) ? []).length
    console.log "[spine] done in #{elapsed}s · #{result.text.length} chars · #{thinkCount} <think> blocks"

    L.make 'spine_text', result.text
    L.make 'spine_meta',
      kind:            kind
      slug:            slug
      brief:           brief
      constraints:     constraints
      elapsed_s:       Number(elapsed)
      char_count:      result.text.length
      think_block_ct:  thinkCount
      think_clauses:   result.meta?.think_clauses ? null
      model_dir:       result.meta?.model_dir ? null
      adapter_path:    result.meta?.adapter_path ? null
      post_processed:  result.meta?.post_processed ? false
      generated_at:    result.meta?.generated_at ? new Date().toISOString()

    libDir = path.join(os.homedir(), 'writer', 'data', 'spines')
    try
      fs.mkdirSync libDir, {recursive: true}
      libPath = path.join libDir, "#{slug}_#{kind}.txt"
      fs.writeFileSync libPath, result.text, 'utf8'
      console.log "[spine] library copy: #{libPath}"
    catch e
      console.warn "[spine] spine-library copy failed: #{e.message} (out/ artifact still written)"

    L.done()
    return
