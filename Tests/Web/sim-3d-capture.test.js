'use strict';

// Sim3DPanel's capture path: the JSON body it POSTs to
// `/simulators/:udid/render-3d.png` when the user saves a frame, and the
// PNG header read it does to name the file after the real dimensions.
//
// The panel itself (canvas, pointer orbiting, stream lifecycle) stays
// integration-only — same bar as sim-native.js. These two statics are the
// part with arithmetic in it, so they get covered.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModules } = require('./helpers/load-browser-module.js');

const WEB = path.join(__dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web');

function load() {
  return loadBrowserModules([
    path.join(WEB, 'capture', 'capture-size.js'),
    path.join(WEB, 'capture', 'capture-settings.js'),
    path.join(WEB, 'sim-3d.js'),
  ]);
}

function panelAndSettings(opts) {
  const window = load();
  return {
    Sim3DPanel: window.Sim3DPanel,
    settings: new window.Baguette._CaptureSettings(opts),
  };
}

const POSE = { rotation: { x: -8, y: 18, z: 0 }, variants: { finish: 'space-black' } };

// ── the render request ───────────────────────────────────────

test('carries the pose, variants and glass choice verbatim', () => {
  const { Sim3DPanel } = panelAndSettings();
  const body = Sim3DPanel.renderBody({ ...POSE, screenGlass: true });
  assert.deepEqual(body.rotation, { x: -8, y: 18, z: 0 });
  assert.deepEqual(body.variants, { finish: 'space-black' });
  assert.equal(body.screenGlass, true);
});

test('asks the server for exactly the App Store pixels, unclamped', () => {
  const { Sim3DPanel, settings } = panelAndSettings({ size: 'appstore-6.9' });
  const body = Sim3DPanel.renderBody({
    ...POSE, settings, streamSize: { width: 960, height: 960 },
  });
  // The live stream is clamped to 480–1600 px; the one-shot render is not.
  assert.deepEqual(body.size, { width: 1290, height: 2796 });
});

test('every fixed preset goes out at its own catalogue size', () => {
  const window = load();
  const CaptureSettings = window.Baguette._CaptureSettings;
  const sizes = ['appstore-6.9', 'appstore-6.5', 'appstore-ipad-13', '1920x1080'].map(
      (spec) => window.Sim3DPanel.renderBody({
        ...POSE,
        settings: new CaptureSettings({ size: spec }),
        streamSize: { width: 960, height: 960 },
      }).size
  );
  assert.deepEqual(sizes, [
    { width: 1290, height: 2796 },
    { width: 1242, height: 2688 },
    { width: 2064, height: 2752 },
    { width: 1920, height: 1080 },
  ]);
});

test('a native capture omits size so the server renders at its own size', () => {
  const { Sim3DPanel, settings } = panelAndSettings({ size: 'native' });
  const body = Sim3DPanel.renderBody({
    ...POSE, settings, streamSize: { width: 960, height: 720 },
  });
  assert.equal('size' in body, false);
});

test('a ratio preset resolves against the live stream frame', () => {
  const { Sim3DPanel, settings } = panelAndSettings({ size: '16:9' });
  const body = Sim3DPanel.renderBody({
    ...POSE, settings, streamSize: { width: 960, height: 720 },
  });
  // 16:9 never downscales — the taller axis binds and the width grows.
  assert.deepEqual(body.size, { width: 1280, height: 720 });
});

test('a ratio preset with no known stream size falls back to the native render', () => {
  const { Sim3DPanel, settings } = panelAndSettings({ size: 'square' });
  const body = Sim3DPanel.renderBody({ ...POSE, settings });
  assert.equal('size' in body, false);
});

test('the letterbox background comes from the chosen settings', () => {
  const { Sim3DPanel, settings } = panelAndSettings({
    size: 'appstore-6.9', background: '#101820',
  });
  const body = Sim3DPanel.renderBody({
    ...POSE, settings, streamSize: { width: 960, height: 960 },
  });
  assert.equal(body.background, '#101820');
});

test('the screen keeps the live view\u2019s cover placement whatever fit is picked', () => {
  const window = load();
  const CaptureSettings = window.Baguette._CaptureSettings;
  // `fit` on this route places the captured frame on the device's screen
  // surface, not the render inside the canvas — so the user's canvas-fit
  // choice must not reach it, or the app screenshot would letterbox
  // inside the phone display.
  const fits = ['contain', 'cover', 'stretch'].map((fit) => window.Sim3DPanel.renderBody({
    ...POSE,
    settings: new CaptureSettings({ size: 'appstore-6.9', fit }),
    streamSize: { width: 960, height: 960 },
  }).fit);
  assert.deepEqual(fits, ['cover', 'cover', 'cover']);
});

test('a native capture stays transparent so the PNG gains no white mat', () => {
  const { Sim3DPanel, settings } = panelAndSettings({ background: '#ffffff' });
  const body = Sim3DPanel.renderBody({
    ...POSE, settings, streamSize: { width: 960, height: 960 },
  });
  assert.equal(body.background, 'transparent');
});

test('without capture settings the render matches the live stream framing', () => {
  const { Sim3DPanel } = panelAndSettings();
  const body = Sim3DPanel.renderBody({ ...POSE, background: '#f1f3f6' });
  assert.equal('size' in body, false);
  assert.equal(body.fit, 'cover');
  assert.equal(body.background, '#f1f3f6');
});

test('an absent pose renders the model square-on rather than failing', () => {
  const { Sim3DPanel } = panelAndSettings();
  const body = Sim3DPanel.renderBody({});
  assert.deepEqual(body.rotation, { x: 0, y: 0, z: 0 });
  assert.deepEqual(body.variants, {});
  assert.equal(body.screenGlass, false);
  assert.equal(body.background, 'transparent');
});

test('the body does not alias the panel state it was built from', () => {
  const { Sim3DPanel } = panelAndSettings();
  const variants = { finish: 'space-black' };
  const body = Sim3DPanel.renderBody({ ...POSE, variants });
  variants.finish = 'silver';
  assert.deepEqual(body.variants, { finish: 'space-black' });
});

// ── naming the file after what actually came back ────────────

function pngBytes(width, height) {
  const bytes = new Uint8Array(24);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  new DataView(bytes.buffer).setUint32(16, width);
  new DataView(bytes.buffer).setUint32(20, height);
  return bytes;
}

test('reads the rendered size out of the PNG header', () => {
  const { Sim3DPanel } = panelAndSettings();
  assert.deepEqual(Sim3DPanel.pngSize(pngBytes(1290, 2796)), {
    width: 1290, height: 2796,
  });
});

test('reports no size for bytes that are not a PNG', () => {
  const { Sim3DPanel } = panelAndSettings();
  assert.equal(Sim3DPanel.pngSize(new Uint8Array(24)), null);
  assert.equal(Sim3DPanel.pngSize(pngBytes(1, 1).slice(0, 16)), null);
  assert.equal(Sim3DPanel.pngSize(null), null);
});

// ── saving a frame end to end ────────────────────────────────
//
// The panel's DOM is integration-only, but saving is now a wire call with
// a fallback behind it, and "the user always ends up with a file" is the
// promise worth pinning. A fake document is enough to drive it.

// `document`, `fetch` and `URL` are bare globals inside sim-3d.js (it is a
// browser file, not a module), so the fakes have to be real Node globals
// rather than properties of the throwaway `window`. Every test restores
// them so the stubs don't leak into the rest of the process.
function fakePanel(respond) {
  const anchors = [];
  const requests = [];
  const saved = { document: global.document, fetch: global.fetch, URL: global.URL };
  global.document = {
    createElement() {
      return { href: '', download: '', click() { anchors.push(this); } };
    },
  };
  global.URL = {
    createObjectURL: (blob) => 'blob:' + blob.id,
    revokeObjectURL() {},
  };
  global.fetch = (url, init) => {
    requests.push({ url, init, body: JSON.parse(init.body) });
    return respond();
  };
  const restore = () => Object.assign(global, saved);

  const window = loadBrowserModules([
    path.join(WEB, 'capture', 'capture-size.js'),
    path.join(WEB, 'capture', 'capture-settings.js'),
    path.join(WEB, 'sim-3d.js'),
  ]);
  const panel = new window.Sim3DPanel();
  panel.udid = 'BC3E-138D';
  panel.model = { id: 'iphone-17-pro-max' };
  panel.canvas = {
    width: 960,
    height: 960,
    hasAttribute: () => true,
    toDataURL: () => 'data:image/png;base64,LIVE',
  };
  return { window, panel, anchors, requests, restore };
}

function pngResponse(width, height) {
  return async () => ({
    ok: true,
    blob: async () => ({
      id: 'render',
      arrayBuffer: async () => pngBytes(width, height).buffer,
    }),
  });
}

test('saving posts the pose to render-3d.png and files it under its real size', async (t) => {
  const { window, panel, anchors, requests, restore } = fakePanel(pngResponse(1290, 2796));
  t.after(restore);
  panel.setCaptureSettings(new window.Baguette._CaptureSettings({ size: 'appstore-6.9' }));
  await panel.download();

  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/simulators/BC3E-138D/render-3d.png');
  assert.equal(requests[0].init.method, 'POST');
  assert.deepEqual(requests[0].body.size, { width: 1290, height: 2796 });
  assert.equal(anchors.length, 1);
  assert.equal(anchors[0].href, 'blob:render');
  assert.equal(anchors[0].download, 'iphone-17-pro-max-3d-appstore-6.9-1290x2796.png');
});

test('a ratio spec never puts a colon in the saved filename', async (t) => {
  const { window, panel, anchors, restore } = fakePanel(pngResponse(1600, 900));
  t.after(restore);
  panel.setCaptureSettings(new window.Baguette._CaptureSettings({ size: '16:9' }));
  await panel.download();
  assert.equal(anchors[0].download, 'iphone-17-pro-max-3d-16-9-1600x900.png');
});

test('a failed render still saves the live frame rather than nothing', async (t) => {
  const { panel, anchors, restore } = fakePanel(async () => ({ ok: false, status: 404 }));
  t.after(restore);
  await panel.download();
  assert.equal(anchors.length, 1);
  assert.equal(anchors[0].href, 'data:image/png;base64,LIVE');
  assert.equal(anchors[0].download, 'iphone-17-pro-max-live-3d.png');
});

test('a settings object that cannot plan still leaves the user with a file', async (t) => {
  const { panel, anchors, restore } = fakePanel(pngResponse(1290, 2796));
  t.after(restore);
  panel.setCaptureSettings({ size: 'appstore-6.9' });  // not a CaptureSettings
  await panel.download();
  assert.equal(anchors[0].href, 'data:image/png;base64,LIVE');
});

test('a second click while a render is in flight is ignored', async (t) => {
  const { panel, requests, restore } = fakePanel(pngResponse(1290, 2796));
  t.after(restore);
  await Promise.all([panel.download(), panel.download()]);
  assert.equal(requests.length, 1);
});
