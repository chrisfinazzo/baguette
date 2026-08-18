'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web', 'capture'
);

function modules() {
  const window = loadBrowserModules([
    path.join(WEB, 'capture-size.js'),
    path.join(WEB, 'capture-composer.js'),
  ]);
  return {
    CaptureSize: window.Baguette._CaptureSize,
    CaptureComposer: window.Baguette._CaptureComposer,
  };
}

// A canvas 2D context stand-in that tracks the current transform and
// records every paint in FINAL canvas pixels — the same state a real
// canvas would end up in, just readable.
function fakeCtx() {
  const ops = [];
  let m = { x: 0, y: 0, sx: 1, sy: 1 };
  const stack = [];
  return {
    ops,
    canvas: { width: 0, height: 0 },
    fillStyle: '',
    imageSmoothingEnabled: false,
    imageSmoothingQuality: '',
    save() { stack.push({ ...m }); },
    restore() { m = stack.pop() || m; },
    translate(x, y) { m.x += x * m.sx; m.y += y * m.sy; },
    scale(sx, sy) { m.sx *= sx; m.sy *= sy; },
    clearRect(x, y, w, h) { ops.push(['clear', x, y, w, h]); },
    fillRect(x, y, w, h) {
      ops.push(['fill', this.fillStyle, m.x + x * m.sx, m.y + y * m.sy,
        w * m.sx, h * m.sy]);
    },
    drawImage(img, x, y, w, h) {
      ops.push(['draw', img.tag, m.x + x * m.sx, m.y + y * m.sy,
        w * m.sx, h * m.sy]);
    },
    beginPath() { ops.push(['beginPath']); },
    moveTo() {}, lineTo() {}, quadraticCurveTo() {}, closePath() {},
    clip() { ops.push(['clip']); },
    arc() {}, stroke() {},
  };
}

const source = (tag, width, height) => ({ tag, width, height });

// ── background ───────────────────────────────────────────────

test('fills the whole canvas with the background before drawing', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, '#ff0000', () => {});

  assert.deepEqual(ctx.ops[0], ['clear', 0, 0, 2000, 2000]);
  assert.deepEqual(ctx.ops[1], ['fill', '#ff0000', 0, 0, 2000, 2000]);
});

test('a transparent background clears without filling', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', () => {});

  assert.deepEqual(ctx.ops, [['clear', 0, 0, 2000, 2000]]);
});

// ── placement ────────────────────────────────────────────────

// The callback paints in SOURCE coordinates; compose maps them onto the
// target canvas so no caller has to redo the letterbox arithmetic.
test('maps a paint in source coordinates onto the letterboxed rect', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', (c) => {
    c.drawImage(source('screen', 1000, 2000), 0, 0, 1000, 2000);
  });

  assert.deepEqual(ctx.ops[1], ['draw', 'screen', 500, 0, 1000, 2000]);
});

test('scales the source paint up when the target is larger', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  // 1000x2000 source into a fixed 2000x4000 canvas → 2x.
  const plan = CaptureSize.parse('2000x4000').plan(1000, 2000, 'contain');

  CaptureComposer.compose(ctx, plan, 'transparent', (c) => {
    c.drawImage(source('screen', 1000, 2000), 100, 200, 400, 400);
  });

  assert.deepEqual(ctx.ops[1], ['draw', 'screen', 200, 400, 800, 800]);
});

test('restores the transform so a second compose is not compounded', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(1000, 2000, 'contain');
  const paint = (c) => c.drawImage(source('screen', 1000, 2000), 0, 0, 1000, 2000);

  CaptureComposer.compose(ctx, plan, 'transparent', paint);
  CaptureComposer.compose(ctx, plan, 'transparent', paint);

  assert.deepEqual(ctx.ops[1], ctx.ops[3]);
});

test('skips the source paint entirely when the plan is empty', () => {
  const { CaptureSize, CaptureComposer } = modules();
  const ctx = fakeCtx();
  const plan = CaptureSize.parse('square').plan(0, 0, 'contain');
  let painted = false;

  CaptureComposer.compose(ctx, plan, 'transparent', () => { painted = true; });

  assert.equal(painted, false);
});

// ── the bezel composite ──────────────────────────────────────

const SCREEN = {
  viewport: { width: 1400, height: 2900 },
  rect: { x: 55, y: 52, width: 1290, height: 2796 },
  clipRadius: 120,
};

test('reports the bezel viewport as the composite size when a frame is loaded', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 1400 }, SCREEN, { width: 1290, height: 2796 }),
    { width: 1400, height: 2900 }
  );
});

test('falls back to the source canvas size when there is no bezel', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize(null, SCREEN, { width: 1290, height: 2796 }),
    { width: 1290, height: 2796 }
  );
});

test('falls back to the source canvas when the bezel image has not decoded yet', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 0 }, SCREEN, { width: 1290, height: 2796 }),
    { width: 1290, height: 2796 }
  );
});

// DeviceKit composites paint an opaque dark "off glass" in the screen
// cutout, meant to sit UNDER live content — so the bezel goes down first
// and the screen lands on top, clipped to the inner corner radius.
test('paints the bezel first, then clips and paints the screen on top', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
  });

  assert.deepEqual(ctx.ops[0], ['draw', 'bezel', 0, 0, 1400, 2900]);
  assert.ok(ctx.ops.some((o) => o[0] === 'clip'), 'screen is clipped');
  assert.deepEqual(
    ctx.ops[ctx.ops.length - 1],
    ['draw', 'screen', 55, 52, 1290, 2796]
  );
});

test('paints the bare screen at the origin when there is no bezel', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: null,
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
  });

  assert.deepEqual(ctx.ops, [['draw', 'screen', 0, 0, 1290, 2796]]);
});

test('hands the screen rect to the overlay callback so dots land inside the clip', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();
  let handed = null;

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 1290, 2796),
    onOverlay: (c, rect) => { handed = rect; },
  });

  assert.deepEqual(handed, { x: 55, y: 52, width: 1290, height: 2796 });
});

// Pressing Record (or Screenshot) before the first frame has decoded is
// ordinary: the stream may still be negotiating. The device frame is
// already loaded and is worth painting on its own — an empty source
// should cost you the screen layer, not the whole composite.
test('still paints the bezel when the source canvas has not decoded yet', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
  });

  assert.deepEqual(ctx.ops, [['draw', 'bezel', 0, 0, 1400, 2900]]);
});

test('skips the overlay too when there is no screen content to sit on', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();
  let overlaid = false;

  CaptureComposer.paintComposite(ctx, {
    frameImg: { tag: 'bezel', naturalWidth: 1400 },
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
    onOverlay: () => { overlaid = true; },
  });

  assert.equal(overlaid, false);
});

test('paints nothing when there is neither a bezel nor a decoded source', () => {
  const { CaptureComposer } = modules();
  const ctx = fakeCtx();

  CaptureComposer.paintComposite(ctx, {
    frameImg: null,
    screen: SCREEN,
    sourceCanvas: source('screen', 0, 0),
  });

  assert.deepEqual(ctx.ops, []);
});

// compositeSize already falls back to the bezel viewport, so a capture
// started before the first frame is full-size rather than 0x0.
test('sizes the composite from the bezel even with an undecoded source', () => {
  const { CaptureComposer } = modules();
  assert.deepEqual(
    CaptureComposer.compositeSize({ naturalWidth: 1400 }, SCREEN, { width: 0, height: 0 }),
    { width: 1400, height: 2900 }
  );
});
