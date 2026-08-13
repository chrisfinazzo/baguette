'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'screens', 'companion-screens.js'
);

function CompanionScreens() {
  return loadBrowserModule(MODULE_PATH).Baguette._CompanionScreens;
}

function entriesFor(payload) {
  const map = {};
  for (const entry of CompanionScreens().from(payload).entries()) map[entry.id] = entry;
  return map;
}

test('every companion screen gets an entry, in a stable order', () => {
  const ids = CompanionScreens().from(null).entries().map((e) => e.id);
  assert.deepEqual(ids, ['carplay', 'watch']);
});

test('a connected CarPlay display is ready to open', () => {
  const carplay = entriesFor({ carplay: { available: true } }).carplay;
  assert.equal(carplay.status, 'ready');
  assert.equal(carplay.label, 'CarPlay');
  assert.ok(carplay.canOpen);
});

test('a CarPlay display that is not attached explains how to attach one', () => {
  const carplay = entriesFor({ carplay: { available: false } }).carplay;
  assert.equal(carplay.status, 'absent');
  assert.ok(!carplay.canOpen);
  assert.ok(carplay.instructions.length > 0);
  assert.ok(carplay.instructions.some((step) => /External Displays/.test(step)));
});

test('a booted paired watch is ready, and is labelled with its own name', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Booted' },
  }).watch;
  assert.equal(watch.status, 'ready');
  assert.equal(watch.label, 'Apple Watch Ultra 3');
  assert.equal(watch.udid, 'W-1');
  assert.ok(watch.canOpen);
});

test('a paired watch that is not booted needs booting, not instructions', () => {
  const watch = entriesFor({
    watch: { available: true, udid: 'W-1', name: 'Apple Watch Ultra 3', state: 'Shutdown' },
  }).watch;
  assert.equal(watch.status, 'needs-boot');
  assert.ok(!watch.canOpen);
  assert.equal(watch.udid, 'W-1');
});

test('a phone with no paired watch explains how to pair one', () => {
  const watch = entriesFor({ watch: { available: false } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(watch.instructions.some((step) => /simctl pair/.test(step)));
  assert.equal(watch.label, 'Apple Watch');
});

test('a payload the server never sent reads as nothing available', () => {
  for (const payload of [null, undefined, 'nope', 42, {}, { watch: 'yes' }]) {
    for (const entry of CompanionScreens().from(payload).entries()) {
      assert.equal(entry.status, 'absent', `${JSON.stringify(payload)} → ${entry.id}`);
      assert.ok(!entry.canOpen);
    }
  }
});

test('a watch marked available with no udid cannot be streamed', () => {
  const watch = entriesFor({ watch: { available: true, state: 'Booted' } }).watch;
  assert.equal(watch.status, 'absent');
  assert.ok(!watch.canOpen);
});

test('openable names just the screens a click could actually show', () => {
  const screens = CompanionScreens().from({
    carplay: { available: true },
    watch: { available: true, udid: 'W-1', name: 'Watch', state: 'Shutdown' },
  });
  assert.deepEqual(screens.openable().map((e) => e.id), ['carplay']);
});
