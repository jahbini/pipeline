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

## Notes and memory

- ALL working notes go in `GPT/` or `gypsy/` so they are committed to the
  repo and visible across machines and branches.
- Do not use hidden directories (`.claude/`, etc.) as the sole home for
  notes. The hidden system may be used as a secondary index, but the
  canonical content lives in the repo.
- Update the relevant `GPT/<area>/*.md` file in the same session where the
  knowledge was gained — not the next morning.
