'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'capture'
);

function CaptureSettings() {
  return loadBrowserModules([
    path.join(WEB, 'capture-size.js'),
    path.join(WEB, 'capture-settings.js'),
  ]).Baguette._CaptureSettings;
}

/** localStorage stand-in — a plain map with the same three methods. */
function fakeStorage(seed = {}) {
  const map = new Map(Object.entries(seed));
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
}

// ── defaults ─────────────────────────────────────────────────

test('starts native, contain, white, with the bezel on', () => {
  const s = new (CaptureSettings())();
  assert.equal(s.size.id, 'native');
  assert.equal(s.fit, 'contain');
  assert.equal(s.background, '#ffffff');
  assert.equal(s.withFrame, true);
});

// ── the derived plan ─────────────────────────────────────────

test('plans a capture by handing the source through to its size', () => {
  const s = new (CaptureSettings())({ size: 'square', fit: 'cover' });
  assert.deepEqual(s.plan(1000, 2000), {
    width: 2000, height: 2000,
    drawX: 0, drawY: -1000, drawW: 2000, drawH: 4000,
    sourceWidth: 1000, sourceHeight: 2000,
  });
});

// Nothing is letterboxed at native size, so a background would only ever
// paint under a fully-opaque image — reporting it as transparent keeps
// PNG captures of a transparent 3D render honest.
test('reports a transparent background at native size', () => {
  const s = new (CaptureSettings())({ size: 'native', background: '#ff0000' });
  assert.equal(s.effectiveBackground, 'transparent');
});

test('reports the chosen background once a size actually letterboxes', () => {
  const s = new (CaptureSettings())({ size: 'square', background: '#ff0000' });
  assert.equal(s.effectiveBackground, '#ff0000');
});

// ── immutable updates ────────────────────────────────────────

test('with() returns a new value and leaves the original alone', () => {
  const s = new (CaptureSettings())({ size: 'native' });
  const next = s.with({ size: 'square' });
  assert.equal(s.size.id, 'native');
  assert.equal(next.size.id, 'square');
  assert.equal(next.fit, s.fit);
});

test('an unparseable size falls back to native rather than throwing', () => {
  const s = new (CaptureSettings())({ size: 'not-a-size' });
  assert.equal(s.size.id, 'native');
});

test('an unknown fit falls back to contain', () => {
  assert.equal(new (CaptureSettings())({ fit: 'wat' }).fit, 'contain');
});

// ── the wire / CLI vocabulary ────────────────────────────────

test('serialises to the same query params the Swift routes accept', () => {
  const s = new (CaptureSettings())({
    size: 'appstore-6.9', fit: 'cover', background: '#101010',
  });
  assert.deepEqual(s.toQuery(), {
    size: 'appstore-6.9', fit: 'cover', background: '#101010',
  });
});

test('omits size and fit from the query when nothing is being resized', () => {
  assert.deepEqual(new (CaptureSettings())().toQuery(), {});
});

test('names the capture so downloads say what size they came out at', () => {
  const s = new (CaptureSettings())({ size: 'appstore-6.9' });
  assert.equal(s.slug(1290, 2796), 'appstore-6.9-1290x2796');
  assert.equal(new (CaptureSettings())().slug(1290, 2796), '1290x2796');
});

// A colon is legal in an HFS+ filename but the Finder renders it as a
// slash, so `16:9-...` shows up as `16/9-...` in the user's Downloads.
// Sanitise here, once, so screenshots and recordings name files the same.
test('keeps a ratio spec filename-safe', () => {
  const s = new (CaptureSettings())({ size: '16:9' });
  assert.equal(s.slug(4971, 2796), '16-9-4971x2796');
});

test('leaves an already-safe spec alone', () => {
  assert.equal(
    new (CaptureSettings())({ size: '1920x1080' }).slug(1920, 1080),
    '1920x1080-1920x1080'
  );
});

// ── persistence ──────────────────────────────────────────────

test('restores a previously persisted selection', () => {
  const CS = CaptureSettings();
  const storage = fakeStorage();
  new CS({ size: 'square', fit: 'cover', background: '#222222', withFrame: false })
    .persist(storage, 'asc.capture');

  const restored = CS.restore(storage, 'asc.capture');
  assert.equal(restored.size.id, 'square');
  assert.equal(restored.fit, 'cover');
  assert.equal(restored.background, '#222222');
  assert.equal(restored.withFrame, false);
});

test('restores defaults when nothing was ever persisted', () => {
  assert.equal(CaptureSettings().restore(fakeStorage(), 'asc.capture').size.id, 'native');
});

test('restores defaults when the persisted blob is corrupt', () => {
  const storage = fakeStorage({ 'asc.capture': '{not json' });
  assert.equal(CaptureSettings().restore(storage, 'asc.capture').size.id, 'native');
});

test('survives a storage that throws (Safari private browsing)', () => {
  const CS = CaptureSettings();
  const hostile = {
    getItem() { throw new Error('denied'); },
    setItem() { throw new Error('denied'); },
  };
  assert.equal(CS.restore(hostile, 'asc.capture').size.id, 'native');
  assert.doesNotThrow(() => new CS().persist(hostile, 'asc.capture'));
});
