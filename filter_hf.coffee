#!/usr/bin/env coffee

https = require 'https'

BAD_EXTS = [
  ".gguf", ".ggml", ".bin", ".pt", ".pth",
  "-awq", "-gptq", "gptq", "awq"
]

isBad = (fname) ->
  low = fname.toLowerCase()
  for ext in BAD_EXTS
    return true if low.includes ext
  return false

hfGET = (path) ->
  new Promise (resolve, reject) ->
    opts =
      hostname: "huggingface.co"
      path: "/api/#{path}"
      method: "GET"
      headers: { "User-Agent": "mlx-filter" }

    req = https.request opts, (res) ->
      data = ""
      res.on 'data', (chunk) -> data += chunk
      res.on 'end', ->
        try resolve JSON.parse(data)
        catch err then reject err

    req.on 'error', reject
    req.end()

# Check MLX file structure
isMLXCompatible = (files) ->
  hasConfig = false
  hasSafes  = false
  hasTok    = false
  hasBad    = false

  for f in files
    name = f.rfilename
    if name is "config.json" then hasConfig = true
    if name.endsWith ".safetensors" then hasSafes = true
    if name in ["tokenizer.json", "tokenizer.model"] then hasTok = true
    if isBad name then hasBad = true

  return hasConfig and hasSafes and hasTok and not hasBad

# Compute memory load of safetensors files (in GB)
estimateMemory = (files) ->
  sizeSum = 0
  for f in files
    if f.rfilename.endsWith ".safetensors"
      sizeSum += (f.size or 0)   # bytes

  gb = sizeSum / (1024*1024*1024)

  # MLX runtime overhead factor
  est = gb * 1.20   # conservative

  return { raw_gb: gb, est_gb: est }

searchModels = (query, limit=50) ->
  hfGET "models?search=#{encodeURIComponent query}&limit=#{limit}"

listRepoFiles = (repoId) ->
  hfGET "models/#{encodeURIComponent repoId}"

searchMLX = (query) ->
  new Promise (resolve, reject) ->
    searchModels(query)
      .then (repos) ->
        results = []

        checkNext = (i) ->
          return resolve results if i >= repos.length
          repo = repos[i]

          listRepoFiles(repo.id)
            .then (info) ->
              files = info?.siblings ? []

              if isMLXCompatible files
                mem = estimateMemory files
                results.push
                  id: repo.id
                  memory: mem

              checkNext i + 1
            .catch ->
              checkNext i + 1

        checkNext 0

      .catch reject

# ------------------------------------------------------------
# Driver
# ------------------------------------------------------------

queries = ["qwen", "llama", "phi", "mistral"]
RAM_LIMIT = 13  # GB usable on M4 16GB

console.log "🔍 MLX-Compatible Model Search with Memory Estimation\n"

run = ->
  Promise.all(queries.map (q) -> searchMLX q)
    .then (all) ->
      for q, idx in queries
        console.log "### #{q.toUpperCase()}:"
        for item in all[idx]
          fit = if item.memory.est_gb <= RAM_LIMIT then "✓ fits" else "✗ too big"
          console.log "  - #{item.id}"
          console.log "      raw: #{item.memory.raw_gb.toFixed(2)} GB"
          console.log "      est: #{item.memory.est_gb.toFixed(2)} GB   (#{fit})"
        console.log ""
    .catch (err) ->
      console.error "ERROR:", err

run()
