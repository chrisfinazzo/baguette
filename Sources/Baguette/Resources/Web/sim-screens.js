// sim-screens.js — the companion-screens rail in focus mode.
//
// A simulator can drive more than its own glass: a CarPlay external
// display, and the Apple Watch paired with it. Both used to be a
// standing decision the page made for you — the CarPlay pane was always
// mounted, which also meant every page load reached into Simulator.app
// and attached a CarPlay display whether you wanted one or not.
//
// This rail makes it a choice. It asks the host what is actually there
// (`/simulators/<udid>/companion-screens.json`), offers what it can
// show, and for what it can't, says how to get one — a device with no
// CarPlay display and no paired watch is the common case, so "nothing
// here" has to be a useful answer rather than an empty rail.
//
// The rail owns the buttons, the state card and the remembered choice.
// It does not own the streams: opening a pane calls back into
// sim-native.js, which owns every StreamSession on the page.
//
// Wire:
//   GET  /simulators/<udid>/companion-screens.json  → what's attached
//   POST /simulators/<udid>/boot                    → boot a paired watch
(function (root) {
  'use strict';

  const STORAGE_KEY = 'baguette.companionScreens';

  // Host-owned glyphs, one per companion screen. Keyed by the same ids
  // `CompanionScreens` uses so a new kind lands in one place at each end.
  const GLYPHS = {
    carplay:
      '<path d="M4 16.5h16M5.5 16.5v2M18.5 16.5v2"/>' +
      '<path d="M4.6 16.5 6.2 9.9A2 2 0 0 1 8.1 8.4h7.8a2 2 0 0 1 1.9 1.5l1.6 6.6"/>' +
      '<path d="M6.4 13.2h11.2"/>',
    watch:
      '<rect x="7" y="6.5" width="10" height="11" rx="3"/>' +
      '<path d="M9 6.5 9.4 3.2h5.2l.4 3.3M9 17.5l.4 3.3h5.2l.4-3.3"/>',
  };

  const RAIL_CAP =
    '<rect x="2.5" y="5" width="12" height="9" rx="2"/>' +
    '<path d="M6 18h5"/>' +
    '<rect x="16" y="10" width="5.5" height="9" rx="1.8"/>';

  function svgWrap(inner, size) {
    const n = size || 17;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
         + 'stroke-linecap="round" stroke-linejoin="round" width="' + n + '" height="' + n
         + '" aria-hidden="true">' + inner + '</svg>';
  }

  class ScreensRail {
    /**
     * @param {object} opts
     * @param {string} opts.udid
     * @param {HTMLElement} [opts.mount]  where the rail + card attach
     * @param {(entry:object) => void} [opts.onOpen]   show this screen's pane
     * @param {(entry:object) => void} [opts.onClose]  hide it again
     * @param {(msg:string) => void} [opts.log]
     */
    constructor({ udid, mount, onOpen, onClose, log }) {
      this.udid = udid;
      this.mount = mount || document.body;
      this.onOpen = onOpen || (() => {});
      this.onClose = onClose || (() => {});
      this.log = log || (() => {});
      this.screens = null;
      this.open = new Set();
      this.rail = null;
      this.card = null;
      this.buttons = new Map();
      this.bootPollTimer = null;
    }

    /**
     * Ask the host what is attached and draw the rail.
     *
     * A server that doesn't answer isn't a reason to hide the rail: the
     * entries still know how to explain themselves, and an empty right
     * edge would leave no way to find out that CarPlay exists at all.
     */
    async load() {
      let payload = null;
      try {
        const res = await fetch(
          '/simulators/' + encodeURIComponent(this.udid) + '/companion-screens.json',
          { cache: 'no-store' }
        );
        if (res.ok) payload = await res.json();
      } catch (error) {
        this.log('companion screens unavailable: ' + ((error && error.message) || error));
      }
      this.screens = window.Baguette._CompanionScreens.from(payload);
      this.render();
      this.restoreRemembered();
    }

    /// Re-ask after the user has gone off and attached something. Panes
    /// that are open and still openable stay open; one whose screen went
    /// away closes rather than streaming a display that isn't there.
    async refresh() {
      const wasOpen = new Set(this.open);
      for (const id of wasOpen) this.closeScreen(id, { remember: false });
      await this.load();
      for (const id of wasOpen) {
        const entry = this.entry(id);
        if (entry && entry.canOpen) this.openScreen(id, { remember: false });
      }
    }

    entry(id) {
      return this.screens.entries().find((e) => e.id === id) || null;
    }

    render() {
      ScreensRail.injectCSS();
      if (this.rail) this.rail.remove();
      this.buttons.clear();

      const rail = document.createElement('aside');
      rail.className = 'screens-rail';
      rail.setAttribute('aria-label', 'Companion screens');

      const cap = document.createElement('div');
      cap.className = 'screens-rail-cap';
      cap.title = 'Companion screens';
      cap.innerHTML = svgWrap(RAIL_CAP, 16);
      rail.appendChild(cap);
      rail.appendChild(ScreensRail.divider());

      for (const entry of this.screens.entries()) {
        rail.appendChild(this.buildButton(entry));
      }

      rail.appendChild(ScreensRail.divider());
      const again = document.createElement('button');
      again.className = 'screens-rail-btn screens-rail-refresh';
      again.title = 'Check for screens again';
      again.setAttribute('aria-label', 'Check for companion screens again');
      again.innerHTML = svgWrap('<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>', 16);
      again.addEventListener('click', () => this.refresh());
      rail.appendChild(again);

      this.mount.appendChild(rail);
      this.rail = rail;
    }

    static divider() {
      const divider = document.createElement('div');
      divider.className = 'screens-rail-divider';
      return divider;
    }

    /**
     * One slot per screen — present whether or not the screen is.
     *
     * A screen that isn't attached keeps its button and dims it. The
     * click then opens the card explaining how to attach one, which is
     * the only place that instruction can live: a rail that hid what you
     * don't have could never tell you how to get it.
     */
    buildButton(entry) {
      const button = document.createElement('button');
      button.className = 'screens-rail-btn';
      if (!entry.canOpen) button.classList.add('unavailable');
      button.innerHTML = svgWrap(GLYPHS[entry.id] || GLYPHS.carplay, 18);
      button.title = entry.canOpen
        ? entry.label
        : entry.label + ' — ' + entry.detail;
      button.setAttribute('aria-label', button.title);
      button.setAttribute('aria-pressed', 'false');
      button.addEventListener('click', () => this.clicked(entry));
      this.buttons.set(entry.id, button);
      return button;
    }

    clicked(entry) {
      if (!entry.canOpen) {
        this.showCard(entry);
        return;
      }
      this.closeCard();
      if (this.open.has(entry.id)) this.closeScreen(entry.id);
      else this.openScreen(entry.id);
    }

    // --- panes ---------------------------------------------------------

    openScreen(id, { remember = true } = {}) {
      const entry = this.entry(id);
      if (!entry || !entry.canOpen || this.open.has(id)) return;
      this.open.add(id);
      this.reflect(id);
      if (remember) this.remember();
      this.onOpen(entry);
    }

    closeScreen(id, { remember = true } = {}) {
      if (!this.open.has(id)) return;
      this.open.delete(id);
      this.reflect(id);
      if (remember) this.remember();
      const entry = this.entry(id);
      if (entry) this.onClose(entry);
    }

    reflect(id) {
      const button = this.buttons.get(id);
      if (!button) return;
      const open = this.open.has(id);
      button.classList.toggle('active', open);
      button.setAttribute('aria-pressed', open ? 'true' : 'false');
    }

    // --- remembered choice ---------------------------------------------
    //
    // Which panes you had open is a preference, not a session detail —
    // reloading the tab after an app rebuild shouldn't cost you the
    // layout you set up. A remembered screen that is no longer attached
    // is simply skipped; nothing here can resurrect a pane whose screen
    // has gone.

    remember() {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify([...this.open]));
      } catch (_) { /* private mode / quota — the rail still works */ }
    }

    restoreRemembered() {
      let stored = [];
      try {
        stored = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
      } catch (_) { stored = []; }
      if (!Array.isArray(stored)) return;
      for (const id of stored) this.openScreen(id, { remember: false });
    }

    // --- the "not attached" card ----------------------------------------

    showCard(entry) {
      this.closeCard();
      const card = document.createElement('div');
      card.className = 'screens-card';
      card.setAttribute('role', 'dialog');
      card.setAttribute('aria-label', entry.label);

      const head = document.createElement('div');
      head.className = 'screens-card-head';
      const title = document.createElement('span');
      title.className = 'screens-card-title';
      title.textContent = entry.label;
      const close = document.createElement('button');
      close.className = 'screens-card-close';
      close.setAttribute('aria-label', 'Close');
      close.textContent = '✕';
      close.addEventListener('click', () => this.closeCard());
      head.appendChild(title);
      head.appendChild(close);
      card.appendChild(head);

      const body = document.createElement('div');
      body.className = 'screens-card-body';
      const status = document.createElement('p');
      status.className = 'screens-card-status';
      status.textContent = entry.detail;
      body.appendChild(status);

      if (entry.status === 'needs-boot') {
        body.appendChild(this.bootControls(entry));
      } else {
        const list = document.createElement('ol');
        list.className = 'screens-steps';
        for (const step of entry.instructions) {
          const item = document.createElement('li');
          item.textContent = step;   // host copy, but never markup
          list.appendChild(item);
        }
        body.appendChild(list);

        const again = document.createElement('button');
        again.className = 'screens-card-btn';
        again.textContent = 'Check again';
        again.addEventListener('click', () => { this.closeCard(); this.refresh(); });
        body.appendChild(again);
      }

      card.appendChild(body);
      this.mount.appendChild(card);
      this.card = card;
      this.positionCard(card, this.buttons.get(entry.id));
    }

    /// A paired watch that isn't running needs one button, not a page of
    /// prose — it is already the right device, it just isn't up yet.
    bootControls(entry) {
      const wrap = document.createElement('div');
      const note = document.createElement('p');
      note.className = 'screens-card-note';
      note.textContent =
        'This watch is paired with the phone but not running. Boot it to stream its screen.';
      wrap.appendChild(note);

      const button = document.createElement('button');
      button.className = 'screens-card-btn';
      button.textContent = 'Boot ' + entry.label;
      button.addEventListener('click', async () => {
        button.disabled = true;
        button.textContent = 'Booting…';
        try {
          await fetch('/simulators/' + encodeURIComponent(entry.udid) + '/boot',
            { method: 'POST' });
        } catch (_) { /* the poll below is the real answer */ }
        this.pollForBoot(entry.udid, note, button);
      });
      wrap.appendChild(button);
      return wrap;
    }

    /// CoreSimulator answers the boot before the guest is up, so watch
    /// the device list rather than trusting the POST's return.
    pollForBoot(udid, note, button, deadline) {
      const until = deadline || (Date.now() + 120000);
      this.bootPollTimer = setTimeout(async () => {
        this.bootPollTimer = null;
        let booted = false;
        try {
          const res = await fetch('/simulators.json', { cache: 'no-store' });
          const json = await res.json();
          const all = (json.running || []).concat(json.available || []);
          const hit = all.find((d) => (d.id || d.udid) === udid);
          booted = !!hit && hit.state === 'Booted';
        } catch (_) { /* keep waiting */ }
        if (booted) {
          this.closeCard();
          await this.refresh();
          this.openScreen('watch');
          return;
        }
        if (Date.now() >= until) {
          note.textContent = 'Still not booted. Try again, or boot it from the simulator list.';
          button.disabled = false;
          button.textContent = 'Boot again';
          return;
        }
        this.pollForBoot(udid, note, button, until);
      }, 1000);
    }

    /// Anchored to the left of its button, then kept on screen — a rail
    /// slot near the bottom of a short window would hang off the edge.
    positionCard(card, button) {
      if (!button || !this.rail) return;
      const rail = this.rail.getBoundingClientRect();
      const anchor = button.getBoundingClientRect();
      card.style.right = (window.innerWidth - rail.left + 8) + 'px';
      const height = card.offsetHeight;
      const centred = anchor.top + anchor.height / 2 - height / 2;
      card.style.top = Math.max(12, Math.min(centred, window.innerHeight - height - 12)) + 'px';
    }

    closeCard() {
      if (this.bootPollTimer) { clearTimeout(this.bootPollTimer); this.bootPollTimer = null; }
      if (this.card) this.card.remove();
      this.card = null;
    }

    detach() {
      this.closeCard();
      if (this.rail) this.rail.remove();
      this.rail = null;
      this.buttons.clear();
    }
  }

  // Host-owned styling, injected here so the module stays self-contained
  // — same arrangement as the plugin rail it sits above. The two rails
  // share a shape on purpose but not an accent: this one is baguette's
  // own, so it takes the page's text colour rather than the plugin
  // system's accent seam.
  const CSS = `
  .screens-rail { display: flex; flex-direction: column; align-items: center; gap: 6px;
                  padding: 8px 6px; z-index: 45;
                  background: var(--nv-bar-bg, rgba(255,255,255,0.92));
                  border: 1px solid var(--nv-bar-border, rgba(15,23,42,0.10));
                  border-radius: 14px;
                  box-shadow: var(--nv-bar-shadow, 0 8px 30px rgba(15,23,42,0.12));
                  backdrop-filter: blur(18px) saturate(1.5);
                  -webkit-backdrop-filter: blur(18px) saturate(1.5);
                  color: var(--nv-text, #1d1d1f); }
  .screens-rail-cap { display: inline-flex; align-items: center; justify-content: center;
                      width: 30px; height: 24px; color: var(--nv-text-muted, rgba(29,29,31,0.65));
                      opacity: 0.9; }
  .screens-rail-divider { width: 20px; height: 1px; margin: 1px 0 3px;
                          background: var(--nv-divider, rgba(15,23,42,0.14)); }
  .screens-rail-btn { position: relative; width: 34px; height: 34px; padding: 0; border: 0;
                      cursor: pointer;
                      display: inline-flex; align-items: center; justify-content: center;
                      background: transparent; border-radius: 9px;
                      color: var(--nv-text, #1d1d1f);
                      transition: background 0.12s ease, transform 0.12s ease, opacity 0.12s ease; }
  .screens-rail-btn:hover  { background: var(--nv-btn-hover, rgba(15,23,42,0.06)); }
  .screens-rail-btn:active { transform: scale(0.94); }
  .screens-rail-btn.active { background: var(--nv-accent, #2563eb);
                             color: var(--nv-accent-text, #fff); }
  /* Dimmed, not hidden: the button is how you find out the screen could
     exist, and how you reach the instructions for attaching one. */
  .screens-rail-btn.unavailable { opacity: 0.38; }
  .screens-rail-btn.unavailable:hover { opacity: 0.7; }
  .screens-rail-refresh { color: var(--nv-text-muted, rgba(29,29,31,0.65)); }

  .screens-card { position: fixed; z-index: 50; width: 268px;
                  background: var(--nv-bar-bg, rgba(255,255,255,0.96));
                  border: 1px solid var(--nv-bar-border, rgba(15,23,42,0.10));
                  border-radius: 13px;
                  box-shadow: 0 10px 34px rgba(15,23,42,0.20);
                  backdrop-filter: blur(18px) saturate(1.5);
                  -webkit-backdrop-filter: blur(18px) saturate(1.5);
                  color: var(--nv-text, #1d1d1f);
                  animation: screens-card-in 0.12s ease-out; }
  @keyframes screens-card-in { from { opacity: 0; transform: translateX(6px); }
                               to   { opacity: 1; transform: translateX(0); } }
  @media (prefers-reduced-motion: reduce) { .screens-card { animation: none; } }
  .screens-card-head { display: flex; align-items: center; gap: 8px; padding: 10px 12px;
                       border-bottom: 1px solid var(--nv-divider, rgba(15,23,42,0.10)); }
  .screens-card-title { font: 600 12px/1 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
                        letter-spacing: 0.02em; }
  .screens-card-close { margin-left: auto; border: 0; background: transparent; cursor: pointer;
                        font-size: 12px; padding: 2px 4px;
                        color: var(--nv-text-muted, rgba(29,29,31,0.65)); }
  .screens-card-body { padding: 11px 12px 13px; }
  .screens-card-status { margin: 0 0 8px;
                         font: 600 11px/1.35 -apple-system, sans-serif;
                         color: var(--nv-text-muted, rgba(29,29,31,0.65)); }
  .screens-card-note { margin: 0 0 10px;
                       font: 400 11.5px/1.45 -apple-system, sans-serif;
                       color: var(--nv-text-muted, rgba(29,29,31,0.65)); }
  .screens-steps { margin: 0 0 11px; padding-left: 17px;
                   display: flex; flex-direction: column; gap: 6px;
                   font: 400 11.5px/1.45 -apple-system, sans-serif;
                   color: var(--nv-text, #1d1d1f); }
  .screens-steps li { overflow-wrap: anywhere; }
  .screens-card-btn { width: 100%; padding: 8px 12px; border: 0; border-radius: 8px;
                      cursor: pointer; font: 600 12px/1 -apple-system, sans-serif;
                      color: var(--nv-accent-text, #fff); background: var(--nv-accent, #2563eb); }
  .screens-card-btn:disabled { opacity: 0.6; cursor: default; }

  @media (max-width: 560px) {
    .screens-card { width: auto; left: 12px; right: 12px; }
  }
  `;

  function injectCSS() {
    if (document.getElementById('screens-rail-css')) return;
    const style = document.createElement('style');
    style.id = 'screens-rail-css';
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  root.ScreensRail = ScreensRail;
  root.ScreensRail.injectCSS = injectCSS;
})(window);
