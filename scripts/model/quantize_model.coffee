###
  quantize_model.coffee  —  DOWNLOAD_MODEL pipeline step
  =====================================================

  Quantizes a downloaded HuggingFace model into MLX format via
  `python -m mlx_lm convert`. The output directory is
  self-contained: no further HF traffic is required to load or run
  the model. This is the step that breaks the dependency on HF's
  cache/symlink "protocol".

  **Step params:**
    src_dir         default: build/model       (input — the HF download)
    quantized_dir   default: build/model4      (output — MLX-formatted)
    q_bits          default: 4                 (quantization bit-width)
    skip_quantize   default: false             (true to skip this step)

  After this step succeeds, you can `rm -rf $src_dir` to reclaim
  disk; the quantized dir alone is enough for inference.
###
{ spawnSync } = require 'child_process'
fs = require 'fs'
path = require 'path'

resolvePython = ->
  candidates = [
    path.join(process.cwd(), '.venv', 'bin', 'python')
    path.join(process.cwd(), '.venv', 'bin', 'python3')
  ]
  for c in candidates when fs.existsSync(c)
    return c
  throw new Error "python not found at #{candidates[0]} — is the project's .venv set up?"

@step =
  name: 'quantize_model'
  desc: 'Quantize a downloaded model to MLX format (default 4-bit).'

  action: (M, stepName) ->
    if M.getStepParam(stepName, 'skip_quantize') is true
      console.log "[#{stepName}] skip_quantize=true; nothing to do"
      M.saveThis "done:#{stepName}", true
      return

    srcDir = M.getStepParam(stepName, 'src_dir') ? 'build/model'
    quantizedDir = M.getStepParam(stepName, 'quantized_dir') ? 'build/model4'
    qBits = M.getStepParam(stepName, 'q_bits') ? 4

    srcAbs = path.resolve process.cwd(), srcDir
    dstAbs = path.resolve process.cwd(), quantizedDir

    throw new Error "[#{stepName}] source dir not found: #{srcAbs}" unless fs.existsSync(srcAbs)

    # mlx_lm.convert refuses to overwrite an existing destination;
    # remove it first so the step is idempotent on re-run.
    if fs.existsSync(dstAbs)
      console.log "[#{stepName}] removing prior quantized dir #{dstAbs}"
      fs.rmSync dstAbs, recursive: true, force: true

    pythonPath = resolvePython()
    args = [
      '-m', 'mlx_lm', 'convert'
      '--hf-path', srcAbs
      '--mlx-path', dstAbs
      '--quantize'
      '--q-bits', String(qBits)
    ]

    console.log "[#{stepName}] quantizing #{srcAbs} → #{dstAbs} (#{qBits}-bit)"
    result = spawnSync pythonPath, args, encoding: 'utf8', stdio: 'inherit'

    if result.error?
      throw new Error "[#{stepName}] quantize failed: #{result.error.message}"
    if result.status isnt 0
      throw new Error "[#{stepName}] quantize failed: exit #{result.status}"

    console.log "[#{stepName}] complete: #{dstAbs}"
    M.saveThis "done:#{stepName}", true
    return
