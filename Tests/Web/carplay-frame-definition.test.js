'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'carplay', 'frame-definition.js'
);

function CarPlayFrameDefinition() {
  return loadBrowserModule(MODULE_PATH).Baguette._CarPlayFrameDefinition;
}

const CUPRA = {
  schemaVersion: 1,
  id: 'cupra',
  displayName: 'Cupra',
  viewport: { width: 1920, height: 842 },
  screen: { x: 0, y: 0, width: 1920, height: 752, clipRadius: 0 },
  layers: [{
    id: 'climate',
    image: 'climate-bar.png',
    rect: { x: 0, y: 752, width: 1920, height: 90 },
    z: 'above',
  }],
  stream: { defaultSize: { width: 800, height: 450 }, fit: 'contain' },
};

test('parses Cupra viewport and screen cutout from definition JSON', () => {
  const Def = CarPlayFrameDefinition();
  const def = Def.parse(CUPRA);
  assert.equal(def.id, 'cupra');
  assert.deepEqual(def.viewport, { width: 1920, height: 842 });
  assert.deepEqual(def.screen, {
    x: 0, y: 0, width: 1920, height: 752, clipRadius: 0,
  });
  assert.equal(def.layers.length, 1);
  assert.equal(def.layers[0].z, 'above');
});

test('screenRectPct maps Cupra cutout to percentages of the 1920×842 viewport', () => {
  const Def = CarPlayFrameDefinition();
  const def = Def.parse(CUPRA);
  const pct = def.screenRectPct();
  assert.equal(pct.left, 0);
  assert.equal(pct.top, 0);
  assert.equal(pct.width, 100);
  assert.ok(Math.abs(pct.height - (752 / 842) * 100) < 1e-6);
});

test('layerRectPct maps the climate bar to the bottom band', () => {
  const Def = CarPlayFrameDefinition();
  const def = Def.parse(CUPRA);
  const pct = def.layerRectPct(def.layers[0].rect);
  assert.equal(pct.left, 0);
  assert.ok(Math.abs(pct.top - (752 / 842) * 100) < 1e-6);
  assert.equal(pct.width, 100);
  assert.ok(Math.abs(pct.height - (90 / 842) * 100) < 1e-6);
});

test('parse rejects a screen that spills outside the viewport', () => {
  const Def = CarPlayFrameDefinition();
  assert.throws(() => Def.parse({
    ...CUPRA,
    screen: { x: 0, y: 0, width: 1920, height: 900, clipRadius: 0 },
  }), /viewport/i);
});

test('parse rejects an unknown layer z', () => {
  const Def = CarPlayFrameDefinition();
  assert.throws(() => Def.parse({
    ...CUPRA,
    layers: [{ ...CUPRA.layers[0], z: 'middle' }],
  }), /z/i);
});
