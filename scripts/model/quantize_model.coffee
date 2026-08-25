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

  **Pre-quantized-source detection**: if `src_dir` itself is already
  a quantized MLX model (its `config.json` has a `quantization` block
  matching our requested `q_bits`/`group_size`), we symlink
  `quantized_dir → src_dir` instead of trying to re-quantize —
  re-quantizing packed uint32 weights fails with an MLX kernel error
  (`affine_quantize_uint32_t_gs_*_b_*`). Common case: HF repos named
  like `mlx-community/<name>-4bit`.
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

    # Pre-quantized source detection: if src is already an MLX
    # quantized model with matching bits + group_size, symlink dst
    # to src instead of re-quantizing. Re-quantizing packed uint32
    # weights fails with `affine_quantize_uint32_t_gs_*_b_*`.
    srcConfig = null
    try srcConfig = JSON.parse fs.readFileSync(path.join(srcAbs, 'config.json'), 'utf8') catch then null
    srcQuant = srcConfig?.quantization
    if srcQuant? and srcQuant.bits is qBits and srcQuant.group_size is groupSize
      if srcAbs is dstAbs
        console.log "[#{S.stepName}] src already quantized (bits=#{srcQuant.bits}, group_size=#{srcQuant.group_size}) and src_dir == quantized_dir — nothing to do"
        S.done()
        return

      # If dst exists but isn't already a symlink pointing at src,
      # replace it. Consistent with the "prior quantized dir" cleanup
      # below.
      dstIsCorrectLink = false
      if fs.existsSync(dstAbs) or (try fs.lstatSync(dstAbs) catch then null)?
        try
          st = fs.lstatSync(dstAbs)
          if st.isSymbolicLink()
            resolved = path.resolve path.dirname(dstAbs), fs.readlinkSync(dstAbs)
            dstIsCorrectLink = resolved is srcAbs
        catch
          null
        unless dstIsCorrectLink
          console.log "[#{S.stepName}] removing prior #{dstAbs} to replace with symlink to already-quantized src"
          fs.rmSync dstAbs, recursive: true, force: true

      unless dstIsCorrectLink
        fs.mkdirSync path.dirname(dstAbs), recursive: true
        # Prefer a relative symlink when src and dst share a parent —
        # keeps the tree portable across machines with different $MODELS.
        linkTarget = path.relative(path.dirname(dstAbs), srcAbs) or srcAbs
        fs.symlinkSync linkTarget, dstAbs, 'dir'
        console.log "[#{S.stepName}] src is already quantized (bits=#{srcQuant.bits}, group_size=#{srcQuant.group_size}); symlinked #{dstAbs} -> #{linkTarget}"
      else
        console.log "[#{S.stepName}] symlink #{dstAbs} -> src already correct — nothing to do"
      S.done()
      return

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
