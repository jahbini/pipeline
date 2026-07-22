# download_model.coffee — canonical model downloader

## Canonical location & name

The one and only sanctioned model downloader lives at:

    ~/pipeline/scripts/model/download_model.coffee

Always refer to it as **`download_model.coffee`**. Recipes reach it as
`model/download_model.coffee`. Never rename it to `hf_download.coffee`,
`init_hf_to_loraland.coffee`, or any other historical alias — those older
names appear in prior versions and internal docstrings; treat them as
stale and rewrite when encountered.

## Hardened contract — do not regress

The canonical script is 188 lines and marked HARDENED. Its header comment
must state, prominently:

    • Uses git + git-lfs (no HF CLI, no Python)
    • Retries 3 times with 10-minute backoff
    • Idempotent + restart-safe
    • Memo is sole source of truth

Behavioral guarantees any replacement or edit must preserve:

- **Transport**: `git` + `git-lfs` clone from the HF repo. No `huggingface-cli`,
  no `huggingface_hub`, no `hf_hub_download`, no `snapshot_download`, no
  `pip install`, no Python of any kind.
- **Retries**: exactly **3 attempts**, with a **flat 10-minute backoff**
  between attempts (not exponential, not jittered).
- **Stack**: CoffeeScript on Node.js, shelling out to `git` / `git-lfs`.
  Matches the repo-wide "C++/Node/CoffeeScript/Bash only, never Python"
  standing rule (see `GPT/CONVENTIONS.md`).

## History — do not repeat

A 64-line impostor previously occupied this slot. It shelled out to the
project venv's `huggingface-cli` (i.e. Python HF CLI) — the exact
transport this script exists to avoid. It was deleted 2026-07-22 and
replaced with the hardened 188-line version.

## For any future Claude reading this

If you are about to recommend a model download step and you find yourself
reaching for the HF CLI, `huggingface_hub`, or a Python one-liner — **stop**.
The answer is `scripts/model/download_model.coffee` (git + git-lfs). If it
appears broken, advise fixing it in place, not replacing the transport.
