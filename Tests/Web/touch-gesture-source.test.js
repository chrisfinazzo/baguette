'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');
const { FakeElement, fakeEvent, fakeScreen, fakeOverlay } = require('./helpers/fake-dom.js');

const GESTURES_DIR = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'baguette', 'gestures'
);

function TouchGestureSource() {
  return loadBrowserModules([
    path.join(GESTURES_DIR, 'attachable-event-source.js'),
    path.join(GESTURES_DIR, 'edge-bands.js'),
    path.join(GESTURES_DIR, 'touch-gesture-source.js'),
  ]).Baguette._TouchGestureSource;
}

function touch(clientX, clientY, identifier = 0) {
  return { clientX, clientY, identifier };
}

function closeTo(actual, expected, tolerance = 1e-6) {
  return Math.abs(actual - expected) < tolerance;
}

function assertPoint(finger, x, y) {
  assert.ok(closeTo(finger.x, x), `x: ${finger.x} vs ${x}`);
  assert.ok(closeTo(finger.y, y), `y: ${finger.y} vs ${y}`);
}

test('a single finger streams touchDown/touchMove/touchUp in device-point space', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen);
  source.attach(el);

  el.fire('touchstart', fakeEvent({ touches: [touch(100, 200)] }));
  assert.equal(screen.calls.touchDown.length, 1);
  assertPoint(screen.calls.touchDown[0].fingers[0], 100, 200);
  assert.equal(screen.calls.touchDown[0].opts, undefined);

  el.fire('touchmove', fakeEvent({ touches: [touch(120, 220)] }));
  assert.equal(screen.calls.touchMove.length, 1);
  assertPoint(screen.calls.touchMove[0].fingers[0], 120, 220);

  el.fire('touchend', fakeEvent({ changedTouches: [touch(120, 220)] }));
  assert.equal(screen.calls.touchUp.length, 1);
  assertPoint(screen.calls.touchUp[0].fingers[0], 120, 220);
});

test('a touch landing in the bottom edge band tags every envelope with edge:"bottom"', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen);
  source.attach(el);

  // yNorm = 800/844 ≈ 0.948 — well inside the touch bottom band (0.85).
  el.fire('touchstart', fakeEvent({ touches: [touch(195, 800)] }));
  assert.equal(screen.calls.touchDown[0].opts.edge, 'bottom');

  el.fire('touchmove', fakeEvent({ touches: [touch(195, 810)] }));
  assert.equal(screen.calls.touchMove[0].opts.edge, 'bottom');

  el.fire('touchend', fakeEvent({ changedTouches: [touch(195, 810)] }));
  assert.equal(screen.calls.touchUp[0].opts.edge, 'bottom');
});

test('a touch outside the interactive surface (3D bezel/background) starts nothing', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen, { mapClientPoint: () => ({ x: 0, y: 0, xNorm: 0, yNorm: 0, inside: false }) });
  source.attach(el);

  el.fire('touchstart', fakeEvent({ touches: [touch(50, 50)] }));
  assert.equal(screen.calls.touchDown.length, 0);

  // No state was ever armed, so a stray end/move is a no-op too.
  el.fire('touchmove', fakeEvent({ touches: [touch(60, 60)] }));
  el.fire('touchend', fakeEvent({ changedTouches: [touch(60, 60)] }));
  assert.equal(screen.calls.touchMove.length, 0);
  assert.equal(screen.calls.touchUp.length, 0);
});

test('a second finger landing defers to Safari GestureEvent instead of dispatching touch2', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen, { overlay });
  source.attach(el);

  el.fire('touchstart', fakeEvent({ touches: [touch(10, 10, 0), touch(20, 20, 1)] }));

  assert.equal(screen.calls.touchDown.length, 0, 'no touch1/touch2 envelope — gesturestart owns this');
  assert.equal(overlay.calls.setFingers.length, 1, 'HUD still paints both real fingertips');
});

test('a second finger arriving mid-single-touch-stream closes the touch1 stream cleanly', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen, { overlay });
  source.attach(el);

  el.fire('touchstart', fakeEvent({ touches: [touch(100, 200, 0)] }));
  assert.equal(screen.calls.touchDown.length, 1);

  el.fire('touchmove', fakeEvent({ touches: [touch(100, 200, 0), touch(150, 250, 1)] }));
  assert.equal(screen.calls.touchUp.length, 1, 'the single-touch stream is closed before deferring');

  // Now deferred — further move/end dispatch nothing more from this source.
  el.fire('touchend', fakeEvent({ changedTouches: [touch(150, 250, 1)] }));
  assert.equal(screen.calls.touchUp.length, 1);
});

test('detach removes every listener so a torn-down source stays silent', () => {
  const TGS = TouchGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new TGS(screen);
  source.attach(el);
  source.detach();

  el.fire('touchstart', fakeEvent({ touches: [touch(100, 200)] }));
  assert.equal(screen.calls.touchDown.length, 0);
});
