#!/usr/bin/env node
// pipeline-runner — npm bin entrypoint.
//
// Registers the CoffeeScript loader, then defers to the .coffee runner.
// This wrapper exists so users don't need `coffee` globally installed —
// `npm install @jahbini/pipeline-runner` brings everything needed.
require('coffeescript/register');
require('../pipeline_runner');
