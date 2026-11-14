###
  tools/model_footprint.coffee — measure what a pipe's model ACTUALLY is.

  Memory knowledge (2026-11-07). The one honest way to size a model before
  dispatch is the BYTES ON DISK of the directory that will load — never the
  directory's NAME. A failed quantize can leave full-precision weights under
  a '-mlx4' name: that is exactly how an "8B mlx4, ~4.5GB" turned out to be
  15.6GB of bf16 shards and saturated the 16GB mini (Qwen3-8B-Base-mlx4,
  Oct 9 quantize failure — see pipeline/GPT/memory_knowledge.md).

  Tool contract: stateless, ordinary args in / values out, fs allowed
  (I/O, not state). Reached as S.tools.model_footprint.<entrypoint>.
###

fs   = require 'fs'
path = require 'path'
os   = require 'os'

# MODELS is a GLOB, not a literal (`/Volumes/bigbig*/models` — DiskArb can
# remount the volume as "bigbig 1"). Pipe foundations may carry the glob
# verbatim; expand it segment-by-segment, first match wins (the `ls -d
# <glob> | head -1` convention). A pattern-free path passes through as-is.
expandGlob = (p) ->
  return p unless p.includes('*')
  segs = String(p).split('/').filter (s) -> s.length
  cur = '/'
  for seg in segs
    unless seg.includes('*')
      cur = path.join(cur, seg)
      continue
    re = new RegExp '^' + seg.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$'
    names = (try fs.readdirSync(cur) catch then []).filter((n) -> re.test n).sort()
    return null unless names.length
    cur = path.join(cur, names[0])
  cur

# The model dir a pipe's LLM steps will load. The pipe FOUNDATION lives in
# override.yaml's `run:` block (writer/MORNING.md contract): `quantized_dir`
# is what recipes pin (steps surface it as quantized_model_dir in their
# params) and `loraLand` is the raw/base dir. Priority mirrors the steps +
# session_api's mlx4→raw fallback: quantized first, raw second; first
# candidate that exists with a config.json wins. Returns the dir or null.
resolveModelDir = (pipeDir) ->
  text = ''
  for f in ['override.yaml', 'control_override.yaml', 'experiment.yaml']
    try text += fs.readFileSync(path.join(pipeDir, f), 'utf8') + '\n' catch then null
  byKey = {}
  for line in text.split('\n')
    m = line.match /^\s*(quantized_dir|quantized_model_dir|model_dir|loraLand)\s*:\s*(\S.*?)\s*$/
    byKey[m[1]] ?= m[2].replace(/^['"]|['"]$/g, '') if m
  for key in ['quantized_dir', 'quantized_model_dir', 'model_dir', 'loraLand']
    d = expandGlob byKey[key] if byKey[key]?
    continue unless d?
    return d if (try fs.existsSync(path.join(d, 'config.json')) catch then false)
  # Old-style foundation: only `run.model: <org>/<name>` (e.g. the 14b pipe).
  # Derive dirs by the layout convention <MODELS>/<model>[-mlx4]; MODELS is
  # the canonical glob when the env var is absent.
  modelId = null
  for line in text.split('\n')
    m = line.match /^\s*model\s*:\s*(\S.*?)\s*$/
    modelId ?= m[1].replace(/^['"]|['"]$/g, '') if m
  if modelId?
    root = expandGlob(process.env.MODELS ? '/Volumes/bigbig*/models')
    if root?
      for suffix in ['-mlx4', '']
        d = path.join(root, modelId + suffix)
        return d if (try fs.existsSync(path.join(d, 'config.json')) catch then false)
  null

# Sum of *.safetensors bytes in a model dir — the honest weight size,
# immune to mislabeled dir names. Returns bytes, or null when the dir is
# unreadable or holds no safetensors.
bytesOnDisk = (dir) ->
  total = 0
  try
    for f in fs.readdirSync(dir) when /\.safetensors$/.test(f)
      total += (try fs.statSync(path.join(dir, f)).size catch then 0)
  catch
    return null
  if total > 0 then total else null

# Physical RAM of THIS host (callers run same-host as the models they gate).
hostMemBytes = -> os.totalmem()

# The dispatch gate in one call: can `pipeDir`'s model fit this host?
#   {fits, reason, model_dir, model_bytes, need_bytes, host_bytes}
# fits is null (unknown) when no model dir resolves — caller decides policy.
# Sizing: weights × 1.25 (KV cache + activations) + 1.5GB headroom must stay
# within 85% of physical RAM, or the host lands in compression/jetsam.
fitsHost = (pipeDir) ->
  dir   = resolveModelDir pipeDir
  bytes = if dir? then bytesOnDisk(dir) else null
  host  = hostMemBytes()
  unless bytes?
    return {fits: null, reason: 'model size unknown (no model dir resolved)', model_dir: dir, model_bytes: null, need_bytes: null, host_bytes: host}
  need = Math.round(bytes * 1.25 + 1.5e9)
  fits = need <= host * 0.85
  gb = (b) -> (b / 1e9).toFixed(1)
  reason = if fits then "#{gb bytes}GB on disk, needs ~#{gb need}GB of #{gb host}GB — fits" \
  else "#{gb bytes}GB on disk → needs ~#{gb need}GB, host has #{gb host}GB — TOO BIG FOR THIS HOST"
  {fits, reason, model_dir: dir, model_bytes: bytes, need_bytes: need, host_bytes: host}

module.exports = {resolveModelDir, bytesOnDisk, hostMemBytes, fitsHost}
