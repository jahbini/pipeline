#!/usr/bin/env node
// pipeline-runner — npm bin entrypoint and subcommand dispatcher.
//
// Registers the CoffeeScript loader once, then routes argv[2] to one
// of three behaviors. The dispatch lives in JS (not in the runner)
// so the runner itself stays a pure pipeline executor; the CLI shape
// is the bin script's concern.
//
// Subcommands:
//   pipeline-runner            — run the pipeline (default)
//   pipeline-runner ui         — start the UI HTTP server
//   pipeline-runner ui:init    — copy the shipped ui/ into the
//                                project root so it can be edited
//
require('coffeescript/register');

const fs = require('fs');
const path = require('path');

const PKG_ROOT = path.resolve(__dirname, '..');
const cmd = process.argv[2];

function uiInit() {
  const src = path.join(PKG_ROOT, 'ui');
  const dst = path.join(process.cwd(), 'ui');
  const force = process.argv.includes('--force');

  if (!fs.existsSync(src)) {
    console.error('pipeline-runner ui:init — no ui/ in the installed package.');
    process.exit(1);
  }
  if (fs.existsSync(dst) && !force) {
    console.error(`pipeline-runner ui:init — ${dst} already exists.`);
    console.error('Use --force to overwrite (this will discard your edits).');
    process.exit(1);
  }

  fs.cpSync(src, dst, { recursive: true });
  console.log(`pipeline-runner ui:init — copied ${src} → ${dst}`);
  console.log('');
  console.log('  Edit ui/index.html to customize the frontend for this project.');
  console.log('  Run `pipeline-runner ui` to start the server (default port 4311).');
}

switch (cmd) {
  case 'ui:init':
    uiInit();
    break;
  case 'ui':
    require('../ui_server');
    break;
  default:
    require('../pipeline_runner');
}
