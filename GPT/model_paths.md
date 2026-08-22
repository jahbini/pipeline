# Model paths — `$MODELS` cache convention

_Landed 2026-08-19. This supersedes every prior doc that describes
`build/model` / `build/model4` as the canonical location. Those
paths still work as a legacy fallback when `$MODELS` is unset._

## The convention

Base models live in a shared cache under `$MODELS`, nested by
HuggingFace org and repo name, with quantization variants as
sibling directories keyed by suffix:

```
$MODELS/
  <org>/<name>/          raw HF download (git+lfs)
  <org>/<name>-mlx4/     4-bit MLX quantized
  <org>/<name>-mlx8/     8-bit (if produced)
  <org>/<name>-fused-<adapter-sha>/   fused base+adapter
```

Example:

```
~/models/
  huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated/
  huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated-mlx4/
  Qwen/Qwen3-4B-Instruct-2507/
  Qwen/Qwen3-4B-Instruct-2507-mlx4/
```

Multiple pipes on the same host share one `$MODELS` tree — no
per-pipe duplication of a 15GB base download.

## How the paths get pinned

`${VAR}` expansion is performed by the pipeline runner (`loadYamlSafe`
in `pipeline_runner.coffee` — 2026-08-19 addition). Recipes and
overrides can use `${MODELS}` in any string value and it's replaced
with the env var's current value at load time.

Each pipe's `pipes/<pipe>/config/<recipe>.yaml` (highest-priority
recipe tier) pins its model paths explicitly:

```yaml
run:
  loraLand: ${MODELS}/huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated

download_model:
  download_dir: ${MODELS}/huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated

quantize_model:
  src_dir:       ${MODELS}/huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated
  quantized_dir: ${MODELS}/huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated-mlx4

oracle_ask_sqlite:
  model_dir: ${MODELS}/huihui-ai/Huihui-Qwen3-4B-Instruct-2507-abliterated-mlx4
```

Every downstream step that loads the model (chat_llm, storacle,
generate_prompt_*, generate_diary_*, story_outline, story_beats,
scene_planner, state_extractor, compare_adapters_ite, etc.) reads
its own `quantized_model_dir` (or `model_dir` for oracle). That's
where the pin lives.

## Why per-pipe

The pipe's config directory (`pipes/<pipe>/config/*.yaml`) is the
highest-priority recipe tier per `resolveConfigPath` (CWD > BASE >
EXEC). Anything a pipe needs to shadow, it shadows there. Project-
shared recipes at `~/writer/config/` and shipped defaults at
`~/pipeline/config/` no longer carry `build/model[4]` defaults —
those got stripped 2026-08-20 so a missing pin fails loud
instead of silently reading an empty legacy path.

## Env var setup

Set once in your shell:

```sh
export MODELS=$HOME/models
```

Also useful (for HF's own cache to coexist under the same root):

```sh
export HF_HOME=$MODELS
```

Then load a model into a pipe by running its `reset` recipe (which
inlines `download_model` + `quantize_model`) — the recipe fetches
into `$MODELS/<org>/<name>/` and quantizes into
`$MODELS/<org>/<name>-mlx4/` per the pinned paths.

## Legacy `build/model[4]` fallback

`download_model.coffee` derives from `$MODELS` + the `model` param
when no explicit `download_dir` is set. If `$MODELS` is unset, it
falls back to `build/model` (legacy). `quantize_model.coffee` has
no such derivation — its `src_dir`/`quantized_dir` must be pinned
explicitly (or falls back to `build/model[4]` for backward compat).

Older docs that still say `build/model4` describe the legacy
layout. They're accurate when `$MODELS` is unset; when it's set,
substitute `${MODELS}/<org>/<name>-mlx4` for `build/model4` and
`${MODELS}/<org>/<name>` for `build/model` mentally.

## Adapters + fused models: pipe-local

Adapters stay at `pipes/<pipe>/build/adapter*/` — pipe-scoped
because they're the pipe's output, not a reusable cache.

Fused models (base + adapter merged into a self-contained
directory) live under `$MODELS/fused/<org>/<name>-<adapter-sha>/`
when produced (currently manual — no shipped recipe fuses).

## Cross-references

- `~/pipeline/scripts/model/download_model.coffee` — HF fetcher
  with `$MODELS` derivation
- `~/pipeline/scripts/model/quantize_model.coffee` — MLX quantize
- `~/writer/pipes/Huihui-Qwen3-4B-Instruct-2507-abliterated/config/`
  — a fully-pinned pipe example
- `~/puppeteer/bin/sync-models.sh` — push `~/models/` to another
  host (mac-mini)
