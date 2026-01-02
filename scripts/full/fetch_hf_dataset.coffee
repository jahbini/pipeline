#!/usr/bin/env coffee
###
fetch_hf_dataset.coffee — memo-only, strict (final)
-------------------------------------------------------
Produces:
  • memo[TRAIN]  = [ text, text, ... ]
  • memo[VALID]  = [ text, text, ... ]
  • memo[CONTRACT_KEY] = {...}
  • memo[CATALOG_KEY]  = {...}

No temporary JSONL files are written.
All byte/line counts come directly from memo arrays.
###

fs     = require 'fs'
path   = require 'path'
crypto = require 'crypto'
child  = require 'child_process'
rand   = require 'seedrandom'

@step =
  desc: "Fetch & preprocess HF dataset into train/valid memo arrays (no disk use)"

  action: (M, stepName) ->
    params = (M.theLowdown "params/#{stepName}.json").value
    # ---------------------------------------------------------
    # Required keys
    # ---------------------------------------------------------
    needed = [
      'hf_dataset','subset','mode','valid_fract',
      'min_words','max_words','seed','train','valid',
      'contract','catalog'
    ]
    for k in needed
      throw new Error "Missing required param '#{k}' in #{stepName}" unless params[k]?

    DATA_DIR     = M.getStepParam stepName, "data_dir"
    CONTRACT_KEY = params.contract
    CATALOG_KEY  = params.catalog

    HF_DATASET   = params.hf_dataset
    SUBSET       = params.subset
    MODE         = params.mode
    VALID_FRACT  = params.valid_fract
    MIN_WORDS    = params.min_words
    MAX_WORDS    = params.max_words
    SEED         = params.seed
    TRAIN        = params.train
    VALID        = params.valid

    # ---------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------
    rng = rand(SEED)
    Math.random = rng

    wc = (s) -> String(s).trim().split(/\s+/).length
    sha = (s) -> crypto.createHash('sha256').update(String(s)).digest('hex')
    timestampUTC = -> new Date().toISOString().replace(/\.\d+Z$/, 'Z')

    sanitize = (text) ->
      return '' unless text?
      String(text)
        .replace(/\\n/g, '\n')
        .replace(/\\\\n/g, '\n')
        .replace(/[“”]/g, '"')
        .replace(/[‘’]/g, "'")
        .replace(/\r/g, '')
        .trim()

    # ---------------------------------------------------------
    # Load via Python
    # ---------------------------------------------------------
    pyScript = """
from datasets import load_dataset
import json
ds = load_dataset(#{JSON.stringify(HF_DATASET)}, name=#{JSON.stringify(SUBSET)}, split='train')
for r in ds:
  print(json.dumps(r))
"""

    res = child.spawnSync('python', ['-u','-c', pyScript], {encoding:'utf8'})
    if res.error? or res.status isnt 0
      console.error res.stderr
      throw new Error "datasets.load_dataset failed"
    rawRows = []
    
    for line in res.output[1].split('\n')
      continue unless line.trim()
      try
        obj = JSON.parse(line)
        rawRows.push obj
      catch
        continue

    # ---------------------------------------------------------
    # Transform + filter
    # ---------------------------------------------------------
    rows = []

    for r in rawRows
      quote  = sanitize(r.quote)  or ''
      author = sanitize(r.author) or ''
      quote.replace(/^"|"$/g, '')
      continue unless quote.length

      text = if MODE is 'plain'
        { text: quote }
      else
        instr = "Write a short motivational quote."
        instr = "Write a short motivational quote in the style of #{author}." if author 
        { prompt:instr, completion: quote}
      rows.push text

    # Deduplicate
    seen = new Set()
    uniq = []
    for t in rows
      h = sha(t.completion)
      unless seen.has(h)
        seen.add(h)
        uniq.push t

    # Shuffle
    uniq.sort -> rng() - 0.5

    # Split
    validN = Math.max(1, Math.floor(uniq.length * VALID_FRACT))
    valid = uniq.slice(0, validN)
    train = uniq.slice(validN)

    # ---------------------------------------------------------
    # Save to MEMO ONLY
    # ---------------------------------------------------------
    M.saveThis(TRAIN, train)
    M.saveThis(VALID, valid)
    M.saveThis('data/test.jsonl',valid)
    console.log "Saved train=#{train.length}, valid=#{valid.length}."

    # ---------------------------------------------------------
    # Construct data_contract (memo-only paths)
    # ---------------------------------------------------------
    created = timestampUTC()

    data_contract =
      created_utc: created
      data_dir: DATA_DIR
      filenames:
        train:
          chosen: TRAIN
          resolved: TRAIN
        valid:
          chosen: VALID
          resolved: VALID
      schema:
        format: "jsonl"
        fields: {text: "string"}

    # ---------------------------------------------------------
    # Build data_catalog WITHOUT FILES — using memo arrays
    # ---------------------------------------------------------
    computeCatalogEntry = (label, arr) ->
      # Simulate JSONL count/byte length as if serialized
      lines = arr.length
      bytes = 0
      shaAcc = crypto.createHash('sha256')
      for t in arr
        j = JSON.stringify({text:t}) + "\n"
        bytes += Buffer.byteLength(j)
        shaAcc.update(j)
      {
        path: label
        lines: lines
        bytes: bytes
        sha256: shaAcc.digest('hex')
        stats:
          num_valid_examples: lines
          num_bytes: bytes
          sha256: null   # filled by top-level
      }

    trainEntry = computeCatalogEntry(TRAIN, train)
    validEntry = computeCatalogEntry(VALID, valid)
    trainEntry.stats.sha256 = trainEntry.sha256
    validEntry.stats.sha256 = validEntry.sha256

    data_catalog =
      created_utc: created
      files:
        train: trainEntry
        valid: validEntry
      entries:
        train: trainEntry
        valid: validEntry

    # ---------------------------------------------------------
    # Save contract + catalog
    # ---------------------------------------------------------
    M.saveThis(CONTRACT_KEY, data_contract)
    M.saveThis(CATALOG_KEY, data_catalog)

    console.log  "#{stepName} finished"
    return
