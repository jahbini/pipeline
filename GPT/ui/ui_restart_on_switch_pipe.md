# Prompt — make "Switch Pipe UI" restart the UI (incl. in-place)

Hand this to the pipeline UI bot. It is framework-orbit UI infrastructure (applies
to every project/branch using the runner's UI), so port it into the
`@jahbini/pipeline` source.

## Goal

The served page does not hot-reload; relaunching `ui_server` (then the browser
reloads) is how edits to `ui_server.coffee` / `ui/index.html` take effect. Make
the **Switch Pipe UI** button the canonical "restart the UI" action:

- Selecting a real pipe under `PIPES_ROOT` switches to it and relaunches (as before).
- Selecting **nothing** (empty) restarts the **current workspace in place** —
  critical for project workspaces that are NOT under `pipes/` (e.g. the repo root),
  where there is no pipe to "switch" to.

## Make these changes

### 1. `ui_server.coffee` — `handleSwitchPipe`

- **Empty pipe = in-place restart.** Don't `400` on an empty `pipe`; instead set
  the relaunch target to the current workspace:

  ```coffee
  pipeName = String(payload.pipe ? '').trim()
  if pipeName.length
    return sendJson(res, 400, { ok:false, error:'invalid pipe name' }) if pipeName.includes('/') or pipeName.includes(path.sep) or pipeName is '.' or pipeName is '..'
    targetCwd = path.join(PIPES_ROOT, pipeName)
    return sendJson(res, 404, { ok:false, error:'pipe directory not found' }) unless fs.existsSync(targetCwd) and fs.statSync(targetCwd).isDirectory()
  else
    targetCwd = CWD          # empty pipe => restart current workspace in place
  ```

- **Drop the `unchanged` short-circuit.** Do NOT return `{unchanged:true}` when the
  target equals `CWD`; always proceed to relaunch.

- **Relaunch the PROJECT's `ui_server.coffee`, not the shipped one.** The old code
  hardcoded `path.join(EXEC_ROOT, 'ui_server.coffee')`, which relaunches the
  package server in a pipe dir — losing the project's edited UI and its
  `runtime.sqlite` data. Prefer the target workspace's own server:

  ```coffee
  uiServerPath = path.join(targetCwd, 'ui_server.coffee')
  uiServerPath = path.join(EXEC_ROOT, 'ui_server.coffee') unless fs.existsSync(uiServerPath)
  ...
  launchArgs = ['-lc', "sleep 1; exec coffee #{JSON.stringify(uiServerPath)}"]
  child = spawn 'bash', launchArgs,
    cwd: targetCwd
    detached: true
    stdio: 'ignore'
    env: Object.assign {}, process.env, EXEC: EXEC_ROOT, CWD: targetCwd, UI_PORT: String(PORT), UI_BIND_MODE: UI_BIND_MODE
  child.unref()
  setTimeout((-> process.exit(0)), 150)
  ```

### 2. `ui/index.html` — keep the button enabled

In `renderPipeControls` and the `#pipe-select` `change` handler:
`switchButton.disabled = false;` (was disabled when `pipes.length === 0` or the
selection equalled the current pipe).

### 3. `ui/index.html` — `switchPipe()` must fire on empty/current

Remove the early bails that blocked an in-place restart and always POST:

```js
async function switchPipe() {
  const result = byId('launch-result');
  const pipe = byId('pipe-select').value || '';   // empty => restart current workspace in place
  try {
    const res = await fetch('/api/switch_pipe', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pipe })
    });
    const data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || 'switch/restart failed');
    result.textContent = pipe ? `switching UI to pipe ${pipe}...` : 'restarting UI...';
    if (pipe) selectedPipeName = pipe;
    window.setTimeout(() => window.location.reload(), 1800);
  } catch (err) { result.textContent = String(err.message || err); }
}
```

(Removed: `if (!pipe) return;` and `if (pipe === currentPipeName) { …; return; }`.)

## Invariants / why it is safe

- The relaunch spawns a NEW `ui_server` (`sleep 1; exec coffee <uiServerPath>`)
  bound to the same `UI_PORT`. The OLD process exits ~150ms after responding
  `restarting: true`, so the port is free before the new one's `sleep 1` ends.
- `bash -lc` (login shell) must resolve bare `coffee` on PATH — unchanged from the
  prior implementation.
- An in-place restart keeps `CWD` (and thus the same `runtime.sqlite`); only the
  process is replaced, picking up edited `ui_server.coffee` / `ui/index.html`.

## Acceptance

- Pressing **Switch Pipe UI** with no pipe selected restarts the current
  workspace's UI in place: edited `ui_server.coffee` + `ui/index.html` go live, same
  `runtime.sqlite`.
- Selecting a real pipe still switches to it and relaunches.
- The button is never disabled.

## Chicken-and-egg note for whoever applies this

The running `ui_server` still has the OLD restart logic, so it cannot load this fix
via itself — do ONE manual relaunch (`npm run ui` / re-exec) after applying, and the
button works in place thereafter.
