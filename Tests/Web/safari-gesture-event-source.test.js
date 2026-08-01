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

function SafariGestureEventSource() {
  return loadBrowserModules([
    path.join(GESTURES_DIR, 'attachable-event-source.js'),
    path.join(GESTURES_DIR, 'safari-gesture-event-source.js'),
  ]).Baguette._SafariGestureEventSource;
}

test('gesturestart opens a 2-finger stream straddling the touch centroid', () => {
  const SGES = SafariGestureEventSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));

  assert.equal(screen.calls.touchDown.length, 1);
  const [f1, f2] = screen.calls.touchDown[0].fingers;
  const midX = (f1.x + f2.x) / 2, midY = (f1.y + f2.y) / 2;
  assert.ok(Math.abs(midX - 200) < 1e-6);
  assert.ok(Math.abs(midY - 400) < 1e-6);
});

test('gesturechange scales and rotates the synthesized fingers around the current centroid', () => {
  const SGES = SafariGestureEventSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  el.fire('gesturechange', fakeEvent({ clientX: 200, clientY: 400, scale: 2, rotation: 90 }));

  const [f1, f2] = screen.calls.touchMove.at(-1).fingers;
  const spread = Math.hypot(f1.x - f2.x, f1.y - f2.y);
  // A 90° rotation swings the pair from horizontal onto (near) vertical.
  assert.ok(spread > 300, `expected the doubled-scale spread to exceed 300pt, got ${spread}`);
  assert.ok(Math.abs(f1.x - f2.x) < 1, 'a 90° rotation leaves almost no horizontal separation');
});

test('gestureend closes the stream and clears the overlay', () => {
  const SGES = SafariGestureEventSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen, { overlay });
  source.attach(el);

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  el.fire('gestureend', fakeEvent({ clientX: 200, clientY: 400, scale: 1, rotation: 0 }));

  assert.equal(screen.calls.touchUp.length, 1);
  assert.equal(overlay.calls.clear, 1);
});

test('gesturechange/gestureend before any gesturestart are no-ops', () => {
  const SGES = SafariGestureEventSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);

  el.fire('gesturechange', fakeEvent({ clientX: 1, clientY: 1, scale: 1, rotation: 0 }));
  el.fire('gestureend', fakeEvent({ clientX: 1, clientY: 1, scale: 1, rotation: 0 }));

  assert.equal(screen.calls.touchMove.length, 0);
  assert.equal(screen.calls.touchUp.length, 0);
});

test('detach stops the source from opening new streams', () => {
  const SGES = SafariGestureEventSource();
  const screen = fakeScreen({ width: 390, height: 844 });
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const source = new SGES(screen);
  source.attach(el);
  source.detach();

  el.fire('gesturestart', fakeEvent({ clientX: 200, clientY: 400 }));
  assert.equal(screen.calls.touchDown.length, 0);
});
