# Ports — the plan (jahbini ruling, 2026-11-07)

This REPLACES "ports drift, verify live" as the intent: ports are now
ASSIGNED by plan. (Still verify live until the plan is activated
everywhere — see Activation.)

## The plan

| port        | what                                                        |
|-------------|-------------------------------------------------------------|
| **8000**    | the puppeteer (controller)                                  |
| **8100**    | the writer (first controlled service)                       |
| **8101–8199** | the writer's pipes (puppet nodes), **oldest pipe = lowest port** |
| **8200**    | the NEXT writer-like service, if the puppeteer ever controls one |
| **8201–8299** | that service's pipes                                       |

General form: controller 8000; controlled service N (1-based) at
8000 + N×100; its pipes at base+1..base+99 ranked by AGE (pipe dir
birthtime, oldest first, name tie-break). Capacity 99 pipes per service.

Why age-rank is stable: a dir's birthtime never changes, and a NEW pipe is
younger than every existing one, so it appends at the top of the range
without shifting anyone. (Deleting a pipe shifts younger pipes down one —
same as the old name-sort on deletion.)

## Where it is implemented (2026-11-07)

- `puppeteer/ui/project.coffee` — `PUPPET_BASE` default 8100 (env
  `PUPPET_BASE` overrides = the controlled service's base);
  `puppetPortFor` = base + 1 + age-rank; `portDefault: 8000`;
  `peerHttpBase` default `http://mac-mini.local:8100`; writer spawn env
  `UI_PORT: 8100`.
- `writer/ui/project.coffee` — `portDefault: 8100`.
- `writer/override/puppeteer.yaml` + `puppeteer/override/puppeteer.yaml`
  roster — 8100.
- `pipeline/mcp/pipe_server.coffee` default UI_PORT — 8100.
- All `puppeteer/config/*.yaml` `peer_http:`/`UI_PORT:` literals and
  script defaults (sat_sweep_run, helper_action_executor, peer_utils,
  hf_queue_gen_ite, helper_scenario_assembler, queue_run_ite,
  streaming/walk_pending*) — 8100. `peer_fleet.js` browser fallback — 8100.

## Activation

Code defaults are the plan; a node's ACTUAL port is whatever UI_PORT its
launcher passed. To activate: relaunch with UI_PORT per the table.
- Laptop (manual nohup pair): done 2026-11-07 — 8000/8100 live.
- Mini (launchd): DONE 2026-11-09. Writer on **8100** (plist UI_PORT=8100),
  puppeteer on 8000, puppets on 81xx (8110/8133/8134). The puppeteer plist's
  stale `EnvironmentVariables.PEER_HTTP=http://localhost:6100` was REMOVED
  (not just repointed) so the section-leader registry (`mac-mini.local:8100`)
  drives the peer URL — see `puppeteer/GPT/ui/project_plugin.md` "Gotcha —
  remove stale PEER_HTTP/PEER_SSH env overrides". NOTE: `kickstart -k` does NOT
  re-read plist `EnvironmentVariables`; use `launchctl bootout`+`bootstrap`.
- `state/puppets.json` registries carry old ports until the reaper prunes
  the dead pids and `ensure_puppet_pipe` re-records on first use.
