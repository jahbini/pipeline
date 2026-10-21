{DatabaseSync} = require 'node:sqlite'
path = require 'path'
fs   = require 'fs'

# MEMO_DB overrides the sqlite path (scratch DB for tests; the future
# switchboard's configurable store). Default unchanged.
DEFAULT_PATH = process.env.MEMO_DB ? "#{process.env.HOME}/pipeline/state/memo.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS memo (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  updated_by  TEXT NOT NULL,
  version     INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS memo_history (
  key         TEXT NOT NULL,
  value       TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  updated_by  TEXT NOT NULL,
  version     INTEGER NOT NULL,
  PRIMARY KEY (key, version)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS memo_prefix ON memo(key);
"""

HISTORIED  = [/^ui\/intent\//, /^run\/[^\/]+\/verdict$/, /^pipe\/[^\/]+\/schedule\//]
HISTORY_N  = 20
# story/* (spine library) and run/*/preview|progress (live step output)
# are UI-reactive per UI_MEMO.md's key table — they must publish on write.
NOTIFIED   = [/^ui\//, /^sys\//, /^pipe\/[^\/]+\/schedule\//, /^story\//, /^run\/[^\/]+\/(preview|progress)$/]

keyMatches = (patterns, key) ->
  for p in patterns when p.test key then return true
  false

validateKey = (k) ->
  throw new Error 'bad_key' unless typeof k is 'string' and k.length and k.length < 512
  throw new Error 'bad_key' unless /^[a-z0-9_\-]+(\/[a-z0-9_\-]+)*$/.test k

validatePrefix = (p) ->
  throw new Error 'bad_prefix' unless typeof p is 'string' and p.length and p.length < 512
  throw new Error 'bad_prefix' unless /^[a-z0-9_\-/]+$/.test p

class Memo
  constructor: (@dbPath = DEFAULT_PATH, @broker = null) ->
    fs.mkdirSync path.dirname(@dbPath), recursive:true
    @db = new DatabaseSync @dbPath
    @db.exec 'PRAGMA journal_mode=WAL;'
    @db.exec 'PRAGMA synchronous=NORMAL;'
    @db.exec SCHEMA
    @_get      = @db.prepare 'SELECT value, version, updated_at, updated_by FROM memo WHERE key = ?'
    @_prefix   = @db.prepare 'SELECT key, value, version, updated_at FROM memo WHERE key >= ? AND key < ? ORDER BY key'
    @_upsert   = @db.prepare """
      INSERT INTO memo(key,value,updated_at,updated_by,version) VALUES (?,?,?,?,1)
      ON CONFLICT(key) DO UPDATE SET
        value=excluded.value,
        updated_at=excluded.updated_at,
        updated_by=excluded.updated_by,
        version=memo.version+1
      RETURNING version
    """
    @_cas      = @db.prepare 'UPDATE memo SET value=?, updated_at=?, updated_by=?, version=version+1 WHERE key=? AND version=? RETURNING version'
    @_insNew   = @db.prepare 'INSERT INTO memo(key,value,updated_at,updated_by,version) VALUES (?,?,?,?,1) RETURNING version'
    @_del      = @db.prepare 'DELETE FROM memo WHERE key = ? RETURNING version'
    @_histIns  = @db.prepare 'INSERT INTO memo_history(key,value,updated_at,updated_by,version) VALUES (?,?,?,?,?)'
    @_histTrim = @db.prepare """
      DELETE FROM memo_history
      WHERE key = ? AND version NOT IN (
        SELECT version FROM memo_history WHERE key = ? ORDER BY version DESC LIMIT ?
      )
    """
    @_histList = @db.prepare 'SELECT value, version, updated_at, updated_by FROM memo_history WHERE key = ? ORDER BY version DESC LIMIT ?'

  get: (key) ->
    validateKey key
    row = @_get.get key
    return null unless row
    {value: JSON.parse(row.value), version: row.version, updated_at: row.updated_at, updated_by: row.updated_by}

  getPrefix: (prefix, limit=1000) ->
    validatePrefix prefix
    # half-open range using '/' (0x2F) and '0' (0x30) — keys only contain chars < '0'? No, keys contain digits.
    # Use string succ: append a char greater than any legal key char. '~' (0x7E) suffices since keys use [a-z0-9_\-/].
    end = prefix + '~'
    rows = @_prefix.all prefix, end
    rows = rows.slice 0, limit
    {key:r.key, value:JSON.parse(r.value), version:r.version, updated_at:r.updated_at} for r in rows

  history: (key, n=HISTORY_N) ->
    validateKey key
    rows = @_histList.all key, n
    {value:JSON.parse(r.value), version:r.version, updated_at:r.updated_at, updated_by:r.updated_by} for r in rows

  put: (key, value, who='anon') ->
    validateKey key
    json = JSON.stringify value
    now  = Date.now()
    @db.exec 'BEGIN IMMEDIATE'
    try
      row = @_upsert.get key, json, now, who
      if keyMatches HISTORIED, key
        @_histIns.run key, json, now, who, row.version
        @_histTrim.run key, key, HISTORY_N
      @db.exec 'COMMIT'
    catch err
      try @db.exec 'ROLLBACK'
      throw err
    @_notify key, value, row.version, who
    {version: row.version}

  cas: (key, value, ifVersion, who='anon') ->
    validateKey key
    now  = Date.now()
    json = JSON.stringify value
    row = null
    if ifVersion is 0
      try row = @_insNew.get key, json, now, who
    else
      row = @_cas.get json, now, who, key, ifVersion
    return {ok:false, reason:'version_mismatch'} unless row
    if keyMatches HISTORIED, key
      @_histIns.run key, json, now, who, row.version
      @_histTrim.run key, key, HISTORY_N
    @_notify key, value, row.version, who
    {ok:true, version: row.version}

  del: (key, who='anon') ->
    validateKey key
    row = @_del.get key
    return {ok:false} unless row
    @_notify key, null, row.version + 1, who
    {ok:true}

  _notify: (key, value, version, who) ->
    return unless @broker and keyMatches NOTIFIED, key
    if value is null
      # Deletion (or put of literal null): the broker only clears its
      # retained record when the PAYLOAD is null and retain is true —
      # a {value:null,…} envelope with retain:false leaves the dead
      # value replaying to every new subscriber. Clear first, then a
      # volatile tombstone so live subscribers learn version/author.
      @broker.publish "memo/#{key}", null, retain: true
      @broker.publish "memo/#{key}", {value: null, version, updated_by: who, ts: Date.now()}, retain: false
    else
      @broker.publish "memo/#{key}", {value, version, updated_by: who, ts: Date.now()}, retain: true

  rehydrate: ->
    return 0 unless @broker
    rows = @_prefix.all '', '~'
    n = 0
    for r in rows when keyMatches NOTIFIED, r.key
      @broker.publish "memo/#{r.key}",
        {value: JSON.parse(r.value), version: r.version, updated_by: 'rehydrate', ts: r.updated_at},
        retain:true
      n++
    n

  installHandlers: ->
    throw new Error 'no_broker' unless @broker
    @broker.handle "runner/+/+/meta/sqlite/req", (payload, meta) =>
      {op, key, value, if_version, prefix, limit, n} = payload ? {}
      who = meta.client_id ? 'anon'
      switch op
        when 'get'        then @get key
        when 'get_prefix' then @getPrefix prefix, limit ? 1000
        when 'put'        then @put key, value, who
        when 'cas'        then @cas key, value, if_version, who
        when 'del'        then @del key, who
        when 'history'    then @history key, n ? HISTORY_N
        else throw new Error "unknown_op:#{op}"

  close: -> try @db.close()

module.exports = {Memo}
