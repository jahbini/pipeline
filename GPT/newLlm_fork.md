# newLlm fork — retired 2026-09-08

A learning exercise from the 2026-09-07 session that has been **superseded
by in-tree edits**. This doc captures what was learned so the same wheel
doesn't get reinvented.

## What it was

A fork of `@frost-beta/llm` v0.4.1 (from
`https://github.com/frost-beta/llm.js`) placed at `~/claude_zone/newLlm/`.
Included:

- Port of `mlex-main`'s Rust `qwen3.rs`, `qwen3_5/mod.rs`,
  `qwen3_5/vision.rs`, `gated_delta.rs`, `moe.rs` into TypeScript files
  under `src/models/`.
- Extension of `kv-cache.ts` with `GatedDeltaCache` (`convState`,
  `recurState`) and `KVCacheOptions.perLayerKind`.
- Extension of `llm.ts` cache allocation to honor `perLayerKind`.
- Sanitize covering `language_model.*` + `model.language_model.*` prefix
  conventions, plus `model.visual.*` / `vision_tower.*` skip.

The mini was wired to it via `writer/package.json`'s
`"@frost-beta/llm": "file:../claude_zone/newLlm"` plus scp overlays into
two pnpm cache dirs plus a sed patch to comment out `qwen3` and `qwen3_5`
from `session_api.coffee`'s `LOCAL_MODELS`.

## Why it was retired

Three problems, in decreasing severity:

1. **Framework-orbit violation** (see `GPT/pipeline_architecture.md`,
   "Two orbits to keep distinct" section). A model class is
   **framework-orbit** and belongs in `~/pipeline/mlx/models/`. Placing
   it under `~/claude_zone/newLlm/` put it outside git and outside the
   normal resolution path — the pnpm-cache scp overlays and the
   `session_api.coffee` sed patch were symptoms of that misplacement,
   not bugs to fix.
2. **Two live implementations for qwen3_5.** The existing
   `~/pipeline/mlx/models/qwen3_5.coffee` is documented and battle-tested
   (see `GPT/qwen3_5.md`, "Verified working: Qwen3.5-4B mac-mini 10
   tok/s"). The fork's `qwen3_5.ts` was untested. Under real oracle load
   on the mini it hit jetsam OOM before generating a single token — 43 GB
   compressed process footprint. The MLX-tracked ceiling
   (`SESSION_API_MEM_CEIL_MB=10240`) never fired because MLX active
   stayed under 10 GB while V8/native intermediates blew up compressor
   swap. The local coffee implementation does not have this issue.
3. **`pnpm install` blows the wiring away.** The mini's overlay-and-patch
   configuration was invisible to git AND ephemeral — any future
   `pnpm install` (including one triggered by `@jahbini/pipeline`
   version bump) would silently revert the fix.

## What was kept

The only genuinely-new capability was the **Case B fix for qwen3 dense**
(tied but not-declared `lm_head.*` in the checkpoint, seen on
`qwen3-0.6b` and `qwen3-1.7b`). That fix has been backported into
`~/pipeline/mlx/models/qwen3.coffee`'s `sanitize` (added 2026-09-08):

```coffee
sanitize: (weights) ->
  return unless @args.tieWordEmbeddings
  delete weights[k] for k of weights when k is 'lm_head.weight' or k.startsWith('lm_head.')
  return
```

Now the LOCAL `qwen3.coffee` handles tied+`lm_head`-in-weights checkpoints
without needing any fork.

## Findings worth remembering

- **qwen3_5 prefix conventions in the wild.** The pipeline's local
  `qwen3_5.coffee`'s sanitize already handles both `language_model.model.*`
  (mlx-community 4-bit release) and `model.language_model.*` (0.8B-Base HF
  release). Documented in `GPT/qwen3_5.md`. Both were also encountered
  during the fork exercise.
- **`vision_tower` naming variants:** `vision_tower.*`, `model.visual.*`,
  and bare `visual.*` all show up depending on checkpoint provenance. The
  local `qwen3_5.coffee` sanitize drops all three via
  `dropped 326 unused (mtp/visual)`.
- **conv1d weight shape:** MLX depthwise convention is `[C, K, 1]`. Some
  HF-style checkpoints (Qwen/Qwen3.5-4B-mlx4) ship `[C, 1, K]`. The
  local `qwen3_5.coffee` sanitize does the conditional transpose. The
  fork also implemented this but the pattern to remember is: detect via
  `shape[1] == 1`.
- **`mx.toSnakeCase` behavior:** in `@frost-beta/mlx`, model params are
  snake_cased at strict-load time; checkpoint keys are taken as-is. A
  leading-capital identifier like `ALog` is NOT snake_cased (early return
  in `toSnakeCase`), so the model class can keep `A_log` as `ALog`
  verbatim.
- **16 GB mini + hybrid qwen3_5 + oracle_ite embed = jetsam OOM.** The
  embed step does a full prefill of a 3000-char chunk through the linear-
  attn recurrence. Even with the battle-tested local coffee, embed
  memory spikes are large. `q35_4` and `Q_9B` sit in hospital with
  `category: soft_limit` until a bigger host (32 GB+) is available OR
  the embed path is made optional.
- **Never write a shim inside `.pnpm/`.** Everything in a pnpm cache dir
  is a copy that pnpm feels free to rebuild. If you need to change a
  package's behavior locally, use the `writer/node_modules/@jahbini/pipeline
  → ~/pipeline` symlink pattern from `GPT/mac-mini-sync.md` — that survives
  as long as you re-symlink after each `pnpm install`.

## Related

- `GPT/qwen3_5.md` — the authoritative model-class reference.
- `GPT/hospital.md` — Case A (NVFP4) and Case B (untied/tied lm_head)
  bug classes. Case B's Case-2 (tied with quantized triple in weights)
  is what this fork exercise added coverage for on the pipeline side.
- `GPT/mac-mini-sync.md` — the correct way to iterate on
  `mlx/models/*.coffee` across laptop + mini.
