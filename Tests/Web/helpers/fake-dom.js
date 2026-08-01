'use strict';

/**
 * A minimal fake DOM element — just enough surface for the gesture-source
 * classes to `addEventListener`/`removeEventListener`/`getBoundingClientRect`
 * against, plus a `fire(type, event)` test hook to dispatch synthetic
 * events synchronously. No jsdom: these classes only ever touch this
 * narrow slice of the DOM API, so a hand-rolled fake is enough to drive
 * real behavioural tests — the same Chicago-school "fake object with
 * state" the Swift side uses (`Fake…` NSObject subclasses), not a mock
 * that only records calls.
 */
class FakeElement {
  constructor(rect = { left: 0, top: 0, width: 400, height: 800 }) {
    this._rect = rect;
    this._listeners = new Map();
  }

  addEventListener(type, fn) {
    if (!this._listeners.has(type)) this._listeners.set(type, new Set());
    this._listeners.get(type).add(fn);
  }

  removeEventListener(type, fn) {
    const set = this._listeners.get(type);
    if (set) set.delete(fn);
  }

  getBoundingClientRect() {
    return this._rect;
  }

  /** Synchronously invokes every listener registered for `type`. */
  fire(type, event) {
    for (const fn of this._listeners.get(type) || []) fn(event);
  }

  listenerCount(type) {
    return this._listeners.get(type)?.size || 0;
  }
}

/** A `preventDefault`-able synthetic event; spread `overrides` on top. */
function fakeEvent(overrides = {}) {
  return { preventDefault() {}, ...overrides };
}

/** Records every Screen verb call so tests can assert on the wire calls made. */
function fakeScreen(size = { width: 390, height: 844 }) {
  const calls = { touchDown: [], touchMove: [], touchUp: [], tap: [] };
  return {
    size,
    touchDown(fingers, opts) { calls.touchDown.push({ fingers, opts }); },
    touchMove(fingers, opts) { calls.touchMove.push({ fingers, opts }); },
    touchUp(fingers, opts) { calls.touchUp.push({ fingers, opts }); },
    tap(point, opts) { calls.tap.push({ point, opts }); },
    calls,
  };
}

/** Records every HUD call so tests can assert on overlay updates. */
function fakeOverlay() {
  const calls = { setFingers: [], clear: 0 };
  return {
    setFingers(fingers) { calls.setFingers.push(fingers); },
    clear() { calls.clear += 1; },
    calls,
  };
}

/**
 * Installs a minimal fake `document` as a real Node global — needed for
 * classes (like MouseGestureSource's tap ripple) that touch bare
 * `document.createElement`/`document.body`. Returns a `{ createdCount,
 * uninstall() }` handle; call `uninstall()` in a test's cleanup so the
 * stub doesn't leak into other test files sharing the same process.
 */
function installFakeDocument() {
  const previous = global.document;
  let createdCount = 0;
  global.document = {
    getElementById: () => null,
    createElement: () => {
      createdCount += 1;
      return { style: {}, remove() {} };
    },
    head: { appendChild() {} },
    body: { appendChild() {} },
  };
  return {
    get createdCount() { return createdCount; },
    uninstall() { global.document = previous; },
  };
}

module.exports = { FakeElement, fakeEvent, fakeScreen, fakeOverlay, installFakeDocument };
