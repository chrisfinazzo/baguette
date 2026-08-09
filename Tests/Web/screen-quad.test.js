'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'gestures', 'screen-quad.js'
);

function ScreenQuad() {
  return loadBrowserModule(MODULE_PATH).Baguette._ScreenQuad;
}

// Forward bilinear interpolation — the inverse of what `locate` solves.
// Used only to derive known-good (u,v)->(x,y) fixtures for round-trip tests.
function forwardBilinear(quad, u, v) {
  const { topLeft: a, topRight: b, bottomRight: c, bottomLeft: d } = quad;
  return {
    x: (1 - u) * (1 - v) * a.u + u * (1 - v) * b.u + u * v * c.u + (1 - u) * v * d.u,
    y: (1 - u) * (1 - v) * a.v + u * (1 - v) * b.v + u * v * c.v + (1 - u) * v * d.v,
  };
}

test('fromCorners builds a quad from the server wire shape (TL,TR,BR,BL)', () => {
  const SQ = ScreenQuad();
  const quad = SQ.fromCorners([[0.1, 0.2], [0.9, 0.2], [0.9, 0.8], [0.1, 0.8]]);
  assert.deepEqual(quad.topLeft, { u: 0.1, v: 0.2 });
  assert.deepEqual(quad.topRight, { u: 0.9, v: 0.2 });
  assert.deepEqual(quad.bottomRight, { u: 0.9, v: 0.8 });
  assert.deepEqual(quad.bottomLeft, { u: 0.1, v: 0.8 });
});

test('fromCorners returns null for a malformed corners payload', () => {
  const SQ = ScreenQuad();
  assert.equal(SQ.fromCorners(null), null);
  assert.equal(SQ.fromCorners([]), null);
  assert.equal(SQ.fromCorners([[0, 0], [1, 0], [1, 1]]), null);
});

test('locate round-trips every corner and the center of a rectangular quad', () => {
  const SQ = ScreenQuad();
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);

  for (const [u, v] of [[0, 0], [1, 0], [1, 1], [0, 1], [0.5, 0.5], [0.25, 0.75]]) {
    const { x, y } = forwardBilinear(quad, u, v);
    const located = quad.locate(x, y);
    assert.ok(Math.abs(located.u - u) < 1e-6, `u: ${located.u} vs ${u}`);
    assert.ok(Math.abs(located.v - v) < 1e-6, `v: ${located.v} vs ${v}`);
    assert.equal(located.inside, true);
  }
});

test('locate round-trips a skewed trapezoid, not just an axis-aligned rect', () => {
  const SQ = ScreenQuad();
  const quad = SQ.fromCorners([[0.35, 0.15], [0.55, 0.25], [0.6, 0.85], [0.3, 0.75]]);

  for (const [u, v] of [[0, 0], [1, 0], [1, 1], [0.5, 0.5], [0.2, 0.9]]) {
    const { x, y } = forwardBilinear(quad, u, v);
    const located = quad.locate(x, y);
    assert.ok(Math.abs(located.u - u) < 1e-6, `u: ${located.u} vs ${u}`);
    assert.ok(Math.abs(located.v - v) < 1e-6, `v: ${located.v} vs ${v}`);
  }
});

test('locate reports a point well outside the quad as not inside', () => {
  const SQ = ScreenQuad();
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);
  const located = quad.locate(0.0, 0.0);
  assert.equal(located.inside, false);
});

test('locate treats a point right at the quad edge as inside despite floating-point noise', () => {
  const SQ = ScreenQuad();
  const quad = SQ.fromCorners([[0.3, 0.2], [0.7, 0.2], [0.7, 0.8], [0.3, 0.8]]);
  const located = quad.locate(0.3, 0.8); // exact bottomLeft corner
  assert.equal(located.inside, true);
});

test('contentRect returns the full box when the aspect ratios already match', () => {
  const SQ = ScreenQuad();
  const canvas = {
    width: 320, height: 240,
    getBoundingClientRect: () => ({ left: 10, top: 20, width: 640, height: 480 }),
  };
  const rect = SQ.contentRect(canvas);
  assert.deepEqual(rect, { left: 10, top: 20, width: 640, height: 480 });
});

test('contentRect letterboxes top/bottom when the box is wider than the content', () => {
  const SQ = ScreenQuad();
  // content is 1:1 (square), box is 2:1 (wide) -> pillarboxed sides, full height used
  const canvas = {
    width: 100, height: 100,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 100 }),
  };
  const rect = SQ.contentRect(canvas);
  assert.equal(rect.height, 100);
  assert.equal(rect.width, 100);
  assert.equal(rect.left, 50);
  assert.equal(rect.top, 0);
});

test('mapClientPointFromContain maps through pillarbox gutters (Cupra-like)', () => {
  const SQ = ScreenQuad();
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 255.3, height: 100 }),
  };
  const size = { width: 800, height: 480 };
  const content = SQ.contentRect(canvas);
  const clientX = content.left + (160 / 800) * content.width;
  const clientY = content.top + (140 / 480) * content.height;
  const point = SQ.mapClientPointFromContain(canvas, clientX, clientY, size);
  assert.ok(Math.abs(point.x - 160) < 0.5, `x: ${point.x} vs 160`);
  assert.ok(Math.abs(point.y - 140) < 0.5, `y: ${point.y} vs 140`);
  assert.equal(point.inside, true);
});

test('mapClientPointFromContain maps like the full box when aspects match', () => {
  const SQ = ScreenQuad();
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 10, top: 20, width: 800, height: 480 }),
  };
  const size = { width: 800, height: 480 };
  const point = SQ.mapClientPointFromContain(canvas, 410, 260, size);
  assert.ok(Math.abs(point.x - 400) < 0.5, `x: ${point.x} vs 400`);
  assert.ok(Math.abs(point.y - 240) < 0.5, `y: ${point.y} vs 240`);
  assert.equal(point.inside, true);
});

test('mapClientPointFromContain reports gutter clicks as outside', () => {
  const SQ = ScreenQuad();
  const canvas = {
    width: 800, height: 480,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 255.3, height: 100 }),
  };
  const size = { width: 800, height: 480 };
  const content = SQ.contentRect(canvas);
  const point = SQ.mapClientPointFromContain(canvas, content.left - 1, content.top + 50, size);
  assert.equal(point.inside, false);
});
