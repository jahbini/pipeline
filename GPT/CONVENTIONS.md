# Collaboration Conventions

Rules the human has stated explicitly. Read this at session start.

## Working surface

- Freely edit `ui/`, `ui_server.coffee`, `scripts/`, `config/` without asking
  permission. These are the normal working surface.
- Do NOT edit `config/*.yaml` recipe files for tuning — use
  `override/<recipe>.yaml` instead. See `GPT/README.md`.
- Reserve confirmation for genuinely destructive actions: deleting committed
  data, force-pushing, dropping database tables.

## Technology stack

- C++, Node.js, CoffeeScript, Bash only.
- Never Python for any task — no python3 one-liners, no pip, no venv
  references in scripts.
- Never launch Xcode GUI. CLI tools (xcrun, xcodebuild, clang) from the
  terminal are fine.

## File access

- Full read access to everything tracked in `.git` — no need to ask.
- `test/` is gitignored scratch space. Use it freely for temp files, test
  scripts, probes, synthetic data. No cleanup obligation.
- `mlx/` is an up-to-date checkout of the MLX source from GitHub. Use it
  directly for exploring the C++ API, headers, kernel implementations,
  and op signatures. Do not modify it.

## Tools: shared utilities behind `S.tools`

Shared functionality used by more than one step lives in `tools/<toolname>.coffee`
and is accessed only through `S.tools.<toolname>.<entrypoint>(args...)`.

**Resolution (CWD↠BASE↠EXEC shadowing, deduped — same tier order as
step scripts):**

```
1. {CWD}/tools/<toolname>.coffee    ← per-pipe override (recipe-local)
2. {BASE}/tools/<toolname>.coffee   ← project root
3. {EXEC}/tools/<toolname>.coffee   ← runner home (= bundled when installed
                                      as node_modules/@jahbini/pipeline)
```

First file found wins. In the monolith layout (working in this repo
directly) all three resolve to the same path and dedupe to one
candidate. The canonical/bundled tools live in `{EXEC}/tools/`; to
override for a single pipe, drop `{CWD}/tools/<toolname>.coffee` into
that pipe's working directory.

**Call shape (synchronous to the step script):**

```coffee
@step =
  action: (S) ->
    embed = S.tools.embedding_blob
    blob = embed.floatArrayToBlob floatArr
```

`S.tools` is a proxy. First reference to a tool name triggers load + cache
within that step's run. Each step gets a fresh `S.tools` — tool-loading
state never leaks between steps.

**The tool contract (HARD rules — break these and it stops being a tool):**

- A tool MUST NOT hold module-level mutable state. No `cache = {}` at the
  top of the file that accumulates across calls.
- A tool MUST NOT receive `S`, `M`, the ledger, the memo, or any
  runner-injected object. It takes ordinary arguments, returns ordinary
  values.
- Two calls to the same entrypoint with the same arguments produce the
  same observable result (modulo what's on disk, which the caller
  controls). No hidden warm-up, no first-call-is-different.
- A tool MAY read from and write to the filesystem — that is I/O, not
  state. The tool itself remembers nothing between calls. Disk
  persistence is the caller's concern.
- A tool is NEVER a step. The recipe loader's step discovery does not
  walk `tools/`. A tool has no `@step =` export; it exports a plain
  object of functions (or a single function). If a `tools/` file
  accidentally exports an `@step =`, the tool loader ignores it and the
  step discovery never sees it.
- A tool cannot `L.need`, cannot `L.make`, cannot read artifacts, cannot
  register a request key, cannot call MLX. It has no claim on the run's
  progress.

**Why tools exist:** any per-pipe bug or local tweak goes in
`{CWD}/tools/<name>.coffee` and wins for that pipe only — no fork of the
runner, no fork of the step script. The shadowing is symmetric with how
step scripts are resolved, so the same mental model applies.

## `fs` stinginess in step scripts

Step scripts should NOT import `fs` directly. The runner, the meta layer,
and tools handle filesystem access on the step's behalf. Two narrow
exceptions:

