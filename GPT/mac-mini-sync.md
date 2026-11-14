# Laptop ↔ mac-mini live sync (no-git debug loop)

_Landed 2026-08-26 during Qwen3.5 bring-up. Bypasses the git push +
pnpm install cycle for tight iteration when both machines share the
same working tree state._

## When to use this

**During active debugging** of shipped-pipeline code (mostly
`mlx/models/*.coffee`, `meta/*.coffee`, `mcp/*.coffee`) or the writer
UI/scripts. The workflow is:

1. Edit a file on the laptop under `~/pipeline/` or `~/writer/`
2. Run `~/bin/sync-to-mini.sh` (≈3s over LAN)
3. Run the test on mac-mini
4. Iterate

**Switch back to git** once the changes stabilize and you want them
recorded (and want the pnpm cache on both machines to converge on a
committed version).

## Symlink prerequisites

Both machines must have the "live pipeline via symlink" trick set up so
edits to `~/pipeline/` are seen by `~/writer/`'s pipeline_runner.

### On each machine, once (mac-mini AND laptop):

```sh
# Point writer's node_modules copy at ~/pipeline
cd ~/writer/node_modules/@jahbini
[ -e pipeline.pnpm-original ] || mv pipeline pipeline.pnpm-original
rm -f pipeline
ln -s ~/pipeline pipeline

# Point ~/pipeline's node_modules @frost-beta at writer's install
# (so require('@frost-beta/mlx') from ~/pipeline/mlx/ resolves to
#  the native build with mlx.metallib)
cd ~/pipeline/node_modules
[ -e @frost-beta.dev-original ] || mv @frost-beta @frost-beta.dev-original
rm -rf @frost-beta
ln -s ~/writer/node_modules/@frost-beta @frost-beta
```

**pnpm install destroys the symlink** — `~/writer/node_modules/@jahbini/pipeline`
gets reset to point at the fresh `.pnpm/<hash>/...` dir. If you ever run
pnpm install (git-updates included), re-run the symlink step above.

## Passwordless SSH

Assumed set up: `ssh theaiguy@mac-mini.local` must not prompt for a
password. If it does, add the laptop's `~/.ssh/id_ed25519.pub` (or rsa)
to `theaiguy@mac-mini.local`'s `~/.ssh/authorized_keys`.

Same convention as `~/puppeteer/config/remote_launch.yaml`'s peer table.

## The script

`~/bin/sync-to-mini.sh` (verbatim):

```bash
#!/usr/bin/env bash
# Push every file under ~/pipeline/mlx/, ~/pipeline/meta/,
# ~/pipeline/pipe_ui_runner.coffee, the ui/project.coffee plugins,
# ~/writer/bin/*.sh from laptop to mac-mini. Idempotent, delta only.
#
# Runs in ~3s over LAN. Use after any edit that debugging cares about.

set -e
HOST=theaiguy@mac-mini.local

rsync -aq /Users/jahbini/pipeline/mlx/     $HOST:pipeline/mlx/
rsync -aq /Users/jahbini/pipeline/meta/    $HOST:pipeline/meta/
rsync -aq /Users/jahbini/pipeline/tools/   $HOST:pipeline/tools/
rsync -aq /Users/jahbini/pipeline/scripts/ $HOST:pipeline/scripts/
rsync -aq /Users/jahbini/pipeline/mcp/     $HOST:pipeline/mcp/

scp -q /Users/jahbini/pipeline/pipe_ui_runner.coffee  $HOST:pipeline/pipe_ui_runner.coffee
# (pipeline_runner.coffee + ui_server.coffee deleted in the 2026-10-30 cutover;
#  the project plugins ride along too:)
scp -q /Users/jahbini/puppeteer/ui/project.coffee     $HOST:puppeteer/ui/project.coffee
scp -q /Users/jahbini/writer/ui/project.coffee        $HOST:writer/ui/project.coffee
rsync -aq /Users/jahbini/writer/bin/ $HOST:writer/bin/

echo "synced $(date +%H:%M:%S)"
```

**Not synced** (intentional, edit-then-git for these):
- `~/pipeline/GPT/` — docs; belong in git
- `~/pipeline/config/` — shipped recipes; belong in git
- `~/writer/config/`, `~/writer/pipes/` — project state, model dirs
- `~/writer/data/` — the shared data directory (2026-08-26 move); commit
  it once and both machines pull it

