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
# ~/pipeline/pipeline_runner.coffee, ~/writer/ui_server.coffee,
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

scp -q /Users/jahbini/pipeline/pipeline_runner.coffee $HOST:pipeline/pipeline_runner.coffee
scp -q /Users/jahbini/writer/ui_server.coffee          $HOST:writer/ui_server.coffee
rsync -aq /Users/jahbini/writer/bin/ $HOST:writer/bin/

echo "synced $(date +%H:%M:%S)"
```

**Not synced** (intentional, edit-then-git for these):
- `~/pipeline/GPT/` — docs; belong in git
- `~/pipeline/config/` — shipped recipes; belong in git
- `~/writer/config/`, `~/writer/pipes/` — project state, model dirs
- `~/writer/data/` — the shared data directory (2026-08-26 move); commit
  it once and both machines pull it

## What needs a UI restart after sync

- **Editing `writer/ui_server.coffee`** → restart the running ui_server.
  Node caches modules; the process must exit and relaunch.
  ```sh
  curl -s -X POST http://127.0.0.1:4311/api/shutdown_ui
  # It respawns via handleSwitchPipe's exec trick
  # OR kill the `coffee ui_server.coffee` process and re-run `npm run ui`
  ```

- **Editing anything else** (model classes, meta devices, step scripts,
  runner) — **no restart needed.** Each pipeline launch spawns a fresh
  `pipeline_runner` process which `require`s the current files.

## Overnight-reboot durability

Everything above survives a reboot:
- Symlinks are on-disk; not in memory
- `~/bin/sync-to-mini.sh` is under `$HOME`; persistent
- SSH keys persist
- If pnpm re-ran during boot (unlikely but possible), re-do the symlink
  step above once

**What gets wiped on reboot:**
- `/private/tmp/claude-*` scratchpads — don't rely on scripts stored there
- The running ui_server + pipeline_runner processes — restart them manually
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
