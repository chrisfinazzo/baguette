'use strict';

// The focus-mode template's <style> blocks carry the whole layout, and a
// CSS parse error in them is silent: the browser skips to the next thing
// it recognises, taking whatever rules were in between with it. That is
// not theoretical — an unterminated comment twice swallowed the block
// defining `--nv-device-max-*`, and the only symptom was the device
// rendering at its natural size with no cap, which looks like a sizing
// bug rather than a syntax one.
//
// So: two checks over the file's own text. Nothing here understands CSS
// — they catch the shapes that actually broke it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const TEMPLATE = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'sim-native.html'
);

/** The concatenated contents of every `<style>` block in an HTML file. */
function styleBlocks(html) {
  return [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)]
    .map((m) => m[1]).join('\n');
}

/**
 * Comment delimiters, in order, with the line each sits on. A `*​/` with
 * no open comment before it means the prose above it is being fed to the
 * CSS parser as if it were a rule.
 */
function unbalancedCommentLine(css) {
  const lines = css.split('\n');
  let open = false;
  for (let i = 0; i < lines.length; i++) {
    for (const token of lines[i].match(/\/\*|\*\//g) || []) {
      if (token === '/*') {
        if (open) return i + 1;   // nested open — CSS comments don't nest
        open = true;
      } else {
        if (!open) return i + 1;  // close with nothing open
        open = false;
      }
    }
  }
  return open ? lines.length : 0;
}

/**
 * Custom properties, split by whether the stylesheet can stand on its own
 * for them.
 *
 * `used` counts only `--nv-*` read WITHOUT a fallback, which is the shape
 * that fails loudly in layout and silently in the console. A `var(--x,
 * something)` is a deliberate optional hook, and a non-`--nv-` name may
 * be set inline from JS (`sim-3d.js` writes `--swatch` on each element) —
 * neither can be judged from this file alone.
 */
function customProperties(css) {
  const used = new Set(
    [...css.matchAll(/var\(\s*(--nv-[\w-]+)\s*\)/g)].map((m) => m[1])
  );
  const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1]));
  return { used, defined };
}

test('every CSS comment in sim-native.html is closed', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  assert.equal(
    unbalancedCommentLine(css), 0,
    'unbalanced /* */ — everything from here to the next recognisable ' +
    'rule is being parsed as CSS and silently dropped'
  );
});

test('unbalancedCommentLine finds a comment closed twice', () => {
  // The exact shape that broke it: prose left outside the comment after
  // an early `*/`, with a stray `*/` of its own at the end.
  const broken = [
    '/* explanation',
    '   more explanation */',
    '   prose that is no longer inside the comment */',
    '#root { --x: 1px; }',
  ].join('\n');
  assert.equal(unbalancedCommentLine(broken), 3);
});

test('unbalancedCommentLine finds a comment never closed', () => {
  assert.equal(unbalancedCommentLine('/* opened\nand never closed\n'), 3);
});

test('every --nv-* read without a fallback is defined in the same stylesheet', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  const { used, defined } = customProperties(css);
  const missing = [...used].filter((name) => !defined.has(name));
  assert.deepEqual(
    missing, [],
    'var() with no definition resolves to nothing and the whole ' +
    'declaration is dropped — the usual cause is a rule block lost to a ' +
    'parse error above it'
  );
});

test('the size budget defines every variable the device and panes size from', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  const { defined } = customProperties(css);
  for (const name of [
    '--nv-vh',
    '--nv-device-max-w', '--nv-device-max-h',
    '--nv-companion-max-w', '--nv-companion-max-h',
  ]) {
    assert.ok(defined.has(name), `${name} is not defined anywhere`);
  }
});

// The two checks below are about *where* focus-mode styling lives, not
// whether it parses. A panel that ships its own stylesheet is styling
// itself against a token set it can't see, so it drifts — different
// radii, a shadow that never learned about dark mode, an accent pulled
// from whatever `--accent` happens to mean on the page it landed on.
// The rest of the focus chrome (logs, status bar, location, the a11y
// inspector) contributes zero CSS and is styled here; these keep it that
// way.

/** Panel modules that render into `#simNativeView` and must not carry CSS. */
const PANEL_MODULES = ['sim-plugins.js', 'sim-screens.js'];

test('panel modules inject no stylesheet of their own', () => {
  for (const name of PANEL_MODULES) {
    const src = fs.readFileSync(path.join(path.dirname(TEMPLATE), name), 'utf8');
    assert.ok(
      !/createElement\(\s*['"]style['"]\s*\)/.test(src),
      `${name} builds a <style> element — focus-mode CSS belongs in ` +
      'sim-native.html under #simNativeView, where the --nv-* tokens are'
    );
  }
});

test('the focus-mode stylesheet reads no token from outside the --nv-* set', () => {
  const css = styleBlocks(fs.readFileSync(TEMPLATE, 'utf8'));
  // `--bg` / `--text` are the standalone-preview :root in <head>, which
  // only applies under file://; `--swatch` is written per-element from
  // sim-3d.js. Everything else must come from the theme block, because
  // only those names are redefined for light and dark.
  const allowed = new Set(['--bg', '--text', '--swatch']);
  const foreign = [...new Set(
    [...css.matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1])
  )].filter((name) => !name.startsWith('--nv-') && !allowed.has(name));
  assert.deepEqual(
    foreign, [],
    'these resolve against sim.html\'s light-only :root, so they never ' +
    'change for dark mode — use the --nv-* equivalent'
  );
});