## What needs a node recycle after sync (fused world, 2026-11-07)

- **Step scripts + recipes + tools** — **no restart needed.** The fused
  node cache-busts step scripts per run and resolves tools per step.
- **`pipe_ui_runner.coffee`, `meta/*`, `mlx/*`, `ipc/*`, `ui/project.coffee`**
  — RESIDENT in the long-lived node; a change needs a node recycle, GATED
  on run state ([[taskmasters-cooperate-no-kill]] — never while
  `ui/run.status == running`):
  ```sh
  launchctl kickstart -k gui/$(id -u)/com.jahbini.pipe-ui-writer     # or -puppeteer
  ```
  Pipe nodes (81xx): `POST <puppeteer>/api/stop_puppet {pipe}` when idle;
  they respawn lazily with the new code.

## Overnight-reboot durability

Everything above survives a reboot:
- Symlinks are on-disk; not in memory
- `~/bin/sync-to-mini.sh` is under `$HOME`; persistent
- SSH keys persist
- If pnpm re-ran during boot (unlikely but possible), re-do the symlink
  step above once

**What gets wiped on reboot:**
- `/private/tmp/claude-*` scratchpads — don't rely on scripts stored there
- The running fused nodes — launchd respawns the pair; manual/dev nodes restart by hand
- pnpm caches — nothing to preserve

## Rebuilding a broken venv (2026-09-07 incident)

If `~/pipeline/.venv/bin/pip` errors with

```
bad interpreter: <some old path>/.venv/bin/python3: No such file or directory
```

the venv was created against an interpreter that has since been deleted.
Every entry-point script in `.venv/bin/` is orphaned — you can't
`pip install --upgrade` your way out; pip itself is broken.

Rebuild from scratch (matches what `pipeline-demo` / `pipeline-pipes`
installers would do):

```sh
ssh theaiguy@mac-mini.local '
  cd /Users/theaiguy/pipeline
  mv .venv .venv.broken.$(date +%s)   # keep for postmortem, delete later
  /opt/homebrew/bin/python3 -m venv .venv
  .venv/bin/pip install --upgrade pip setuptools wheel
  .venv/bin/pip install -r requirements.txt
'
```

`requirements.txt` pins `mlx==0.31.1 / mlx-lm==0.31.2 / mlx-metal==0.31.1`
(three packages, checked by `validatePythonEnvironment` at runner
startup — see `GPT/pipeline_runner.md` § "Python / MLX env — validate,
never fix"). The runner will not attempt any repair; it only errors
loudly with the paths it tried.

## @frost-beta cross-host symlink leak (2026-10-21)

**Symptom:** MLX recipes launched on the mini via the runner
(`broadcast`, `storacle`, `voice_test`, …) die with
`Cannot find module '@frost-beta/llm'` — even though the writer's
node_modules has it.

**Root cause:** `~/pipeline/node_modules/@frost-beta` was an **absolute**
symlink → `/Users/jahbini/writer/node_modules/@frost-beta` (the
**laptop's** path, mtime Aug 26). It resolves on the laptop but
**dangles on the mini** (no `/Users/jahbini/writer` there — the mini is
`/Users/theaiguy`). The runner only hits it when dep resolution goes
through `~/pipeline` — i.e. once the `writer/node_modules/@jahbini/
pipeline → ~/pipeline` symlink (which `/sync-mini` re-establishes) is
in place. Before that, resolution went via the `.pnpm` copy, which has
`@frost-beta/llm` intact, so the leak was masked.

**Fix (applied both machines):** make it a **relative** symlink so it
resolves to each host's own writer:
```
cd ~/pipeline/node_modules && rm @frost-beta && \
  ln -s ../../writer/node_modules/@frost-beta @frost-beta
```
`../../writer/...` → `/Users/<me>/writer/node_modules/@frost-beta` on
either host. The parked `@frost-beta.dev-original` holds the original
0.4.1 `llm`/`mlx` `.pnpm` symlinks (migration artifact); the live
`@frost-beta` points into the writer's pnpm store. Same
never-bake-a-host-absolute-path lesson as the MODELS glob rule.
