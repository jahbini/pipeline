#!/usr/bin/env coffee
###
crawl_for_voice.coffee — memo-native (2025)
----------------------------------------------
STEP — Crawl HTML pages under a base URL, extract text,
segment into paragraphs, produce train/valid datasets
*inside the memo*.

Reads:
  - experiment.yaml   (from memo)
  - remote HTML pages

Writes (to memo only):
  - <output_key>/train   → array of JSONL lines
  - <output_key>/valid   → array of JSONL lines
  - metadata counts
###

fs      = require 'fs'
path    = require 'path'
axios   = require 'axios'
cheerio = require 'cheerio'

@step =
  desc: "Crawl site pages and build memo-resident voice dataset"

  action: (M, stepName) ->

    # ------------------------------------------------------------
    # 1) Load config from memo
    # ------------------------------------------------------------

    BASE       = M.getStepParam stepName, "base"
    OUT_KEY    = M.getStepParam stepName, "output_key"
    VALID_FRAC = Number(M.getStepParam stepName, "valid_fraction")
    MIN_WORDS  = parseInt(M.getStepParam stepName, "min_story_words")

    MAX_PAGES  = parseInt(M.getStepParam stepName, "max_pages")
    PAUSE_SEC  = Number(M.getStepParam stepName, "pause_sec")
    UA         = M.getStepParam stepName, "user_agent"
    TIMEOUT_MS = parseInt(M.getStepParam stepName, "request_timeout")

    START_URL  = "https://#{BASE}/"

    # ------------------------------------------------------------
    # 2) Logging (still allowed to filesystem)
    # ------------------------------------------------------------
    EVAL_DIR = path.resolve("./logs")
    fs.mkdirSync(EVAL_DIR, {recursive:true})

    LOG_PATH = path.join(EVAL_DIR, "#{stepName}.log")
    log = (msg) ->
      stamp = new Date().toISOString().replace('T',' ').replace(/\.\d+Z$/,'')
      line  = "[#{stamp}] #{msg}"
      try fs.appendFileSync(LOG_PATH, line+"\n") catch then null
      console.log line

    # ------------------------------------------------------------
    # 3) Helpers
    # ------------------------------------------------------------
    sleep = (ms) -> new Promise (r)-> setTimeout(r,ms)

    normalize = (s) ->
      return '' unless s?
      s.replace(/\s+/g,' ').trim()

    split_paragraphs = (txt) ->
      (p.trim() for p in txt.split(/\n{2,}/) when p.trim().length)

    ordinal = (n) ->
      if 10 <= n%100 <= 20 then 'th'
      else {1:'st',2:'nd',3:'rd'}[n%10] or 'th'

    get_html = (target) ->
      axios.get(target,
        timeout: TIMEOUT_MS
        headers: {'User-Agent': UA}
      ).then((r)-> r.data)
       .catch((e)-> log "⚠️ #{target} (#{e.message})"; '')

    is_local_html = (href) ->
      return false unless href?
      href = href.split('#')[0]
      href.endsWith('.html')

    # ------------------------------------------------------------
    # 4) BFS crawl
    # ------------------------------------------------------------
    discover_pages = ->
      queue = [START_URL]
      seen  = new Set()
      pages = []

      while queue.length and pages.length < MAX_PAGES
        u = queue.shift()
        continue if seen.has(u)
        seen.add(u)

        html = await get_html(u)
        continue unless html

        pages.push [u, html]

        $ = cheerio.load(html)
        $('a[href]').each (_,a) ->
          href = $(a).attr('href')
          if is_local_html(href)
            url2 = new URL(href, START_URL).href
            unless seen.has(url2) or queue.includes(url2)
              queue.push(url2)

        await sleep(PAUSE_SEC*1000)

      pages

    extract_plain = (html) ->
      $ = cheerio.load(html)
      title = $('h2').eq(1).text()?.trim() or $('title').text()?.trim() or "Untitled"
      block = $('#bloviation')
      text  = normalize(block.text()) if block.length
      [title, text or '']

    # ------------------------------------------------------------
    # 5) MAIN
    # ------------------------------------------------------------
    log "🌐 Crawl start: #{START_URL}"

    pages = await discover_pages()
    log "Fetched #{pages.length} pages"

    examples = []

    for [page_url, html] in pages
      [title, body] = extract_plain(html)
      continue unless body and body.split(/\s+/).length >= MIN_WORDS

      slug = path.basename(page_url).replace('.html','')
      paras = split_paragraphs(body)

      for idx, para in paras
        i = idx + 1
        prompt =
          "This is the #{i}#{ordinal(i)} paragraph from the story \"#{title}\". " +
          "Please summarize it and describe its tone."

        examples.push
          meta:
            doc_id: slug
            title: title
            url: page_url
            paragraph_index: i
          prompt: prompt
          completion: ""

    # ------------------------------------------------------------
    # 6) Shuffle + split
    # ------------------------------------------------------------
    examples.sort -> Math.random() - 0.5
    n_valid = Math.max 1, Math.floor(examples.length * VALID_FRAC)
    valid = examples.slice(0, n_valid)
    train = examples.slice(n_valid)

    # ------------------------------------------------------------
    # 7) Save to memo instead of disk
    # ------------------------------------------------------------
    M.saveThis "#{OUT_KEY}:train", train.map((o)-> JSON.stringify(o))
    M.saveThis "#{OUT_KEY}:valid", valid.map((o)-> JSON.stringify(o))

    M.saveThis "#{stepName}:train_count", train.length
    M.saveThis "#{stepName}:valid_count", valid.length

    log "train=#{train.length}, valid=#{valid.length}"
    log "✅ crawl_for_voice complete"

    return {train:train.length, valid:valid.length}
