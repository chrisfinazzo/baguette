'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'farm', 'farm-filter.js'
);

// farm-filter.js attaches directly to `window.FarmFilter` (the older
// farm/ convention), not `window.Baguette._X` like the shared SDK.
function FarmFilter() {
  return loadBrowserModule(MODULE_PATH).FarmFilter;
}

function device(overrides) {
  return { platform: 'iphone', runtime: '26.4', uiState: 'live', name: 'A', udid: 'U', ...overrides };
}

test('every facet starts inclusive of all known options', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4', '18.4'] });
  const devices = [
    device({ platform: 'iphone', runtime: '26.4', uiState: 'live' }),
    device({ platform: 'watch', runtime: '18.4', uiState: 'off' }),
  ];
  assert.deepEqual(filter.apply(devices), devices);
});

test('toggle removes then re-adds an option from a facet', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [device({ platform: 'iphone' }), device({ platform: 'ipad' })];

  filter.toggle('platforms', 'ipad');
  assert.deepEqual(filter.apply(devices).map((d) => d.platform), ['iphone']);

  filter.toggle('platforms', 'ipad');
  assert.deepEqual(filter.apply(devices).map((d) => d.platform).sort(), ['ipad', 'iphone']);
});

test('search matches across name, udid, runtime, and platform, case-insensitively', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [
    device({ name: 'iPhone 17 Pro', udid: 'ABC-123' }),
    device({ name: 'iPhone 17 Pro Max', udid: 'DEF-456' }),
  ];
  filter.search = 'def';
  assert.deepEqual(filter.apply(devices).map((d) => d.udid), ['DEF-456']);
});

test('seedRuntimes merges newly discovered runtimes into the inclusive set', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  filter.seedRuntimes(['18.4']);
  const devices = [device({ runtime: '18.4' })];
  assert.deepEqual(filter.apply(devices), devices);
});

test('a runtime never seeded is excluded even though platforms/states are inclusive', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [device({ runtime: '99.0' })];
  assert.deepEqual(filter.apply(devices), []);
});

test('counts tallies devices per platform and per state', () => {
  const FF = FarmFilter();
  const filter = new FF({ runtimes: ['26.4'] });
  const devices = [
    device({ platform: 'iphone', uiState: 'live' }),
    device({ platform: 'iphone', uiState: 'boot' }),
    device({ platform: 'ipad', uiState: 'live' }),
  ];
  assert.deepEqual(filter.counts(devices), {
    platform: { iphone: 2, ipad: 1 },
    state: { live: 2, boot: 1 },
  });
});
