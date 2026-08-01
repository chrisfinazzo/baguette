'use strict';

const fs = require('node:fs');
const vm = require('node:vm');

/**
 * Loads a browser IIFE module into a throwaway `window` and returns that
 * `window`. Most SDK files attach to `window.Baguette.X`; some app-level
 * files (e.g. farm/farm-filter.js) attach directly to `window.X` — call
 * sites pick whichever property the file under test actually uses.
 *
 * Production files stay plain `<script src>`-loadable — no bundler, no
 * module system — this just gives Node a throwaway `window` for the file
 * to attach to, fresh per call so tests never share state.
 *
 * Runs via `runInThisContext`, NOT `vm.createContext` — a fresh VM
 * context is a separate JS realm with its own `Object`/`Array`
 * prototypes, which silently breaks `assert.deepEqual` (prototype-
 * checking) for any object the loaded module returns. Wrapping the
 * source in a function that takes `window` as a parameter keeps
 * everything in this process's realm while still isolating the fake
 * `window` per load.
 */
function loadBrowserModule(filePath) {
  return loadBrowserModules([filePath]);
}

/**
 * Loads several browser IIFE modules into ONE shared throwaway `window`,
 * in order, and returns that `window` — for files that reference each
 * other at load time (e.g. `class Touch extends window.Baguette._Base`),
 * where the lazy `window.Baguette._X` reference pattern the rest of the
 * SDK uses doesn't apply.
 *
 * @param {string[]} filePaths
 * @param {object} [seedWindow] a pre-built object to load onto instead of
 *   a fresh `{}` — e.g. a `FakeElement` (see fake-dom.js), for classes
 *   that register global `window` listeners (keydown/keyup/blur) and
 *   need that `window` to be fireable in tests.
 */
function loadBrowserModules(filePaths, seedWindow) {
  const window = seedWindow || {};
  for (const filePath of filePaths) {
    const code = fs.readFileSync(filePath, 'utf8');
    const wrapped = `(function (window) {\n${code}\n});`;
    const factory = vm.runInThisContext(wrapped, { filename: filePath });
    factory(window);
  }
  return window;
}

module.exports = { loadBrowserModule, loadBrowserModules };
