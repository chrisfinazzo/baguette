'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'gestures', 'edge-bands.js'
);

function EdgeBands() {
  return loadBrowserModule(MODULE_PATH).Baguette._EdgeBands;
}

test('classifies a point in the bottom hot zone as "bottom" in portrait', () => {
  const EB = EdgeBands();
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.95 }, 'portrait'), 'bottom');
});

test('classifies a point in the top hot zone as "top" in portrait', () => {
  const EB = EdgeBands();
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.02 }, 'portrait'), 'top');
});

test('classifies a point outside both hot zones as null', () => {
  const EB = EdgeBands();
  const bands = new EB(0.93, 0.07);
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.5 }, 'portrait'), null);
});

test('rotates the hot zones onto visual left/right for portrait-upside-down', () => {
  const EB = EdgeBands();
  const bands = new EB(0.93, 0.07);
  // Physical home-indicator edge is still "bottom" of the device, which
  // is visual-LEFT when the device is rendered upside down.
  assert.equal(bands.classify({ xNorm: 0.02, yNorm: 0.5 }, 'portrait-upside-down'), 'bottom');
  assert.equal(bands.classify({ xNorm: 0.98, yNorm: 0.5 }, 'portrait-upside-down'), 'top');
  assert.equal(bands.classify({ xNorm: 0.5, yNorm: 0.02 }, 'portrait-upside-down'), null);
});

test('honors the caller\'s own thresholds (e.g. touch\'s wider bands)', () => {
  const EB = EdgeBands();
  const touchBands = new EB(0.85, 0.15);
  assert.equal(touchBands.classify({ xNorm: 0.5, yNorm: 0.88 }, 'portrait'), 'bottom');
  // Same point would NOT be in the mouse's narrower band.
  const mouseBands = new EB(0.93, 0.07);
  assert.equal(mouseBands.classify({ xNorm: 0.5, yNorm: 0.88 }, 'portrait'), null);
});
