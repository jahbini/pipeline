# Prompt — make "Switch Pipe UI" restart the UI server in place

Hand this to the pipeline UI bot. It is framework-orbit UI infrastructure (applies
to every project/branch using the runner's UI), so port it into the
`@jahbini/pipeline` source.

## Goal

Pressing the **Switch Pipe UI** button should always relaunch the `ui_server`
process — an in-place restart — so edits to `ui_server.coffee` or `ui/index.html`
take effect. The served page does not hot-reload; relaunching the server (then
reloading the browser) is how new UI code loads. The Switch-Pipe flow already
relaunches `ui_server` when moving to a *different* pipe dir; this generalizes it
into the canonical "restart the UI" action.

## Make exactly these two changes

### 1. `ui_server.coffee` — `handleSwitchPipe`

Remove the early-return that short-circuits when the selected pipe equals the
current workspace:

```coffee
# DELETE this line — it skips the relaunch when nothing "changed":
return sendJson(res, 200, { ok: true, pipe: pipeName, cwd: targetCwd, unchanged: true }) if path.resolve(targetCwd) is path.resolve(CWD)
```

With it gone, execution always falls through to the existing relaunch block:

```coffee
launchArgs = ['-lc', "sleep 1; exec coffee #{JSON.stringify(path.join(EXEC_ROOT, 'ui_server.coffee'))}"]
child = spawn 'bash', launchArgs, cwd: targetCwd, detached: true, ...
```

so pressing Switch Pipe relaunches `ui_server` even when staying in the current
workspace (a true in-place restart).

### 2. `ui/index.html` — keep the Switch Pipe button enabled

The button was disabled whenever the selection equalled the current pipe, which
blocked the in-place restart. Keep it enabled in both places that set it:

- in `renderPipeControls`:
  `switchButton.disabled = false;`
  (was `pipes.length === 0 || !desired || desired === current`)
- in the `#pipe-select` `change` handler:
  `byId('switch-pipe-button').disabled = false;`
  (was `!selectedPipeName || selectedPipeName === currentPipeName`)

## Invariants / why it is safe

- The relaunch spawns a NEW `ui_server` (`sleep 1; exec coffee ui_server.coffee`)
  bound to the same `UI_PORT`. The OLD process must exit after responding
  `restarting: true` so the new one can bind that port; the `sleep 1` covers the
  handoff. (The handler already exits after sending the response.)
- No other behavior changes — switching to a *different* pipe still works exactly
  as before; this only stops the same-workspace short-circuit and the button
  disable.

## Acceptance

- With the current workspace selected, pressing **Switch Pipe UI** restarts
  `ui_server`; after the browser reloads, edits to `ui_server.coffee` /
  `ui/index.html` are live.
- The Switch Pipe button is never disabled.
