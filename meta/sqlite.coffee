###
        meta/sqlite.coffee  —  request-keyed SQLite backend
        =====================================================

  **The heavyweight meta device.** Loaded first (per
  `index.coffee`) so its compound regex wins against the simpler
  json/jsonl/txt/csv rules for any key matching its grammar.

  Conceptual model
  ----------------
  Instead of mapping a file path to its contents, sqlite maps
  **request keys** to SQL queries. A request key has the shape:

      <requestName>(\{<arg>\})?.<suffix>

  where `<suffix>` is one of `json` / `jsonl` / `txt` / `csv`,
  and the optional `{arg}` is a positional argument like a
  `story_id` or `run_id`. Examples:

      storyByID{abc-123}.json    → SELECT FROM stories ...
      kagFor{abc-123}.json       → joined SELECT, returns object
      allStories.jsonl           → SELECT FROM stories, array
      sqliteResetAll.json        → write-only, truncates tables

  Pieces
  ------
  - **Schema bootstrap.** The big `CREATE TABLE IF NOT EXISTS`
    block defines every table any request key touches. The schema
    lives here and not in a separate migration system because
    this is a teaching tool — one file should answer "what data
    does this hold."
  - **In-place migration.** A small loop after bootstrap adds any
    missing columns to `kag_entries` via `ALTER TABLE`. This is
    how live projects survive a schema bump without re-creating
    the database. Add new columns the same way.
  - **`FORMATTERS`.** Per-suffix coercion. Each entry has `read`
    and `write` halves. `.json` demands an object, `.jsonl`
    demands an array, `.txt` accepts either and stringifies, `.csv`
    is permissive. Run on both directions of every request.
  - **`REQUESTS`.** The authoritative list of named requests. Each
    has `name`, `regex` (matched against the request key minus
    suffix), `allowedSuffixes`, `read(db, ...args)`, and
    `write(db, value, ...args)`. A `write: null` means read-only.
    Writes wrap multi-table changes in `BEGIN`/`COMMIT`/`ROLLBACK`.
  - **The single `addMetaRule`.** One big disjunctive regex that
    matches every request name; dispatch picks the right
    `REQUESTS` entry by re-matching its narrower regex. The
    indirection lets `REQUESTS` stay declarative.

  **Debug switch.** Set `params/_global.yaml: debug_sql: true` to
  get per-key timing and row-count logs on stdout. The check is
  per-call to `M.theLowdown`, so toggling it mid-run takes effect
  on the next request.

  **Adding a request.** Append a new entry to `REQUESTS` and
  extend the big regex in the `addMetaRule` call at the bottom to
  include the new request name. The narrower per-request regex
  inside the entry is what extracts the args; keep it anchored
  with `^...$`.
###
path = require 'path'
{ DatabaseSync } = require 'node:sqlite'

