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

function WheelGestureSource() {
  return loadBrowserModules([
    path.join(GESTURES_DIR, 'attachable-event-source.js'),
    path.join(GESTURES_DIR, 'wheel-gesture-source.js'),
  ]).Baguette._WheelGestureSource;
}

function wheelEvent(overrides) {
  return fakeEvent({ deltaX: 0, deltaY: 0, ctrlKey: false, clientX: 200, clientY: 400, ...overrides });
}

test('a plain wheel opens a 2-finger pan stream centered on the cursor', () => {
  const WGS = WheelGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new WGS(screen);
  source.attach(el);

  el.fire('wheel', wheelEvent({ deltaX: 0, deltaY: 0 }));

  assert.equal(screen.calls.touchDown.length, 1);
  const [f1, f2] = screen.calls.touchDown[0].fingers;
  assert.equal(f1.y, f2.y, 'pan fingers start on a horizontal line through the cursor');
  assert.ok(f1.x > f2.x);
});

test('a ctrl+wheel opens a 2-finger pinch stream instead', () => {
  const WGS = WheelGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new WGS(screen);
  source.attach(el);

  el.fire('wheel', wheelEvent({ ctrlKey: true }));
  assert.equal(screen.calls.touchDown.length, 1);

  // Scrolling up (negative deltaY) grows the pinch spread.
  el.fire('wheel', wheelEvent({ ctrlKey: true, deltaY: -100 }));
  const lastMove = screen.calls.touchMove.at(-1);
  const spread = Math.abs(lastMove.fingers[0].x - lastMove.fingers[1].x);
  assert.ok(spread > 160, `expected spread to grow past the base 160pt, got ${spread}`);
});

test('switching kind mid-stream (pan -> pinch) closes the old stream before opening a new one', () => {
  const WGS = WheelGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new WGS(screen);
  source.attach(el);

  el.fire('wheel', wheelEvent({ ctrlKey: false }));
  assert.equal(screen.calls.touchDown.length, 1);
  assert.equal(screen.calls.touchUp.length, 0);

  el.fire('wheel', wheelEvent({ ctrlKey: true }));
  assert.equal(screen.calls.touchUp.length, 1, 'the pan stream was closed');
  assert.equal(screen.calls.touchDown.length, 2, 'a fresh pinch stream opened');
});

test('idle for WHEEL_IDLE_MS closes the stream and clears the overlay', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const WGS = WheelGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new WGS(screen, { overlay });
  source.attach(el);

  el.fire('wheel', wheelEvent({}));
  assert.equal(screen.calls.touchUp.length, 0);

  t.mock.timers.tick(120);
  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(overlay.calls.clear, 1);
});

test('detach stops the source from opening new streams', () => {
  const WGS = WheelGestureSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new WGS(screen);
  source.attach(el);
  source.detach();

  el.fire('wheel', wheelEvent({}));
  assert.equal(screen.calls.touchDown.length, 0);
});
