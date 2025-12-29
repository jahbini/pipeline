#!/usr/bin/env coffee
###
prepare_data.coffee — memo-native version (final)
-------------------------------------------------
Performs validation + basic stats.
Writes report through M.saveThis().
###

crypto = require 'crypto'

@step =
  desc: "Validate and analyze dataset files to produce data_report.json"

  action: (M, stepName) ->
    params = (M.theLowdown "params/#{stepName}.json").value
    CONTRACT_KEY = params.contract
    REPORT_KEY   = params.report
    throw new Error "Missing #{stepName}.contract" unless CONTRACT_KEY?
    throw new Error "Missing #{stepName}.report"   unless REPORT_KEY?

    # ----------------------------------------------------------
    contractEntry = M.theLowdown(CONTRACT_KEY)
    contract = contractEntry.value || await contractEntry.notifier
    throw new Error "Missing contract in memo: #{CONTRACT_KEY}" unless contract?

    # ----------------------------------------------------------
    # Utilities
    # ----------------------------------------------------------
    hashText = (s) ->
      crypto.createHash('sha256').update(String(s), 'utf8').digest('hex')

    EOS_MARKERS = ['</s>', '###', '\n\n', '<|eot_id|>', '<|endoftext|>']

    charClasses = (s) ->
      ctrl = ws = nonascii = 0
      for ch in s
        code = ch.charCodeAt(0)
        ctrl++ if code <= 31 or code is 127
        ws++ if /\s/.test(ch)
        nonascii++ if code > 127
      {control: ctrl, whitespace: ws, non_ascii: nonascii}

    percentiles = (vals, q=[5,25,50,75,95]) ->
      return (("p#{p}": 0) for p in q) unless vals?.length
      arr = vals.slice().sort((a,b)->a-b)
      out = {}
      for p in q
        k = Math.max(0, Math.min(arr.length-1, Math.round((p/100)*(arr.length-1))))
        out["p#{p}"] = arr[k]
      out

    # ----------------------------------------------------------
    # Scanner for any JSONL-like dataset
    # ----------------------------------------------------------
    scanLines = (lines, field) ->
      n_lines = bad_json = missing_field = non_str = 0
      empty = ws_only = lead_ws = trail_ws = ctrl_lines = 0
      lengths = []; hashes = []
      eos_hits = {}; eos_hits[m] = 0 for m in EOS_MARKERS
      good = []; bad = []

      for line in lines when line.trim().length
        n_lines++

        # parse jsonl
        try
          obj = JSON.parse(line)
        catch e
          bad_json++
          bad.push "[bad_json] #{line.slice(0,120)}" if bad.length < 3
          continue

        unless field of obj
          missing_field++
          bad.push "[missing_field] #{line.slice(0,120)}" if bad.length < 3
          continue

        val = obj[field]
        unless typeof val is 'string'
          non_str++
          bad.push "[non_string] #{String(val).slice(0,120)}" if bad.length < 3
          continue

        # whitespace/format checks
        empty++      if val is ''
        ws_only++    if val.trim() is ''
        lead_ws++    if /^\s/.test(val)
        trail_ws++   if /\s$/.test(val)

        cc = charClasses(val)
        ctrl_lines++ if cc.control > 0

        L = val.length
        lengths.push L
        hashes.push hashText(val)
        for m in EOS_MARKERS when val.includes(m)
          eos_hits[m] += 1

        good.push val if good.length < 3

      # find duplicates by hash
      counts = {}; dup_count = 0; dup_examples = []
      for h in hashes
        counts[h] ?= 0
        counts[h] += 1

      for h, cnt of counts when cnt > 1
        dup_count += cnt - 1
        dup_examples.push h if dup_examples.length < 3

      lens =
        count: lengths.length
        min: if lengths.length then Math.min.apply(null, lengths) else 0
        max: if lengths.length then Math.max.apply(null, lengths) else 0
        mean: if lengths.length then lengths.reduce((a,b)->a+b)/lengths.length else 0
        median: if lengths.length then lengths.slice().sort((a,b)->a-b)[Math.floor(lengths.length/2)] else 0
        percentiles: percentiles(lengths)

      {
        lines: n_lines
        valid_examples: lengths.length
        errors:
          bad_json: bad_json
          missing_field: missing_field
          non_string_field: non_str
        empties:
          empty_exact: empty
          whitespace_only: ws_only
          leading_whitespace: lead_ws
          trailing_whitespace: trail_ws
        control_char_lines: ctrl_lines
        duplicates:
          duplicate_example_count: dup_count
          sha256_examples: dup_examples
        length_chars: lens
        eos_markers_hits: eos_hits
        samples:
          good_first3: good
          bad_first3: bad
      }

    # ----------------------------------------------------------
    # Main logic
    # ----------------------------------------------------------
    text_field = 'text'
    splits = {}

    for split, fileKey of contract.filenames
      chosen = fileKey.chosen
      dataKey = "data/#{chosen}"

      dataEntry = M.theLowdown(dataKey)
      dataEntry = dataEntry.value || await dataEntry.notifier
      throw new Error "Missing dataset for split #{split} (#{dataKey})" unless dataEntry?

      # dataEntry.value is an array of parsed JSON objects already
      rows = dataEntry.value ? []
      unless Array.isArray(rows)
        throw new Error "Dataset #{dataKey} must load as array of JSON objects"

      # Convert array → JSONL-like lines
      lines = (JSON.stringify(r) for r in rows)

      splits[split] = scanLines(lines, text_field)

    # Final report
    report =
      created_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z')
      text_field: text_field
      splits: splits

    # Persist via memo (meta-rule to JSON)
    M.saveThis REPORT_KEY, report
    console.log "validated splits:", Object.keys(splits).join(', ')

    return
