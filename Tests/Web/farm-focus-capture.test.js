'use strict';

// The two pieces of the farm focus pane's capture wiring that are value
// logic rather than DOM: what output size a recording will come out at,
// and what the download gets called. Everything else in farm-focus.js is
// page composition and stays integration-only.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web'
);

// farm-focus.js attaches to `window.FarmFocus` (the farm/ convention);
// the capture modules it reads through hang off `window.Baguette._X`.
function load() {
  const win = loadBrowserModules([
    path.join(WEB, 'capture', 'capture-size.js'),
    path.join(WEB, 'capture', 'capture-settings.js'),
    path.join(WEB, 'farm', 'farm-focus.js'),
  ]);
  return { FarmFocus: win.FarmFocus, CaptureSettings: win.Baguette._CaptureSettings };
}

// A focus pane with no DOM: `show()` is what builds the markup and mounts
// the real picker, and neither is needed to ask what size comes out.
function focusWith({ settings, context }) {
  const { FarmFocus, CaptureSettings } = load();
  const focus = new FarmFocus({ querySelector: () => null });
  focus.captureMenu = { settings: new CaptureSettings(settings) };
  focus._getRecorderContext = () => context;
  return focus;
}

const BEZEL = {
  canvas: { width: 585, height: 1266 },
  frameImg: { naturalWidth: 1290 },
  screen: { viewport: { width: 1290, height: 2796 } },
};

test('a ratio resolves against the composited bezel, not the scaled canvas', () => {
  const focus = focusWith({ settings: { size: 'square' }, context: BEZEL });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 2796, height: 2796 });
});

test('leaving the bezel out resolves against the live canvas instead', () => {
  const focus = focusWith({
    settings: { size: 'square', withFrame: false },
    context: BEZEL,
  });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 1266, height: 1266 });
});

test('a fixed preset ignores the source entirely', () => {
  const focus = focusWith({ settings: { size: 'appstore-6.9' }, context: BEZEL });
  assert.deepEqual(focus._resolvedOutputSize(), { width: 1290, height: 2796 });
});

test('nothing resolves without a live canvas to record', () => {
  const focus = focusWith({ settings: { size: 'square' }, context: null });
  assert.equal(focus._resolvedOutputSize(), null);
});

// ── download naming ──────────────────────────────────────────────

function naming(sizeSpec, planned, output) {
  const { CaptureSettings } = load();
  return {
    settings: new CaptureSettings({ size: sizeSpec }),
    plannedSize: planned,
    outputSize: output,
  };
}

function nameOf(sizeSpec, planned, output, filename) {
  const focus = focusWith({ settings: {}, context: null });
  return focus._recordFilename({ filename }, naming(sizeSpec, planned, output));
}

test('the download carries the size the recording actually came out at', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 2796, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026-square-2796x2796.mp4'
  );
});

// A recorder that doesn't understand the capture size still produces a
// file — it just isn't the size that was asked for. Naming it after the
// preset anyway would be a lie, so only the real pixels go in.
test('a recorder that ignored the size gets plain dimensions, not the preset', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 1290, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026-1290x2796.mp4'
  );
});

test('a name the recorder already slugged is left alone', () => {
  assert.equal(
    nameOf('square', { width: 2796, height: 2796 }, { width: 2796, height: 2796 },
      'simulator-2026-square-2796x2796.mp4'),
    'simulator-2026-square-2796x2796.mp4'
  );
});

test('a native recording keeps the recorder own name', () => {
  assert.equal(
    nameOf('native', { width: 1290, height: 2796 }, { width: 1290, height: 2796 },
      'simulator-2026.mp4'),
    'simulator-2026.mp4'
  );
});

test('a ratio spec never puts a colon in the filename', () => {
  assert.equal(
    nameOf('16:9', { width: 4971, height: 2796 }, { width: 4971, height: 2796 },
      'simulator-2026.webm'),
    'simulator-2026-16-9-4971x2796.webm'
  );
});
