# Recipe & step lifecycle — the three-tier promotion path

_Landed 2026-08-22. Codifies the "where do new recipes live?"
practice._

The pipeline's resolver already supports three tiers for both
recipes and step scripts (CWD > BASE > EXEC — see `resolveConfigPath`
and `resolveStepScript` in `pipeline_runner.coffee`). This doc names
when work moves between them.

## The three tiers

| tier | path | scope | typical audience |
|---|---|---|---|
| **pipe** | `pipes/<pipe>/config/*.yaml`<br>`pipes/<pipe>/scripts/**/*.coffee` | one pipe | experiment, work-in-progress |
| **project (BASE)** | `~/writer/config/*.yaml`<br>`~/writer/scripts/**/*.coffee` | multiple pipes in this project | proven for THIS project |
| **pipeline (EXEC)** | `~/pipeline/config/*.yaml`<br>`~/pipeline/scripts/**/*.coffee` | any project using @jahbini/pipeline | universal |

## The lifecycle

**1. New recipe or step starts in the pipe** as an experiment.
`pipes/<pipe>/config/foo.yaml` or `pipes/<pipe>/scripts/bar.coffee`.

Why here first: iteration is cheap — no commit/push/reinstall
cycle to reach the runner. Edit, launch, watch, tune. The pipe's
own scripts and configs win over BASE and EXEC because CWD is the
highest-priority tier.

This is especially the pattern for **scripts that need iterative
debugging**: figure out the shape while it's pipe-local, then
promote once it's stable.

**2. Promote to BASE when it's project-scope useful.** If several
pipes in the same project would use the recipe or script, move it
to `~/writer/config/` or `~/writer/scripts/`. Delete the pipe-local
copy — BASE wins over EXEC, and no CWD copy is needed if BASE is
correct for every pipe.

Signals it's ready to promote:
- Another pipe wants the same thing
- The pipe-local version has stopped needing iterative changes
- The paths it references generalize (e.g., using `${MODELS}` for
  model cache, not hardcoded to one model — see `GPT/model_paths.md`)

**3. Promote to EXEC when it's universal.** If the recipe or script
would work for any project using `@jahbini/pipeline` (not just
this project's specific needs), move it to `~/pipeline/config/`
or `~/pipeline/scripts/`. Requires a pipeline version bump + reinstall
downstream, so it's the most expensive promotion.

Signals it's ready:
- The behavior doesn't depend on writer-specific data or scripts
- No hardcoded project paths (`${BASE}/...` references are a smell)
- The scope matches other shipped capabilities

## The reverse direction: keeping something local

If a change to a shipped script needs iterative debugging, the
pattern is the opposite: **copy the shipped script down to the pipe's
own scripts dir**, iterate there, then promote back up once stable.
The pipe-local version shadows the shipped one via the resolver
until you're happy with it. Delete the pipe-local copy after the
change lands upstream.

## What the tiers hold today (2026-08-22)

**Pipeline (EXEC)** — 8 shipped recipes (chat_llm, prompt_ite, reset,
diary_ite, storacle, oracle_ite, train_lora, test), plus universal
steps under `scripts/`.

**Project (BASE)** — 12 pinned recipes in `~/writer/config/`, all
defaulting to the current active model (huihui-ai/Huihui-…) via
`${MODELS}` paths. Universal shipped recipes are shadowed here
because they need model pins that only make sense in this project.

**Pipe** — `pipes/story/scripts/*.coffee` for pipe-specific step
scripts (build_lora_pairs_ite, resolve_story_parts, etc.) and the
diary/oracle forks that override shipped behavior.

## Related

- [`model_paths.md`](model_paths.md) — the `$MODELS` convention that
  makes recipes portable across pipes
- [`pipeline_architecture.md`](pipeline_architecture.md) — the memo,
  the runner, the artifact resolution
- `~/puppeteer/bin/push-to-mini.sh` — pushes local paths to another
  host without a git round-trip (useful for iterating on a pipe
  script that runs on the mac-mini)