1. Steps whose declared purpose IS a disk side effect — model download,
   model quantization, LoRA training. Their disk activity IS the output
   (often a `target:` artifact pointing at a directory).
2. Nothing else.

Adapter sniffing, temp file cleanup, "does this checkpoint exist"
probes, etc., belong in a tool not in the step script's body. Currently
shipped tools for these needs:

- `S.tools.adapter` — `exists(path)`, `hasAdapterConfig(path)`,
  `latestCheckpoint(path)`, `resolveResumeFile(path, override)`.
  Consolidates the LoRA/eval adapter probes.
- `S.tools.embedding_blob` — `floatArrayToBlob(arr)`,
  `blobToFloatArray(buf)`, `meanOfFloatArrays(arrs)`,
  `cosineSimilarity(a, b)`. SQLite BLOB glue and cosine math for
  the 1024-dim voice embeddings that `L.callLLM({op:'embed'})`
  produces.

Retired 2026-07-24: `S.tools.tmp_file` (mint/remove tmp safetensors
paths) and `S.tools.cache_embedding`'s safetensors-reader helpers.
Both died when oracle and eval moved to `L.callLLM({op:'embed'})` —
no temp file to mint, no safetensors file to read. See
`GPT/eval_ite/embedding_blob.md`.

No remaining step-script fs/sql-direct-access violations. The last one
(`scripts/diary_ite/collect_diary_kag_ite.coffee` opening
`runtime.sqlite` directly) was retired 2026-06-26 by adding a
`kagByKeyword{<keyword>}.jsonl` meta request to `meta/sqlite.coffee`
and rewriting the step to consume it via `L.theLowdown(...)`. The
step's business logic (per-event match selection, cross-iteration story
dedup, chunk_text regeneration from `story.text` when the row's
chunk_text is empty) stayed in the step — only the SQL moved.

## Step scripts are location-anonymous

A step script in any recipe **must not know where on disk it is executing
from**. It cannot use path-relative imports, `__dirname`-relative reads,
or hardcoded sibling-directory references. The runner is free to load
step scripts from anywhere — `scripts/<category>/<step>.coffee` today,
an installed `node_modules/@jahbini/pipeline/...` path on the mac-mini,
an ad-hoc experiment directory tomorrow.

The legal surface a step script may touch:

- its own file contents
- the `S` ledger the runner injects (`need`, `make`, `peek`, `param`,
  `callMLX`, `saveThis`, `theLowdown`, `done`)
- request keys the meta layer dispatches (`storyByID{...}.json`,
  `kagEmbeddingRegister{...}.json`, ...)
- Node built-ins (`fs`, `path`, `os`, ...) — globally addressable, not
  location-dependent
- packages resolved by name through Node's normal module resolution
  (`require 'js-yaml'`, etc.)

**Forbidden**: `require '../helpers/x'`, `require './sibling'`, paths
built from `__dirname` or `__filename`, anything that hardcodes
`scripts/_helpers/...`.

Any shared functionality not contained in the step script itself MUST
live in **the pipeline runner** (exposed through `S`) or in **the meta
layer** (exposed through a request key). If neither home fits, that is
a signal to discuss a new paradigm before writing the helper — do not
work around the rule with a private import path.

Established 2026-06-26. Initial migration (cache_embedding into
`tools/`, accessed via `S.tools.cache_embedding`) completed same day.
The `cache_embedding` tool was later (2026-07-24) trimmed to just
the SQLite-blob + cosine helpers and renamed `embedding_blob` — the
safetensors-reader chain it originally carried died with the port to
in-process `L.callLLM({op:'embed'})`. See `GPT/eval_ite/embedding_blob.md`.
The companion `fs` stinginess rule still flags violations — see that
section.

## Notes and memory

- ALL working notes go in `GPT/` or `gypsy/` so they are committed to the
  repo and visible across machines and branches.
- Do not use hidden directories (`.claude/`, etc.) as the sole home for
  notes. The hidden system may be used as a secondary index, but the
  canonical content lives in the repo.
- Update the relevant `GPT/<area>/*.md` file in the same session where the
  knowledge was gained — not the next morning.
