'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'capture', 'capture-size.js'
);

function CaptureSize() {
  return loadBrowserModule(MODULE_PATH).Baguette._CaptureSize;
}

// ── the preset catalogue ─────────────────────────────────────

test('ships native first, then the App Store pixel sizes, then the ratios', () => {
  const ids = CaptureSize().presets().map((p) => p.id);
  assert.deepEqual(ids, [
    'native',
    'appstore-6.9', 'appstore-6.5', 'appstore-ipad-13',
    'square', '16:9', '9:16', '4:3', '4:5',
  ]);
});

test('every preset carries a human label for the picker', () => {
  for (const preset of CaptureSize().presets()) {
    assert.equal(typeof preset.label, 'string');
    assert.ok(preset.label.length > 0, `${preset.id} has no label`);
  }
});

// ── parsing ──────────────────────────────────────────────────

test('parses a preset id', () => {
  assert.equal(CaptureSize().parse('appstore-6.9').id, 'appstore-6.9');
});

test('parses a literal WxH into a custom size', () => {
  const size = CaptureSize().parse('1920x1080');
  assert.equal(size.id, 'custom');
  assert.deepEqual(size.resolve(400, 800), { width: 1920, height: 1080 });
});

test('parses an unlisted W:H ratio', () => {
  const size = CaptureSize().parse('3:2');
  assert.deepEqual(size.resolve(600, 600), { width: 900, height: 600 });
});

test('rejects garbage rather than guessing', () => {
  const CS = CaptureSize();
  assert.equal(CS.parse('appstore'), null);
  assert.equal(CS.parse('1920x'), null);
  assert.equal(CS.parse('0x100'), null);
  assert.equal(CS.parse(''), null);
  assert.equal(CS.parse(null), null);
});

// ── resolution ───────────────────────────────────────────────

test('native resolves to the source dimensions untouched', () => {
  assert.deepEqual(
    CaptureSize().parse('native').resolve(1290, 2796),
    { width: 1290, height: 2796 }
  );
});

test('an App Store preset resolves to its fixed pixel size', () => {
  assert.deepEqual(
    CaptureSize().parse('appstore-6.9').resolve(400, 800),
    { width: 1290, height: 2796 }
  );
});

// A ratio preset never downscales the source: it grows the short axis so
// the source still fits at 1:1. A portrait phone asked for `square` grows
// sideways to the phone's own height.
test('square grows the narrow axis of a portrait source', () => {
  assert.deepEqual(
    CaptureSize().parse('square').resolve(1290, 2796),
    { width: 2796, height: 2796 }
  );
});

test('16:9 grows a portrait source sideways to a landscape canvas', () => {
  assert.deepEqual(
    CaptureSize().parse('16:9').resolve(1290, 2796),
    { width: 4971, height: 2796 }
  );
});

test('9:16 widens a source that is narrower than 9:16', () => {
  // 1290/2796 ≈ 0.461 is narrower than 9/16 = 0.5625, so height binds and
  // the canvas widens to 2796 × 9/16 — the source still fits at 1:1.
  assert.deepEqual(
    CaptureSize().parse('9:16').resolve(1290, 2796),
    { width: 1573, height: 2796 }
  );
});

// ── placement ────────────────────────────────────────────────

test('contain letterboxes the source and centres it', () => {
  const plan = CaptureSize().parse('square').plan(1000, 2000, 'contain');
  assert.deepEqual(plan, {
    width: 2000, height: 2000,
    drawX: 500, drawY: 0, drawW: 1000, drawH: 2000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('cover fills the canvas and lets the overflow crop', () => {
  const plan = CaptureSize().parse('square').plan(1000, 2000, 'cover');
  assert.deepEqual(plan, {
    width: 2000, height: 2000,
    drawX: 0, drawY: -1000, drawW: 2000, drawH: 4000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('stretch distorts the source to exactly fill the canvas', () => {
  const plan = CaptureSize().parse('1920x1080').plan(1000, 2000, 'stretch');
  assert.deepEqual(plan, {
    width: 1920, height: 1080,
    drawX: 0, drawY: 0, drawW: 1920, drawH: 1080,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

test('native is a no-op placement whatever the fit', () => {
  for (const fit of ['contain', 'cover', 'stretch']) {
    assert.deepEqual(
      CaptureSize().parse('native').plan(1290, 2796, fit),
      {
        width: 1290, height: 2796, drawX: 0, drawY: 0, drawW: 1290, drawH: 2796,
        sourceWidth: 1290, sourceHeight: 2796,
      },
      `fit=${fit}`
    );
  }
});

test('an unknown fit falls back to contain', () => {
  assert.deepEqual(
    CaptureSize().parse('square').plan(1000, 2000, 'wat'),
    CaptureSize().parse('square').plan(1000, 2000, 'contain')
  );
});

test('a zero-sized source yields a zero plan instead of dividing by zero', () => {
  const plan = CaptureSize().parse('square').plan(0, 0, 'contain');
  assert.equal(plan.width, 0);
  assert.equal(plan.height, 0);
  assert.ok(Number.isFinite(plan.drawW));
  assert.equal(plan.sourceWidth, 0);
});

// The Swift `CaptureSize` has to place a frame on the same pixel as this
// one. Swift's `Double.rounded()` rounds half away from zero where
// `Math.round` rounds half up, so they only disagree on a negative half —
// i.e. a `cover` draw origin. `CaptureSizeTests.swift` asserts these
// same numbers; if you change one, change both.
test('a cover overflow rounds the same way the Swift side does', () => {
  const plan = CaptureSize().parse('square').plan(1000, 2001, 'cover');
  assert.equal(plan.drawY, -1001);
  assert.equal(plan.width, 2001);
  assert.equal(plan.drawH, 4004);
});

// ── round-tripping through the wire / storage ────────────────

test('spec round-trips through parse for every preset and for custom sizes', () => {
  const CS = CaptureSize();
  for (const preset of CS.presets()) {
    assert.equal(CS.parse(preset.spec).id, preset.id, preset.id);
  }
  assert.equal(CS.parse(CS.parse('1920x1080').spec).spec, '1920x1080');
});
