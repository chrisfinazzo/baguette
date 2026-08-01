'use strict';

const fs = require('node:fs');
const vm = require('node:vm');

/**
 * Loads a browser IIFE module (one that attaches its exports to
 * `window.Baguette.X`) and returns the resulting `window.Baguette`
 * namespace.
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
  const code = fs.readFileSync(filePath, 'utf8');
  const wrapped = `(function (window) {\n${code}\n});`;
  const factory = vm.runInThisContext(wrapped, { filename: filePath });
  const window = {};
  factory(window);
  return window.Baguette;
}

module.exports = { loadBrowserModule };
