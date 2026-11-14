###
        meta/mail.coffee  —  email as a write DESTINATION
        =====================================================

  A meta device, not a step. Writing a value to a `mail{<recipient>}` key
  SENDS that value as an email — the same shape as writing to a `.txt`
  target writes a file. So a recipe emails a manuscript by declaring an
  artifact whose `target:` is `mail{someone@host}` and `L.make`-ing the
  text to it; the meta layer does the send.

  Key:    mail{<recipient-address>}          (brace form, like sqlite keys,
          so the slash/extension catch-alls never claim it)
  Value (write):
    - a string / array of strings → the body (default subject)
    - an object {subject, body|text|markdown, to?, from?} → full control
  Read (value === undefined): no-op (email is write-only).

  Transport: dependency-free SMTP over Node's built-in net/tls — STARTTLS
  on 587 (default) or implicit TLS on 465 — with AUTH LOGIN. NO npm install
  (keeps the @jahbini/pipeline symlink intact) and NO Python. Credentials
  come from state/mail_secret.json (BASE → CWD → EXEC), 0600, gitignored,
  never synced:
    {"host","port","secure","user","pass","from"}

  The send is async + fire-and-forget (meta writes are not awaited): it logs
  "[meta/mail] sent → …" or "[meta/mail] send FAILED → …". This never blocks
  the fused node's event loop.
###

net  = require 'net'
tls  = require 'tls'
fs   = require 'fs'
path = require 'path'

# ── minimal SMTP reply reader: resolve when the final line (CODE<space>) lands
readReply = (sock) ->
  new Promise (resolve, reject) ->
    buf = ''
    cleanup = -> sock.removeListener('data', onData); sock.removeListener('error', onErr)
    onErr  = (e) -> cleanup(); reject(e)
    onData = (d) ->
      buf += d.toString('utf8')
      last = (buf.split(/\r?\n/).filter((x) -> x.length).pop()) ? ''
      if /^\d{3} /.test(last)
        cleanup()
        resolve {code: Number(last.slice(0, 3)), text: buf.trim()}
    sock.on 'data', onData
    sock.on 'error', onErr

# write a command, then await its reply (listener attached before the write)
cmd = (sock, line) ->
  p = readReply(sock)
  sock.write(line + '\r\n')
  p

b64 = (s) -> Buffer.from(String(s ? ''), 'utf8').toString('base64')

buildMessage = (o) ->
  body = String(o.body ? '')
    .split(/\r?\n/)
    .map((l) -> if l.startsWith('.') then '.' + l else l)   # dot-stuffing
    .join('\r\n')
  [
    "From: #{o.from}"
    "To: #{o.to}"
    "Subject: #{o.subject}"
    "Date: #{new Date().toUTCString()}"
    "MIME-Version: 1.0"
    "Content-Type: text/plain; charset=UTF-8"
    ""
    body
  ].join('\r\n')

smtpSend = (o) ->
  host = o.host
  port = Number(o.port ? 587)
  secure = (o.secure is true) or port is 465
  connectTls   = (opts) -> new Promise (res, rej) -> s = tls.connect opts, (-> res s); s.once 'error', rej
  connectPlain = -> new Promise (res, rej) -> s = net.connect {host, port}; s.once 'connect', (-> res s); s.once 'error', rej

  expect = (r, codes...) ->
    throw new Error "SMTP #{codes.join('/')} expected, got #{r.code}: #{r.text}" unless r.code in codes
    r

  do ->
    sock = null
    if secure
      sock = await connectTls {host, port, servername: host}
    else
      sock = await connectPlain()
    expect (await readReply(sock)), 220          # greeting
    expect (await cmd(sock, "EHLO #{host}")), 250
    unless secure
      expect (await cmd(sock, 'STARTTLS')), 220
      sock = await connectTls {socket: sock, servername: host}
      expect (await cmd(sock, "EHLO #{host}")), 250
    expect (await cmd(sock, 'AUTH LOGIN')), 334
    expect (await cmd(sock, b64(o.user))), 334
    expect (await cmd(sock, b64(o.pass))), 235    # authenticated
    expect (await cmd(sock, "MAIL FROM:<#{o.from}>")), 250
    expect (await cmd(sock, "RCPT TO:<#{o.to}>")), 250, 251
    expect (await cmd(sock, 'DATA')), 354
    expect (await cmd(sock, buildMessage(o) + '\r\n.')), 250   # the trailing CRLF.CRLF terminator
    try (await cmd(sock, 'QUIT')) catch then null
    try sock.end() catch then null
    true

module.exports = (M, opts = {}) ->
  loadSecret = ->
    for d in [opts.basePath, opts.baseDir, opts.execDir, process.cwd()] when d
      p = path.join(d, 'state', 'mail_secret.json')
      if (try fs.existsSync(p) catch then false)
        return (try JSON.parse(fs.readFileSync(p, 'utf8')) catch then null)
    null

  M.addMetaRule 'mail', /^mail\{(.+)\}$/, (key, value) ->
    return undefined if value is undefined           # write-only destination
    keyTo = key.match(/^mail\{(.+)\}$/)?[1]
    payload =
      if value? and typeof value is 'object' and not Array.isArray(value) then value
      else { body: (if Array.isArray(value) then value.join('\n') else String(value ? '')) }
    to = String(payload.to ? keyTo ? '').trim()
    # A placeholder / empty recipient is a deliberate no-op: recipes always
    # `make` the mail artifact (so the DAG is satisfied) but only a real
    # `email_to` turns it into an actual send.
    if to.length is 0 or to in ['skip', 'none', 'self']
      console.log "[meta/mail] no recipient (#{to or 'empty'}) — not sending"
      return value
    secret = loadSecret()
    unless secret?.host and secret?.user
      console.error "[meta/mail] no usable state/mail_secret.json — cannot send to #{to}"
      return value
    o =
      host:    secret.host
      port:    secret.port
      secure:  secret.secure
      user:    secret.user
      pass:    secret.pass
      from:    (payload.from ? secret.from ? secret.user)
      to:      to
      subject: (payload.subject ? 'Celarien voyage')
      body:    (payload.body ? payload.text ? payload.markdown ? '')
    smtpSend(o)
      .then(-> console.log "[meta/mail] sent → #{o.to} (#{o.subject})")
      .catch((e) -> console.error "[meta/mail] send FAILED → #{o.to}: #{e?.message ? e}")
    value

  return

# Exported for standalone testing (a probe can send without the memo layer).
module.exports.smtpSend = smtpSend