module.exports = (M, opts={}) ->
    baseDir = opts.baseDir ? process.cwd()
    dbFile = opts.sqliteFile ? 'runtime.sqlite'
    dbPath = if path.isAbsolute(dbFile) then dbFile else path.join(baseDir, dbFile)
    db = new DatabaseSync(dbPath)

    debugEnabled = ->
        try
            globalParams = M.theLowdown("params/_global.yaml")?.value ? {}
            globalParams.debug_sql is true
        catch then false

    debugLog = (parts...) ->
        return unless debugEnabled()
        console.log "[#{new Date().toISOString()}] [SQL]", parts...

    # HEY JIM! There is no repo-defined SQLite schema yet, so this file
    # creates the minimum schema needed for the request-key contract.
    db.exec """
    CREATE TABLE IF NOT EXISTS stories (
      story_id TEXT PRIMARY KEY,
      title TEXT,
      text TEXT
    );

    CREATE TABLE IF NOT EXISTS story_parts (
      story_id TEXT PRIMARY KEY,
      scene TEXT,
      arrival TEXT,
      disturbance TEXT,
      reflection TEXT,
      realization TEXT
    );

    CREATE TABLE IF NOT EXISTS expanded_story_parts (
      story_id TEXT PRIMARY KEY,
      scene_json TEXT,
      arrival_json TEXT,
      disturbance_json TEXT,
      reflection_json TEXT,
      realization_json TEXT
    );

    CREATE TABLE IF NOT EXISTS kag_entries (
      story_id TEXT NOT NULL,
      entry_index INTEGER NOT NULL,
      doc_id TEXT,
      paragraph_index TEXT,
      chunk_index INTEGER,
      start_paragraph INTEGER,
      end_paragraph INTEGER,
      keyword TEXT,
      headline TEXT,
      chunk_text TEXT,
      entry_json TEXT,
      PRIMARY KEY (story_id, entry_index)
    );

    CREATE INDEX IF NOT EXISTS idx_kag_entries_story_id
      ON kag_entries (story_id);

    CREATE INDEX IF NOT EXISTS idx_kag_entries_keyword
      ON kag_entries (keyword);

    CREATE TABLE IF NOT EXISTS oracle_story_attempts (
      story_id TEXT PRIMARY KEY,
      fail_count INTEGER NOT NULL DEFAULT 0,
      last_failed_at TEXT,
      last_error TEXT
    );

    CREATE TABLE IF NOT EXISTS lora_trained_stories (
      story_id TEXT PRIMARY KEY,
      trained_at TEXT
    );

    CREATE TABLE IF NOT EXISTS lora_story_usage (
      story_id TEXT PRIMARY KEY,
      use_count INTEGER NOT NULL DEFAULT 0,
      last_trained_at TEXT,
      last_run_id TEXT
    );

    CREATE TABLE IF NOT EXISTS lora_training_runs (
      run_id TEXT PRIMARY KEY,
      started_at TEXT,
      finished_at TEXT,
      status TEXT,
      model_dir TEXT,
      adapter_path TEXT,
      resume_adapter_file TEXT,
      training_dir TEXT,
      stdout_text TEXT,
      train_rows_count INTEGER,
      valid_rows_count INTEGER,
      test_rows_count INTEGER,
      checkpoint_path TEXT
    );

    CREATE TABLE IF NOT EXISTS lora_training_run_stories (
      run_id TEXT NOT NULL,
      story_id TEXT NOT NULL,
      PRIMARY KEY (run_id, story_id)
    );

    -- Generic pipeline-run history (every recipe launch, not just LoRA).
    -- Powers GET /api/run/{id} and the agent surface's evaluation step.
    CREATE TABLE IF NOT EXISTS runs (
      run_id      TEXT PRIMARY KEY,
      pipeline    TEXT,
      started_at  TEXT,
      finished_at TEXT,
      status      TEXT,
      logdir      TEXT,
      pid         INTEGER,
      cwd         TEXT,
      shutdown    TEXT
    );

    -- Per-row change log (step 5 of the agent surface). Every INSERT,
    -- UPDATE, and DELETE on a tracked table fires a trigger that drops one
    -- row here. Powers GET /api/sqlite/diff?since=<run_id|ts|change_id> for
    -- precise "what changed because of this run" answers.
    CREATE TABLE IF NOT EXISTS _change_log (
      change_id  INTEGER PRIMARY KEY AUTOINCREMENT,
      ts         TEXT NOT NULL,
      table_name TEXT NOT NULL,
      op         TEXT NOT NULL,
      row_id     TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_change_log_ts    ON _change_log (ts);
    CREATE INDEX IF NOT EXISTS idx_change_log_table ON _change_log (table_name);

    -- Triggers: one INSERT/UPDATE/DELETE trigger per tracked table.
    -- row_id is the primary key (compound keys are concatenated with '|').
    -- ts uses strftime so it matches JS Date.toISOString() format and can
    -- be compared lexicographically against runs.started_at.

    CREATE TRIGGER IF NOT EXISTS trg_stories_ins AFTER INSERT ON stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'stories', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_stories_upd AFTER UPDATE ON stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'stories', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_stories_del AFTER DELETE ON stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'stories', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_story_parts_ins AFTER INSERT ON story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'story_parts', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_story_parts_upd AFTER UPDATE ON story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'story_parts', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_story_parts_del AFTER DELETE ON story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'story_parts', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_expanded_story_parts_ins AFTER INSERT ON expanded_story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'expanded_story_parts', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_expanded_story_parts_upd AFTER UPDATE ON expanded_story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'expanded_story_parts', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_expanded_story_parts_del AFTER DELETE ON expanded_story_parts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'expanded_story_parts', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_kag_entries_ins AFTER INSERT ON kag_entries BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'kag_entries', 'INSERT',
              NEW.story_id || '|' || NEW.entry_index);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_kag_entries_upd AFTER UPDATE ON kag_entries BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'kag_entries', 'UPDATE',
              NEW.story_id || '|' || NEW.entry_index);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_kag_entries_del AFTER DELETE ON kag_entries BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'kag_entries', 'DELETE',
              OLD.story_id || '|' || OLD.entry_index);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_oracle_story_attempts_ins AFTER INSERT ON oracle_story_attempts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'oracle_story_attempts', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_oracle_story_attempts_upd AFTER UPDATE ON oracle_story_attempts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'oracle_story_attempts', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_oracle_story_attempts_del AFTER DELETE ON oracle_story_attempts BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'oracle_story_attempts', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_lora_trained_stories_ins AFTER INSERT ON lora_trained_stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_trained_stories', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_trained_stories_upd AFTER UPDATE ON lora_trained_stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_trained_stories', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_trained_stories_del AFTER DELETE ON lora_trained_stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_trained_stories', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_lora_story_usage_ins AFTER INSERT ON lora_story_usage BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_story_usage', 'INSERT', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_story_usage_upd AFTER UPDATE ON lora_story_usage BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_story_usage', 'UPDATE', NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_story_usage_del AFTER DELETE ON lora_story_usage BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_story_usage', 'DELETE', OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_lora_training_runs_ins AFTER INSERT ON lora_training_runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_training_runs', 'INSERT', NEW.run_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_training_runs_upd AFTER UPDATE ON lora_training_runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_training_runs', 'UPDATE', NEW.run_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_training_runs_del AFTER DELETE ON lora_training_runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_training_runs', 'DELETE', OLD.run_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_lora_training_run_stories_ins AFTER INSERT ON lora_training_run_stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_training_run_stories', 'INSERT',
              NEW.run_id || '|' || NEW.story_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_lora_training_run_stories_del AFTER DELETE ON lora_training_run_stories BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'lora_training_run_stories', 'DELETE',
              OLD.run_id || '|' || OLD.story_id);
    END;

    CREATE TRIGGER IF NOT EXISTS trg_runs_ins AFTER INSERT ON runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'runs', 'INSERT', NEW.run_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_runs_upd AFTER UPDATE ON runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'runs', 'UPDATE', NEW.run_id);
    END;
    CREATE TRIGGER IF NOT EXISTS trg_runs_del AFTER DELETE ON runs BEGIN
      INSERT INTO _change_log (ts, table_name, op, row_id)
      VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 'runs', 'DELETE', OLD.run_id);
    END;
    """

    kagColumns = db.prepare("PRAGMA table_info(kag_entries)").all()
    hasKagChunkIndex = false
    hasKagStartParagraph = false
    hasKagEndParagraph = false
    hasKagChunkText = false
    for row in kagColumns
      name = String(row?.name ? '')
      if name is 'chunk_index'
        hasKagChunkIndex = true
      else if name is 'start_paragraph'
        hasKagStartParagraph = true
      else if name is 'end_paragraph'
        hasKagEndParagraph = true
      else if name is 'chunk_text'
        hasKagChunkText = true

    unless hasKagChunkIndex
      db.exec "ALTER TABLE kag_entries ADD COLUMN chunk_index INTEGER"
    unless hasKagStartParagraph
      db.exec "ALTER TABLE kag_entries ADD COLUMN start_paragraph INTEGER"
    unless hasKagEndParagraph
      db.exec "ALTER TABLE kag_entries ADD COLUMN end_paragraph INTEGER"
    unless hasKagChunkText
      db.exec "ALTER TABLE kag_entries ADD COLUMN chunk_text TEXT"

    FORMATTERS =
      json:
        read: (value) ->
          throw new Error "sqlite meta expected object for .json" unless value? and typeof value is 'object' and not Array.isArray(value)
          value
        write: (value) ->
          throw new Error "sqlite meta expected object for .json" unless value? and typeof value is 'object' and not Array.isArray(value)
          value

      jsonl:
        read: (value) ->
          throw new Error "sqlite meta expected array for .jsonl" unless Array.isArray(value)
          value
        write: (value) ->
          throw new Error "sqlite meta expected array for .jsonl" unless Array.isArray(value)
          value

      txt:
        read: (value) ->
          if typeof value is 'string'
            value
          else
            # HEY JIM! The directive requires txt support but does not define
            # a canonical text projection for structured values.
            JSON.stringify(value, null, 2)
        write: (value) ->
          if typeof value is 'string'
            value
          else
            JSON.stringify(value, null, 2)

      csv:
        read: (value) ->
          if Array.isArray(value)
            value
          else if value? and typeof value is 'object'
            value
          else
            throw new Error "sqlite meta expected object or array for .csv"
        write: (value) ->
          if Array.isArray(value)
            value
          else if value? and typeof value is 'object'
            value
          else
            throw new Error "sqlite meta expected object or array for .csv"

    REQUESTS = [
      {
        name: 'storyByID'
        regex: /^storyByID\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, storyID) ->
          row = db.prepare("""
            SELECT story_id, title, text
            FROM stories
            WHERE story_id = ?
          """).get(storyID)

          throw new Error "sqlite meta missing storyByID #{storyID}" unless row?

          {
            story_id: row.story_id
            title: row.title
            text: row.text
          }
        write: (db, value, storyID) ->
          throw new Error "sqlite meta storyByID write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          writeStoryID = value.story_id ? storyID
          throw new Error "sqlite meta storyByID story_id mismatch" unless writeStoryID is storyID

          db.prepare("""
            INSERT INTO stories (story_id, title, text)
            VALUES (?, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
              title = excluded.title,
              text = excluded.text
          """).run(
            writeStoryID
            value.title ? null
            value.text ? null
          )

          {
            story_id: writeStoryID
            title: value.title ? null
            text: value.text ? null
          }
      }

      {
        name: 'partsFor'
        regex: /^partsFor\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, storyID) ->
          row = db.prepare("""
            SELECT story_id, scene, arrival, disturbance, reflection, realization
            FROM story_parts
            WHERE story_id = ?
          """).get(storyID)

          throw new Error "sqlite meta missing partsFor #{storyID}" unless row?

          {
            story_id: row.story_id
            parts:
              scene: row.scene
              arrival: row.arrival
              disturbance: row.disturbance
              reflection: row.reflection
              realization: row.realization
          }
        write: (db, value, storyID) ->
          throw new Error "sqlite meta partsFor write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          throw new Error "sqlite meta partsFor write expects value.parts" unless value.parts? and typeof value.parts is 'object' and not Array.isArray(value.parts)
          writeStoryID = value.story_id ? storyID
          throw new Error "sqlite meta partsFor story_id mismatch" unless writeStoryID is storyID

          db.prepare("""
            INSERT INTO story_parts (
              story_id, scene, arrival, disturbance, reflection, realization
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
              scene = excluded.scene,
              arrival = excluded.arrival,
              disturbance = excluded.disturbance,
              reflection = excluded.reflection,
              realization = excluded.realization
          """).run(
            writeStoryID
            value.parts.scene ? null
            value.parts.arrival ? null
            value.parts.disturbance ? null
            value.parts.reflection ? null
            value.parts.realization ? null
          )

          {
            story_id: writeStoryID
            parts:
              scene: value.parts.scene ? null
              arrival: value.parts.arrival ? null
              disturbance: value.parts.disturbance ? null
              reflection: value.parts.reflection ? null
              realization: value.parts.realization ? null
          }
      }

      {
        name: 'kagFor'
        regex: /^kagFor\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, storyID) ->
          rows = db.prepare("""
            SELECT story_id, entry_index, doc_id, paragraph_index, chunk_index, keyword, headline, entry_json
            FROM kag_entries
            WHERE story_id = ?
            ORDER BY entry_index ASC
          """).all(storyID)

          throw new Error "sqlite meta missing kagFor #{storyID}" unless rows.length

          entries = []
          seenKeywords = new Set()
          keywords = []

          for row in rows
            entry = null
            if row.entry_json?
              entry = JSON.parse(row.entry_json)
              entry.chunk_index ?= row.chunk_index ? null
              entry.meta ?= {}
              entry.meta.chunk_index ?= row.chunk_index ? null
              entry.meta.group_index ?= row.chunk_index ? null
            else
              entry =
                story_id: row.story_id
                entry_index: row.entry_index
                doc_id: row.doc_id
                paragraph_index: row.paragraph_index
                chunk_index: row.chunk_index
                keyword: row.keyword
                headline: row.headline
                chunk_text: row.chunk_text
                meta:
                  chunk_index: row.chunk_index
                  group_index: row.chunk_index
                  start_paragraph: row.start_paragraph
                  end_paragraph: row.end_paragraph

            entries.push entry

            keyword = row.keyword
            if keyword? and not seenKeywords.has(keyword)
              seenKeywords.add keyword
              keywords.push keyword

          {
            story_id: storyID
            entries: entries
            keywords: keywords
          }
        write: (db, value, storyID) ->
          throw new Error "sqlite meta kagFor write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          throw new Error "sqlite meta kagFor write expects entries array" unless Array.isArray(value.entries)
          throw new Error "sqlite meta kagFor write expects keywords array" unless Array.isArray(value.keywords)
          writeStoryID = value.story_id ? storyID
          throw new Error "sqlite meta kagFor story_id mismatch" unless writeStoryID is storyID

          # HEY JIM! Queryable KAG keywords are stored per entry row. Keywords
          # present only in value.keywords but not attached to an entry are not
          # independently queryable because the prompt did not define a separate
          # storage shape for them.
          db.exec 'BEGIN'
          try
            db.prepare("""
              DELETE FROM kag_entries
              WHERE story_id = ?
            """).run(writeStoryID)

            insertStatement = db.prepare("""
              INSERT INTO kag_entries (
                story_id, entry_index, doc_id, paragraph_index, chunk_index, start_paragraph, end_paragraph, keyword, headline, chunk_text, entry_json
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)

            entryIndex = 1
            for entry in value.entries
              docID = entry?.doc_id ? entry?.meta?.doc_id ? null
              paragraphIndex = entry?.paragraph_index ? entry?.meta?.paragraph_index ? null
              chunkIndex = entry?.chunk_index ? entry?.meta?.chunk_index ? entry?.meta?.group_index ? null
              startParagraph = entry?.start_paragraph ? entry?.meta?.start_paragraph ? entry?.meta?.group_start_paragraph ? null
              endParagraph = entry?.end_paragraph ? entry?.meta?.end_paragraph ? entry?.meta?.group_end_paragraph ? null
              keyword = entry?.keyword ? null
              headline = entry?.headline ? entry?.label ? entry?.text ? null
              chunkText = entry?.chunk_text ? entry?.meta?.chunk_text ? null

              insertStatement.run(
                writeStoryID
                entryIndex
                docID
                paragraphIndex
                chunkIndex
                startParagraph
                endParagraph
                keyword
                headline
                chunkText
                JSON.stringify(entry)
              )

              entryIndex += 1

            db.exec 'COMMIT'
          catch err
            try db.exec 'ROLLBACK' catch then null
            throw err

          {
            story_id: writeStoryID
            entries: value.entries
            keywords: value.keywords
          }
      }

      {
        name: 'oracleFailureFor'
        regex: /^oracleFailureFor\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, storyID) ->
          row = db.prepare("""
            SELECT story_id, fail_count, last_failed_at, last_error
            FROM oracle_story_attempts
            WHERE story_id = ?
          """).get(storyID)

          unless row?
            return {
              story_id: storyID
              fail_count: 0
              last_failed_at: null
              last_error: null
            }

          {
            story_id: row.story_id
            fail_count: row.fail_count ? 0
            last_failed_at: row.last_failed_at ? null
            last_error: row.last_error ? null
          }
        write: (db, value, storyID) ->
          payload = if value? and typeof value is 'object' and not Array.isArray(value) then value else {}
          if payload.reset is true
            db.prepare("""
              DELETE FROM oracle_story_attempts
              WHERE story_id = ?
            """).run(storyID)

            return {
              story_id: storyID
              fail_count: 0
              last_failed_at: null
              last_error: null
            }

          current = db.prepare("""
            SELECT fail_count
            FROM oracle_story_attempts
            WHERE story_id = ?
          """).get(storyID)

          nextCount = (current?.fail_count ? 0) + 1
          failedAt = payload.last_failed_at ? new Date().toISOString()
          lastError = payload.last_error ? payload.reason ? null

          db.prepare("""
            INSERT INTO oracle_story_attempts (
              story_id, fail_count, last_failed_at, last_error
            )
            VALUES (?, ?, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
              fail_count = excluded.fail_count,
              last_failed_at = excluded.last_failed_at,
              last_error = excluded.last_error
          """).run(
            storyID
            nextCount
            failedAt
            lastError
          )

          {
            story_id: storyID
            fail_count: nextCount
            last_failed_at: failedAt
            last_error: lastError
          }
      }

      {
        name: 'expandedPartsFor'
        regex: /^expandedPartsFor\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, storyID) ->
          row = db.prepare("""
            SELECT story_id, scene_json, arrival_json, disturbance_json, reflection_json, realization_json
            FROM expanded_story_parts
            WHERE story_id = ?
          """).get(storyID)

          throw new Error "sqlite meta missing expandedPartsFor #{storyID}" unless row?

          parsePart = (raw) ->
            return null unless raw?
            JSON.parse raw

          {
            story_id: row.story_id
            expanded_parts:
              scene: parsePart row.scene_json
              arrival: parsePart row.arrival_json
              disturbance: parsePart row.disturbance_json
              reflection: parsePart row.reflection_json
              realization: parsePart row.realization_json
          }
        write: (db, value, storyID) ->
          throw new Error "sqlite meta expandedPartsFor write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          throw new Error "sqlite meta expandedPartsFor write expects expanded_parts" unless value.expanded_parts? and typeof value.expanded_parts is 'object' and not Array.isArray(value.expanded_parts)
          writeStoryID = value.story_id ? storyID
          throw new Error "sqlite meta expandedPartsFor story_id mismatch" unless writeStoryID is storyID

          db.prepare("""
            INSERT INTO expanded_story_parts (
              story_id, scene_json, arrival_json, disturbance_json, reflection_json, realization_json
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(story_id) DO UPDATE SET
              scene_json = excluded.scene_json,
              arrival_json = excluded.arrival_json,
              disturbance_json = excluded.disturbance_json,
              reflection_json = excluded.reflection_json,
              realization_json = excluded.realization_json
          """).run(
            writeStoryID
            JSON.stringify(value.expanded_parts.scene ? null)
            JSON.stringify(value.expanded_parts.arrival ? null)
            JSON.stringify(value.expanded_parts.disturbance ? null)
            JSON.stringify(value.expanded_parts.reflection ? null)
            JSON.stringify(value.expanded_parts.realization ? null)
          )

          {
            story_id: writeStoryID
            expanded_parts: value.expanded_parts
          }
      }

      {
        name: 'storiesWithKag'
        regex: /^storiesWithKag\{([^}]+)\}$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db, keyword) ->
          db.prepare("""
            SELECT DISTINCT stories.story_id, stories.title, stories.text
            FROM stories
            INNER JOIN kag_entries
              ON kag_entries.story_id = stories.story_id
            WHERE kag_entries.keyword = ?
            ORDER BY stories.story_id ASC
          """).all(keyword)
        write: null
      }

      {
        name: 'storiesMissingKag'
        regex: /^storiesMissingKag$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db) ->
          db.prepare("""
            SELECT
              stories.story_id,
              stories.title,
              stories.text,
              COALESCE(oracle_story_attempts.fail_count, 0) AS fail_count,
              oracle_story_attempts.last_failed_at,
              oracle_story_attempts.last_error
            FROM stories
            LEFT JOIN oracle_story_attempts
              ON oracle_story_attempts.story_id = stories.story_id
            WHERE NOT EXISTS (
              SELECT 1
              FROM kag_entries
              WHERE kag_entries.story_id = stories.story_id
            )
            ORDER BY
              COALESCE(oracle_story_attempts.fail_count, 0) ASC,
              stories.story_id ASC
          """).all()
        write: null
      }

      {
        name: 'allStories'
        regex: /^allStories$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db) ->
          db.prepare("""
            SELECT story_id, title, text
            FROM stories
            ORDER BY story_id ASC
          """).all()
        write: null
      }

      {
        name: 'trainedStories'
        regex: /^trainedStories$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db) ->
          db.prepare("""
            SELECT story_id, trained_at
            FROM lora_trained_stories
            ORDER BY story_id ASC
          """).all()
        write: (db, value) ->
          throw new Error "sqlite meta trainedStories write expects array" unless Array.isArray(value)

          db.exec 'BEGIN'
          try
            db.exec "DELETE FROM lora_trained_stories"

            insertStatement = db.prepare("""
              INSERT INTO lora_trained_stories (story_id, trained_at)
              VALUES (?, ?)
            """)

            for row in value
              if typeof row is 'string'
                storyID = row
                trainedAt = null
              else
                throw new Error "sqlite meta trainedStories write expects objects or strings" unless row? and typeof row is 'object' and not Array.isArray(row)
                storyID = row.story_id
                trainedAt = row.trained_at ? null

              throw new Error "sqlite meta trainedStories write missing story_id" unless storyID?
              insertStatement.run storyID, trainedAt

            db.exec 'COMMIT'
          catch err
            try db.exec 'ROLLBACK' catch then null
            throw err

          rows = []
          for row in value
            if typeof row is 'string'
              rows.push story_id: row, trained_at: null
            else
              rows.push
                story_id: row.story_id
                trained_at: row.trained_at ? null
          rows
      }

      {
        name: 'loraStoryUsage'
        regex: /^loraStoryUsage$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db) ->
          db.prepare("""
            SELECT
              stories.story_id,
              stories.title,
              COALESCE(lora_story_usage.use_count, 0) AS use_count,
              lora_story_usage.last_trained_at,
              lora_story_usage.last_run_id
            FROM stories
            LEFT JOIN lora_story_usage
              ON lora_story_usage.story_id = stories.story_id
            ORDER BY COALESCE(lora_story_usage.use_count, 0) ASC, stories.story_id ASC
          """).all()
        write: null
      }

      {
        name: 'loraTrainingRun'
        regex: /^loraTrainingRun\{([^}]+)\}$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: (db, runID) ->
          row = db.prepare("""
            SELECT
              run_id,
              started_at,
              finished_at,
              status,
              model_dir,
              adapter_path,
              resume_adapter_file,
              training_dir,
              stdout_text,
              train_rows_count,
              valid_rows_count,
              test_rows_count,
              checkpoint_path
            FROM lora_training_runs
            WHERE run_id = ?
          """).get(runID)

          throw new Error "sqlite meta missing loraTrainingRun #{runID}" unless row?

          storyRows = db.prepare("""
            SELECT story_id
            FROM lora_training_run_stories
            WHERE run_id = ?
            ORDER BY story_id ASC
          """).all(runID)

          {
            run_id: row.run_id
            started_at: row.started_at
            finished_at: row.finished_at
            status: row.status
            model_dir: row.model_dir
            adapter_path: row.adapter_path
            resume_adapter_file: row.resume_adapter_file
            training_dir: row.training_dir
            stdout_text: row.stdout_text
            train_rows_count: row.train_rows_count
            valid_rows_count: row.valid_rows_count
            test_rows_count: row.test_rows_count
            checkpoint_path: row.checkpoint_path
            story_ids: (storyRow.story_id for storyRow in storyRows)
          }
        write: (db, value, runID) ->
          throw new Error "sqlite meta loraTrainingRun write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          writeRunID = value.run_id ? runID
          throw new Error "sqlite meta loraTrainingRun run_id mismatch" unless writeRunID is runID
          throw new Error "sqlite meta loraTrainingRun write expects story_ids array" unless Array.isArray(value.story_ids)

          startedAt = value.started_at ? null
          finishedAt = value.finished_at ? null
          status = value.status ? null
          modelDir = value.model_dir ? null
          adapterPath = value.adapter_path ? null
          resumeAdapterFile = value.resume_adapter_file ? null
          trainingDir = value.training_dir ? null
          stdoutText = value.stdout_text ? null
          trainRowsCount = value.train_rows_count ? null
          validRowsCount = value.valid_rows_count ? null
          testRowsCount = value.test_rows_count ? null
          checkpointPath = value.checkpoint_path ? null

          db.exec 'BEGIN'
          try
            db.prepare("""
              INSERT INTO lora_training_runs (
                run_id, started_at, finished_at, status, model_dir, adapter_path,
                resume_adapter_file, training_dir, stdout_text, train_rows_count,
                valid_rows_count, test_rows_count, checkpoint_path
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(run_id) DO UPDATE SET
                started_at = excluded.started_at,
                finished_at = excluded.finished_at,
                status = excluded.status,
                model_dir = excluded.model_dir,
                adapter_path = excluded.adapter_path,
                resume_adapter_file = excluded.resume_adapter_file,
                training_dir = excluded.training_dir,
                stdout_text = excluded.stdout_text,
                train_rows_count = excluded.train_rows_count,
                valid_rows_count = excluded.valid_rows_count,
                test_rows_count = excluded.test_rows_count,
                checkpoint_path = excluded.checkpoint_path
            """).run(
              writeRunID
              startedAt
              finishedAt
              status
              modelDir
              adapterPath
              resumeAdapterFile
              trainingDir
              stdoutText
              trainRowsCount
              validRowsCount
              testRowsCount
              checkpointPath
            )

            db.prepare("""
              DELETE FROM lora_training_run_stories
              WHERE run_id = ?
            """).run(writeRunID)

            insertStory = db.prepare("""
              INSERT INTO lora_training_run_stories (run_id, story_id)
              VALUES (?, ?)
            """)

            for storyID in value.story_ids
              throw new Error "sqlite meta loraTrainingRun story_ids contain empty value" unless storyID?
              insertStory.run writeRunID, storyID

              db.prepare("""
                INSERT INTO lora_story_usage (story_id, use_count, last_trained_at, last_run_id)
                VALUES (?, 1, ?, ?)
                ON CONFLICT(story_id) DO UPDATE SET
                  use_count = lora_story_usage.use_count + 1,
                  last_trained_at = excluded.last_trained_at,
                  last_run_id = excluded.last_run_id
              """).run(storyID, finishedAt ? startedAt, writeRunID)

            db.exec 'COMMIT'
          catch err
            try db.exec 'ROLLBACK' catch then null
            throw err

          {
            run_id: writeRunID
            started_at: startedAt
            finished_at: finishedAt
            status: status
            model_dir: modelDir
            adapter_path: adapterPath
            resume_adapter_file: resumeAdapterFile
            training_dir: trainingDir
            stdout_text: stdoutText
            train_rows_count: trainRowsCount
            valid_rows_count: validRowsCount
            test_rows_count: testRowsCount
            checkpoint_path: checkpointPath
            story_ids: value.story_ids
          }
      }

      {
        name: 'loraTrainingRuns'
        regex: /^loraTrainingRuns$/
        allowedSuffixes: ['jsonl', 'txt', 'csv']
        read: (db) ->
          db.prepare("""
            SELECT
              run_id,
              started_at,
              finished_at,
              status,
              model_dir,
              adapter_path,
              training_dir,
              train_rows_count,
              valid_rows_count,
              test_rows_count,
              checkpoint_path
            FROM lora_training_runs
            ORDER BY started_at DESC, run_id DESC
          """).all()
        write: null
      }

      {
        name: 'sqliteResetAll'
        regex: /^sqliteResetAll$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: null
        write: (db, value) ->
          throw new Error "sqlite meta sqliteResetAll write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          db.exec 'BEGIN'
          try
            db.exec "DELETE FROM kag_entries"
            db.exec "DELETE FROM oracle_story_attempts"
            db.exec "DELETE FROM expanded_story_parts"
            db.exec "DELETE FROM story_parts"
            db.exec "DELETE FROM lora_training_run_stories"
            db.exec "DELETE FROM lora_training_runs"
            db.exec "DELETE FROM lora_story_usage"
            db.exec "DELETE FROM lora_trained_stories"
            db.exec "DELETE FROM stories"
            db.exec 'COMMIT'
          catch err
            try db.exec 'ROLLBACK' catch then null
            throw err

          {
            ok: true
            reset_at: value.reset_at ? new Date().toISOString()
            mode: value.mode ? 'full'
          }
      }

      {
        name: 'loraCycleReset'
        regex: /^loraCycleReset$/
        allowedSuffixes: ['json', 'txt', 'csv']
        read: null
        write: (db, value) ->
          throw new Error "sqlite meta loraCycleReset write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          db.exec 'BEGIN'
          try
            db.exec "DELETE FROM lora_training_run_stories"
            db.exec "DELETE FROM lora_training_runs"
            db.exec "DELETE FROM lora_story_usage"
            db.exec "DELETE FROM lora_trained_stories"
            db.exec 'COMMIT'
          catch err
            try db.exec 'ROLLBACK' catch then null
            throw err

          {
            ok: true
            reset_at: value.reset_at ? new Date().toISOString()
            mode: value.mode ? 'full'
          }
      }

      # --- Generic pipeline-run lifecycle ---------------------------------
      # `runRegister{<id>}.json` (write-only)  — INSERT or REPLACE a runs row
      # at launch. Body is the full row payload (status defaults to 'running').
      # `runUpdate{<id>}.json` (write-only)    — partial UPDATE; only the keys
      # present in the body are written. Use at shutdown/finish to set
      # finished_at + status (+ optional shutdown reason).
      # `runById{<id>}.json`   (read-only)     — SELECT one row.
      # `runHistory.jsonl`     (read-only)     — SELECT all rows, newest first.
      {
        name: 'runRegister'
        regex: /^runRegister\{([^}]+)\}$/
        allowedSuffixes: ['json']
        read: null
        write: (db, value, runID) ->
          throw new Error "sqlite meta runRegister write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          writeRunID = value.run_id ? runID
          throw new Error "sqlite meta runRegister run_id mismatch" unless writeRunID is runID

          db.prepare("""
            INSERT INTO runs (run_id, pipeline, started_at, finished_at, status, logdir, pid, cwd, shutdown)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
              pipeline    = excluded.pipeline,
              started_at  = excluded.started_at,
              finished_at = excluded.finished_at,
              status      = excluded.status,
              logdir      = excluded.logdir,
              pid         = excluded.pid,
              cwd         = excluded.cwd,
              shutdown    = excluded.shutdown
          """).run(
            writeRunID
            value.pipeline ? null
            value.started_at ? null
            value.finished_at ? null
            value.status ? 'running'
            value.logdir ? null
            (if Number.isFinite(Number(value.pid)) then Number(value.pid) else null)
            value.cwd ? null
            (if value.shutdown? then JSON.stringify(value.shutdown) else null)
          )
          { ok: true, run_id: writeRunID }
      }

      {
        name: 'runUpdate'
        regex: /^runUpdate\{([^}]+)\}$/
        allowedSuffixes: ['json']
        read: null
        write: (db, value, runID) ->
          throw new Error "sqlite meta runUpdate write expects object" unless value? and typeof value is 'object' and not Array.isArray(value)
          # Build a partial UPDATE from whichever fields the caller sent.
          sets = []
          binds = []
          for col in ['pipeline', 'started_at', 'finished_at', 'status', 'logdir', 'cwd']
            if Object.prototype.hasOwnProperty.call(value, col)
              sets.push "#{col} = ?"
              binds.push value[col]
          if Object.prototype.hasOwnProperty.call(value, 'pid')
            sets.push "pid = ?"
            binds.push (if Number.isFinite(Number(value.pid)) then Number(value.pid) else null)
          if Object.prototype.hasOwnProperty.call(value, 'shutdown')
            sets.push "shutdown = ?"
            binds.push (if value.shutdown? then JSON.stringify(value.shutdown) else null)
          if sets.length is 0
            return { ok: true, run_id: runID, updated: 0 }
          binds.push runID
          info = db.prepare("UPDATE runs SET #{sets.join(', ')} WHERE run_id = ?").run binds...
          { ok: true, run_id: runID, updated: info.changes ? 0 }
      }

      {
        name: 'runById'
        regex: /^runById\{([^}]+)\}$/
        allowedSuffixes: ['json']
        read: (db, runID) ->
          row = db.prepare("""
            SELECT run_id, pipeline, started_at, finished_at, status, logdir, pid, cwd, shutdown
            FROM runs WHERE run_id = ?
          """).get(runID)
          return null unless row?
          shutdown = null
          if row.shutdown
            try shutdown = JSON.parse(row.shutdown) catch then shutdown = row.shutdown
          {
            run_id: row.run_id
            pipeline: row.pipeline
            started_at: row.started_at
            finished_at: row.finished_at
            status: row.status
            logdir: row.logdir
            pid: row.pid
            cwd: row.cwd
            shutdown: shutdown
          }
        write: null
      }

      # --- Change-log diff (step 5) -------------------------------------
      # `changesSince{<arg>}.json` — return aggregated per-table changes since
      # an anchor. The arg can be:
      #   • a UUID run_id  → resolve to runs.started_at, anchor by ts
      #   • an ISO 8601 ts → use directly as the ts anchor
      #   • an integer     → anchor by change_id
      # Returns:
      #   {
      #     anchor: { kind, value, resolved_ts?, resolved_change_id },
      #     total_changes: N,
      #     by_table: {
      #       stories: { count, inserts, updates, deletes, ids: [...] },
      #       ...
      #     }
      #   }
      {
        name: 'changesSince'
        regex: /^changesSince\{([^}]+)\}$/
        allowedSuffixes: ['json']
        read: (db, arg) ->
          # Discriminate the arg shape.
          anchorChangeId = null
          anchorTs = null
          kind = null
          if /^\d+$/.test(arg)
            anchorChangeId = parseInt(arg, 10)
            kind = 'change_id'
          else if /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(arg)
            row = db.prepare("SELECT started_at FROM runs WHERE run_id = ?").get(arg)
            throw new Error "sqlite meta changesSince: no run with run_id '#{arg}'" unless row?
            anchorTs = row.started_at
            kind = 'run_id'
          else if /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(arg)
            anchorTs = arg
            kind = 'timestamp'
          else
            throw new Error "sqlite meta changesSince: arg '#{arg}' is not a uuid, ISO timestamp, or change_id"

          rows = if anchorChangeId?
            db.prepare("""
              SELECT change_id, ts, table_name, op, row_id
              FROM _change_log
              WHERE change_id > ?
              ORDER BY change_id ASC
            """).all(anchorChangeId)
          else
            db.prepare("""
              SELECT change_id, ts, table_name, op, row_id
              FROM _change_log
              WHERE ts >= ?
              ORDER BY change_id ASC
            """).all(anchorTs)

          resolvedChangeId = if rows.length then rows[0].change_id - 1 else null
          resolvedChangeId = anchorChangeId if anchorChangeId? and resolvedChangeId is null

          byTable = {}
          for r in rows
            t = r.table_name
            byTable[t] ?= { count: 0, inserts: 0, updates: 0, deletes: 0, ids: [] }
            byTable[t].count += 1
            switch r.op
              when 'INSERT' then byTable[t].inserts += 1
              when 'UPDATE' then byTable[t].updates += 1
              when 'DELETE' then byTable[t].deletes += 1
            byTable[t].ids.push r.row_id if r.row_id? and byTable[t].ids.length < 200

          {
            anchor:
              kind: kind
              value: arg
              resolved_ts: anchorTs
              resolved_change_id: resolvedChangeId
            total_changes: rows.length
            by_table: byTable
          }
        write: null
      }

      {
        name: 'runHistory'
        regex: /^runHistory$/
        allowedSuffixes: ['jsonl']
        read: (db) ->
          rows = db.prepare("""
            SELECT run_id, pipeline, started_at, finished_at, status, logdir, pid, cwd, shutdown
            FROM runs
            ORDER BY started_at DESC
          """).all()
          for row in rows
            shutdown = null
            if row.shutdown
              try shutdown = JSON.parse(row.shutdown) catch then shutdown = row.shutdown
            {
              run_id: row.run_id
              pipeline: row.pipeline
              started_at: row.started_at
              finished_at: row.finished_at
              status: row.status
              logdir: row.logdir
              pid: row.pid
              cwd: row.cwd
              shutdown: shutdown
            }
        write: null
      }
    ]

    M.addMetaRule "sqlite",
      /^(?:storyByID\{[^}]+\}|partsFor\{[^}]+\}|kagFor\{[^}]+\}|oracleFailureFor\{[^}]+\}|expandedPartsFor\{[^}]+\}|storiesWithKag\{[^}]+\}|storiesMissingKag|allStories|trainedStories|loraStoryUsage|loraTrainingRun\{[^}]+\}|loraTrainingRuns|loraCycleReset|sqliteResetAll|runRegister\{[^}]+\}|runUpdate\{[^}]+\}|runById\{[^}]+\}|runHistory|changesSince\{[^}]+\})\.(json|jsonl|txt|csv)$/i,
      (key, value) ->
        debugLog "meta key", key, "write?", value isnt undefined

        suffixMatch = key.match /\.([A-Za-z0-9]+)$/
        return undefined unless suffixMatch?

        suffix = suffixMatch[1].toLowerCase()
        formatter = FORMATTERS[suffix]
        return undefined unless formatter?

        requestKey = key.replace /\.[A-Za-z0-9]+$/, ''
        debugLog "parsed", "requestKey=#{requestKey}", "suffix=#{suffix}"

        matchedRequest = null
        matchedArgs = null

        for request in REQUESTS
          match = requestKey.match request.regex
          debugLog "regex check", request.name, String(request.regex), "matched=#{!!match}"
          continue unless match?
          matchedRequest = request
          matchedArgs = match.slice(1)
          break

        unless matchedRequest?
          debugLog "no sqlite request match", requestKey
          return undefined

        unless matchedRequest.allowedSuffixes.includes suffix
          throw new Error "sqlite meta request #{matchedRequest.name} does not allow .#{suffix}"

        debugLog "matched request", matchedRequest.name, "args=#{JSON.stringify(matchedArgs)}"

        if value is undefined
          debugLog "read start", matchedRequest.name, "args=#{JSON.stringify(matchedArgs)}"
          result = matchedRequest.read(db, matchedArgs...)
          if Array.isArray(result)
            debugLog "read result", matchedRequest.name, "rows=#{result.length}"
          else
            debugLog "read result", matchedRequest.name, "type=#{typeof result}"
          return formatter.read(result)

        throw new Error "sqlite meta request #{matchedRequest.name} is read-only" unless typeof matchedRequest.write is 'function'

        decoded = formatter.write(value)
        if Array.isArray(decoded)
          debugLog "write start", matchedRequest.name, "args=#{JSON.stringify(matchedArgs)}", "rows=#{decoded.length}"
        else
          debugLog "write start", matchedRequest.name, "args=#{JSON.stringify(matchedArgs)}", "type=#{typeof decoded}"
        matchedRequest.write(db, decoded, matchedArgs...)
        debugLog "write done", matchedRequest.name, "args=#{JSON.stringify(matchedArgs)}"

# Surface the request catalogue for introspection (the agent manifest reads
# this to advertise what request keys exist). Mirrors the REQUESTS list above;
# kept in sync by hand when a new request is added.
module.exports.requestNames = [
  'storyByID',          'partsFor',         'kagFor',          'oracleFailureFor'
  'expandedPartsFor',   'storiesWithKag',   'storiesMissingKag'
  'allStories',         'trainedStories',   'loraStoryUsage'
  'loraTrainingRun',    'loraTrainingRuns', 'sqliteResetAll',  'loraCycleReset'
  'runRegister',        'runUpdate',        'runById',         'runHistory'
  'changesSince'
]
