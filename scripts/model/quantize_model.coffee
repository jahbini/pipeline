###
  quantize_model.coffee  —  BASE_ITE / DOWNLOAD_MODEL pipeline step
  =================================================================

  Quantizes a downloaded HuggingFace model into MLX format via the
  in-process LLM door: `L.callLLM({op:'quantize', ...})` reaches
  `mlx/quantize.coffee::quantizeModelDir`. No Python, no
  `mlx_lm convert` subprocess. The output directory is
  self-contained: no further HF traffic is required to load or run
  the model.

  **Step params:**
    src_dir         default: build/model       (input — the HF download)
    quantized_dir   default: build/model4      (output — MLX-formatted)
    q_bits          default: 4                 (quantization bit-width)
    group_size      default: 64                (quantization group size)
    skip_quantize   default: false             (true to skip this step)

  After this step succeeds, you can `rm -rf $src_dir` to reclaim
  disk; the quantized dir alone is enough for inference.
###
fs = require 'fs'
path = require 'path'

@step =
  desc: 'Quantize a downloaded model to MLX format (default 4-bit) via callLLM.'

  action: (S) ->
    if S.param('skip_quantize', false) is true
      console.log "[#{S.stepName}] skip_quantize=true; nothing to do"
      S.done()
      return

    srcDir       = S.param 'src_dir',       'build/model'
    quantizedDir = S.param 'quantized_dir', 'build/model4'
    qBits        = S.param 'q_bits',        4
    groupSize    = S.param 'group_size',    64

    srcAbs = path.resolve process.cwd(), srcDir
    dstAbs = path.resolve process.cwd(), quantizedDir

    throw new Error "[#{S.stepName}] source dir not found: #{srcAbs}" unless fs.existsSync(srcAbs)

    # Provenance-checked skip: if the target already has a
    # model.safetensors + a config.json whose quantization block matches
    # our requested bits + group_size, we've already done this work.
    # Same discipline as download_model's idempotency check.
    if fs.existsSync(dstAbs)
      priorConfig = null
      try priorConfig = JSON.parse fs.readFileSync(path.join(dstAbs, 'config.json'), 'utf8') catch then null
      priorSt = path.join(dstAbs, 'model.safetensors')
      q = priorConfig?.quantization
      if q? and q.bits is qBits and q.group_size is groupSize and fs.existsSync(priorSt)
        stBytes = fs.statSync(priorSt).size
        console.log "[#{S.stepName}] target already quantized (bits=#{q.bits}, group_size=#{q.group_size}, #{(stBytes/1024/1024/1024).toFixed 2} GB) — skipping"
        S.done()
        return
      console.log "[#{S.stepName}] removing prior quantized dir #{dstAbs} (missing/mismatched)"
      fs.rmSync dstAbs, recursive: true, force: true

    console.log "[#{S.stepName}] quantizing #{srcAbs} → #{dstAbs} (#{qBits}-bit, groupSize=#{groupSize})"
    result = await S.callLLM
      op:        'quantize'
      sourceDir: srcAbs
      targetDir: dstAbs
      bits:      qBits
      groupSize: groupSize

    gb = (result?.outputBytes ? 0) / 1024 / 1024 / 1024
    console.log "[#{S.stepName}] complete: #{result?.tensorsQuantized ? '?'} tensors quantized, #{result?.tensorsCopied ? '?'} copied verbatim, #{gb.toFixed 2} GB written"

    S.done()
    return
