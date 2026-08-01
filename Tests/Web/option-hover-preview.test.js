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

// OptionHoverPreview registers window-level keydown/keyup/blur listeners
// (bare `window` inside the module resolves to whatever object the test
// loader used as its window parameter), so the fake "window" must be
// fireable too — a second FakeElement plays that role.
function build(screenSize = { width: 390, height: 844 }) {
  const fakeWindow = new FakeElement();
  const bag = loadBrowserModules([
    path.join(GESTURES_DIR, 'attachable-event-source.js'),
    path.join(GESTURES_DIR, 'option-hover-preview.js'),
  ], fakeWindow);
  return { OptionHoverPreview: bag.Baguette._OptionHoverPreview, fakeWindow };
}

test('hovering with Option held shows the cursor mirrored through the screen center', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));

  assert.equal(overlay.calls.setFingers.length, 1);
  const [f1, f2] = overlay.calls.setFingers[0];
  assert.equal(f1.x, 100);
  assert.equal(f1.y, 200);
  assert.equal(f2.x, 390 - 100);
  assert.equal(f2.y, 844 - 200);
});

test('hovering with Option+Shift held shows a parallel pair straddling the center', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Shift' }));

  const [f1, f2] = overlay.calls.setFingers.at(-1);
  assert.equal(f1.y, f2.y, 'parallel pair sits on a horizontal line');
  assert.ok(f1.x !== f2.x);
});

test('releasing Option clears the overlay', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeKeyup = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.clear, clearsBeforeKeyup);

  fakeWindow.fire('keyup', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.clear, clearsBeforeKeyup + 1);
});

test('moving the mouse without Option held never touches the overlay', () => {
  const { OptionHoverPreview } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  el.fire('mousemove', fakeEvent({ clientX: 110, clientY: 210 }));

  assert.equal(overlay.calls.setFingers.length, 0);
  assert.equal(overlay.calls.clear, 2, 'both mouseenter and mousemove clear the stale preview since Option is never held');
});

test('setDragActive(true) suppresses preview updates; setDragActive(false) resumes and refreshes', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  const before = overlay.calls.setFingers.length;

  preview.setDragActive(true);
  el.fire('mousemove', fakeEvent({ clientX: 150, clientY: 250 }));
  assert.equal(overlay.calls.setFingers.length, before, 'no preview repaint while a gesture is active');

  preview.setDragActive(false);
  assert.equal(overlay.calls.setFingers.length, before + 1, 'refreshes immediately once the gesture ends');
});

test('window blur while Option held releases the modifiers and clears the overlay', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeBlur = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  fakeWindow.fire('blur', fakeEvent());

  assert.equal(overlay.calls.clear, clearsBeforeBlur + 1);
  const setFingersBeforeMove = overlay.calls.setFingers.length;

  // Option no longer considered held — a later mousemove shows nothing new.
  el.fire('mousemove', fakeEvent({ clientX: 120, clientY: 220 }));
  assert.equal(overlay.calls.setFingers.length, setFingersBeforeMove);
});

test('the mouse leaving the element hides the preview', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  const clearsBeforeLeave = overlay.calls.clear; // mouseenter clears once, before Option is held
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.setFingers.length, 1);

  el.fire('mouseleave', fakeEvent());
  assert.equal(overlay.calls.clear, clearsBeforeLeave + 1);
});

test('detach stops the source from reacting to further input', () => {
  const { OptionHoverPreview, fakeWindow } = build();
  const screen = fakeScreen({ width: 390, height: 844 });
  const overlay = fakeOverlay();
  const el = new FakeElement({ left: 0, top: 0, width: 390, height: 844 });
  const preview = new OptionHoverPreview(screen, { overlay });
  preview.attach(el);
  preview.detach();

  el.fire('mouseenter', fakeEvent({ clientX: 100, clientY: 200 }));
  fakeWindow.fire('keydown', fakeEvent({ key: 'Alt' }));
  assert.equal(overlay.calls.setFingers.length, 0);
});
