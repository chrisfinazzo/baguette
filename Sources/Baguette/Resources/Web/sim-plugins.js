// sim-plugins.js — renders plugin contributions in focus mode.
//
// Plugins live in their OWN rail on the right edge, deliberately apart
// from the device toolbar. Baguette ships the toolbar; plugins are
// third-party code you installed. Keeping them physically separate is
// a trust signal, not decoration: you should always be able to tell
// "baguette did this" from "something I installed did this", and a
// plugin button must never be able to impersonate a core control.
//
// The host owns every pixel. A plugin ships a manifest describing what
// it wants (a titled panel, an icon from baguette's own set, a list
// fed by one of its commands); this file draws it with host markup.
// Nothing a plugin ships is ever loaded into this page — no plugin
// <script>, no plugin CSS, no plugin HTML. Every string from
// /plugins.json goes through escapeHTML or textContent.
//
// That constraint is what keeps the ~70 lines of Origin /
// Sec-Fetch-Site / DNS-rebind checks on the server meaningful: a
// same-origin plugin script would make all of it moot.
//
// Wire:
//   GET  /plugins.json                        → manifests
//   POST /plugins/<id>/commands/<cmd>?udid=   → {"ok",…,"rows":[…]}
(function (root) {
  'use strict';

  // Glyphs matching Domain/Plugin/PanelBody.swift's `PluginIcon`. A
  // manifest names one; it can never supply markup. Keep the two in
  // sync — an icon the host doesn't have is rejected at parse time, so
  // a missing case here means a plugin that validated can't render.
  const ICONS = {
    accessibility: '<circle cx="12" cy="4.5" r="1.8"/><path d="M4.5 8.5h15M12 8v6M12 14l-3.5 6M12 14l3.5 6"/>',
    reload:        '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v5h-5"/>',
    link:          '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 1 0-5.7-5.7L11.5 7"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3A4 4 0 1 0 11 18.7l1.5-1.5"/>',
    list:          '<line x1="8" y1="7" x2="20" y2="7"/><line x1="8" y1="12" x2="20" y2="12"/><line x1="8" y1="17" x2="20" y2="17"/><circle cx="4.5" cy="7" r="1"/><circle cx="4.5" cy="12" r="1"/><circle cx="4.5" cy="17" r="1"/>',
    bell:          '<path d="M18 8a6 6 0 1 0-12 0c0 6-2 7-2 7h16s-2-1-2-7"/><path d="M13.7 20a2 2 0 0 1-3.4 0"/>',
    wrench:        '<path d="M14.7 6.3a4 4 0 0 0 5 5l-9 9a2.8 2.8 0 1 1-4-4z"/>',
    lock:          '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    globe:         '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 3 2.5 15 0 18M12 3c-2.5 3-2.5 15 0 18"/>',
    camera:        '<rect x="3" y="6.5" width="13" height="11" rx="2"/><path d="M16 10.5 21 8v8l-5-2.5z"/>',
    clock:         '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>',
    document:      '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    play:          '<path d="M8 5.5v13l11-6.5z"/>',
  };

  // The rail's own emblem — a puzzle piece. Names the rail as "the
  // plugins system" so the group reads as distinct from the toolbar.
  const PUZZLE =
    '<path d="M10 4.5a2 2 0 0 1 4 0c0 .3-.1.6-.2.9.2-.1.5-.1.7-.1h1.5a1 1 0 0 1 1 1v1.5c0 .2 0 .5-.1.7.3-.1.6-.2.9-.2a2 2 0 0 1 0 4c-.3 0-.6-.1-.9-.2.1.2.1.5.1.7v2.5a1 1 0 0 1-1 1h-2.5c-.2 0-.5 0-.7-.1.1.3.2.6.2.9a2 2 0 0 1-4 0c0-.3.1-.6.2-.9-.2.1-.5.1-.7.1H6a1 1 0 0 1-1-1v-2.5c0-.2 0-.5.1-.7-.3.1-.6.2-.9.2a2 2 0 0 1 0-4c.3 0 .6.1.9.2C5 8.6 5 8.3 5 8.1V6.4a1 1 0 0 1 1-1h1.5c.2 0 .5 0 .7.1-.1-.3-.2-.6-.2-.9z"/>';

  const SEVERITY_COLOR = { error: '#b91c1c', warn: '#b45309', info: '#64748b' };

  function escapeHTML(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function svgWrap(inner, size) {
    const n = size || 17;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
         + 'stroke-linecap="round" stroke-linejoin="round" width="' + n + '" height="' + n
         + '" aria-hidden="true">' + inner + '</svg>';
  }

  const iconSVG = (name) => svgWrap(ICONS[name] || ICONS.list, 17);

  class PluginPanels {
    /**
     * @param {object} opts
     * @param {string} opts.udid
     * @param {HTMLElement} [opts.mount]     where the rail + panel attach (default document.body)
     * @param {() => boolean} [opts.isBooted]
     * @param {(frame:object|null) => void} [opts.onHighlight]
     * @param {(msg:string) => void} [opts.log]
     */
    constructor({ udid, mount, isBooted, onHighlight, log }) {
      this.udid = udid;
      this.mount = mount || document.body;
      this.isBooted = isBooted || (() => true);
      this.onHighlight = onHighlight || (() => {});
      this.log = log || (() => {});
      this.plugins = [];
      this.openPanelID = null;
      this.rail = null;
      this.host = null;
    }

    async load() {
      let payload;
      try {
        const res = await fetch('/plugins.json', { cache: 'no-cache' });
        if (!res.ok) return;
        payload = await res.json();
      } catch (_) {
        return; // no server-side plugins; nothing to mount
      }
      this.plugins = (payload && payload.plugins) || [];
      this.render();
    }

    /** Flatten manifests to the panels that should show right now. */
    visiblePanels() {
      const out = [];
      for (const plugin of this.plugins) {
        for (const panel of plugin.panels || []) {
          if (panel.when === 'simulator.booted' && !this.isBooted()) continue;
          out.push({ plugin: plugin.name, panel });
        }
      }
      return out;
    }

    render() {
      const panels = this.visiblePanels();
      // No rail at all when nothing is contributed — an empty rail is
      // just clutter that says "a feature exists but you have none".
      if (!panels.length) return;

      PluginPanels.injectCSS();
      this.buildRail();
      for (const { plugin, panel } of panels) this.addButton(plugin, panel);
    }

    buildRail() {
      const rail = document.createElement('aside');
      rail.className = 'plugin-rail';
      rail.setAttribute('aria-label', 'Plugins');
      // Emblem cap — labels the whole strip as the plugins system.
      const cap = document.createElement('div');
      cap.className = 'plugin-rail-cap';
      cap.title = 'Plugins';
      cap.innerHTML = svgWrap(PUZZLE, 16);
      rail.appendChild(cap);
      const divider = document.createElement('div');
      divider.className = 'plugin-rail-divider';
      rail.appendChild(divider);

      const host = document.createElement('div');
      host.className = 'plugin-host';
      host.hidden = true;

      this.mount.appendChild(rail);
      this.mount.appendChild(host);
      this.rail = rail;
      this.host = host;
    }

    addButton(pluginName, panel) {
      const button = document.createElement('button');
      button.className = 'plugin-rail-btn';
      button.id = 'plugin-' + panel.id;
      // title / setAttribute, never innerHTML, for manifest text. The
      // tooltip names the plugin so two plugins' buttons stay legible.
      button.title = panel.title + ' — ' + pluginName;
      button.setAttribute('aria-label', panel.title + ' (' + pluginName + ')');
      // The icon is a host-owned constant chosen by name — the only
      // markup here, and it never contains plugin input.
      button.innerHTML = iconSVG(panel.icon);
      button.addEventListener('click', () => this.toggle(pluginName, panel));
      this.rail.appendChild(button);
    }

    toggle(pluginName, panel) {
      for (const b of this.rail.querySelectorAll('.plugin-rail-btn')) {
        b.classList.toggle('active', b.id === 'plugin-' + panel.id && this.openPanelID !== panel.id);
      }
      if (this.openPanelID === panel.id) { this.close(); return; }
      this.open(pluginName, panel);
    }

    close() {
      this.openPanelID = null;
      this.host.innerHTML = '';
      this.host.hidden = true;
      this.onHighlight(null);
      for (const b of this.rail.querySelectorAll('.plugin-rail-btn')) b.classList.remove('active');
    }

    async open(pluginName, panel) {
      this.openPanelID = panel.id;
      this.host.hidden = false;
      this.renderShell(pluginName, panel, '<div class="plugin-status">Running…</div>');

      const body = panel.body || {};
      if (body.kind !== 'list') {
        this.renderShell(pluginName, panel, '<div class="plugin-status">Unsupported panel</div>');
        return;
      }

      const [id, cmd] = String(body.source).split(':');
      let payload;
      try {
        const url = '/plugins/' + encodeURIComponent(id) + '/commands/' + encodeURIComponent(cmd)
                  + '?udid=' + encodeURIComponent(this.udid);
        const res = await fetch(url, { method: 'POST' });
        payload = await res.json();
      } catch (error) {
        this.renderShell(pluginName, panel, this.statusHTML('Could not reach the server: ' + error));
        return;
      }
      // Guard against a slow response landing after the user moved on.
      if (this.openPanelID !== panel.id) return;

      if (!payload.ok) {
        this.renderShell(pluginName, panel,
          this.statusHTML(payload.error || payload.message || 'Plugin failed'));
        return;
      }
      this.renderRows(pluginName, panel, payload.rows || [], body.rowAction);
    }

    statusHTML(message) {
      return '<div class="plugin-status plugin-error">' + escapeHTML(message) + '</div>';
    }

    renderShell(pluginName, panel, innerHTML) {
      this.host.innerHTML =
        '<div class="plugin-card">'
        + '<div class="plugin-head">'
        +   '<span class="plugin-title">' + escapeHTML(panel.title) + '</span>'
        +   '<span class="plugin-tag">' + escapeHTML(pluginName) + '</span>'
        +   '<button class="plugin-close" aria-label="Close">✕</button>'
        + '</div>'
        + '<div class="plugin-body">' + innerHTML + '</div>'
        + '</div>';
      const close = this.host.querySelector('.plugin-close');
      if (close) close.addEventListener('click', () => this.close());
    }

    renderRows(pluginName, panel, rows, rowAction) {
      if (!rows.length) {
        this.renderShell(pluginName, panel, '<div class="plugin-status">Nothing to report</div>');
        return;
      }
      const items = rows.map((row, index) => {
        const color = SEVERITY_COLOR[row.severity] || SEVERITY_COLOR.info;
        const clickable = rowAction && row.frame ? ' plugin-row-clickable' : '';
        return '<li class="plugin-row' + clickable + '" data-index="' + index + '">'
             + '<span class="plugin-dot" style="background:' + color + '"></span>'
             + '<span class="plugin-row-text">'
             +   '<span class="plugin-row-title">' + escapeHTML(row.title) + '</span>'
             +   (row.subtitle
                   ? '<span class="plugin-row-sub">' + escapeHTML(row.subtitle) + '</span>'
                   : '')
             + '</span></li>';
      }).join('');
      this.renderShell(pluginName, panel, '<ul class="plugin-rows">' + items + '</ul>');

      const list = this.host.querySelector('.plugin-rows');
      if (!list || !rowAction) return;
      list.addEventListener('click', (event) => {
        const li = event.target.closest('.plugin-row');
        if (!li) return;
        const row = rows[Number(li.dataset.index)];
        if (!row) return;
        for (const other of list.querySelectorAll('.plugin-row')) {
          other.classList.toggle('plugin-row-active', other === li);
        }
        if (rowAction === 'highlight') this.onHighlight(row.frame || null);
        if (rowAction === 'copy' && row.copy) navigator.clipboard.writeText(row.copy);
      });
    }
  }

  // Host-owned styling. Injected here rather than added to
  // sim-native.html so the module stays self-contained; no plugin
  // contributes CSS. The rail gets an accent seam so it reads as a
  // distinct system, not another toolbar.
  const CSS = `
  .plugin-rail { position: fixed; right: 16px; top: 50%; transform: translateY(-50%);
                 display: flex; flex-direction: column; align-items: center; gap: 6px;
                 padding: 8px 6px; z-index: 45;
                 background: var(--nv-bar-bg, rgba(255,255,255,0.92));
                 border: 1px solid var(--nv-bar-border, rgba(15,23,42,0.10));
                 border-left: 2px solid var(--accent, #2563eb);
                 border-radius: 14px;
                 box-shadow: var(--nv-bar-shadow, 0 8px 30px rgba(15,23,42,0.12));
                 backdrop-filter: blur(18px) saturate(1.5);
                 -webkit-backdrop-filter: blur(18px) saturate(1.5);
                 color: var(--nv-text, #1d1d1f); }
  .plugin-rail-cap { display: inline-flex; align-items: center; justify-content: center;
                     width: 30px; height: 24px; color: var(--accent, #2563eb); opacity: 0.85; }
  .plugin-rail-divider { width: 20px; height: 1px; margin: 1px 0 3px;
                         background: var(--nv-divider, rgba(15,23,42,0.14)); }
  .plugin-rail-btn { width: 34px; height: 34px; padding: 0; border: 0; cursor: pointer;
                     display: inline-flex; align-items: center; justify-content: center;
                     background: transparent; border-radius: 9px; color: var(--nv-text, #1d1d1f);
                     transition: background 0.12s ease, transform 0.12s ease; }
  .plugin-rail-btn:hover  { background: var(--nv-btn-hover, rgba(15,23,42,0.06)); }
  .plugin-rail-btn:active { transform: scale(0.94); }
  .plugin-rail-btn.active { background: color-mix(in srgb, var(--accent, #2563eb) 16%, transparent);
                            color: var(--accent, #2563eb); }

  .plugin-host { position: fixed; right: 72px; top: 50%; transform: translateY(-50%);
                 width: 340px; max-height: 66vh; z-index: 44; }
  .plugin-card { background: var(--nv-bar-bg, rgba(255,255,255,0.94));
                 border: 1px solid var(--nv-bar-border, rgba(15,23,42,0.10));
                 border-top: 2px solid var(--accent, #2563eb);
                 border-radius: 14px; box-shadow: 0 10px 34px rgba(15,23,42,0.20);
                 backdrop-filter: blur(18px) saturate(1.5);
                 -webkit-backdrop-filter: blur(18px) saturate(1.5);
                 overflow: hidden; display: flex; flex-direction: column; max-height: 66vh; }
  .plugin-head { display: flex; align-items: center; gap: 8px; padding: 10px 12px;
                 border-bottom: 1px solid var(--nv-divider, rgba(15,23,42,0.10)); }
  .plugin-title { font: 600 12px/1 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
                  color: var(--nv-text, #1d1d1f); letter-spacing: 0.02em; }
  .plugin-tag { font: 600 10px/1 -apple-system, sans-serif; letter-spacing: 0.04em;
                text-transform: lowercase; color: var(--accent, #2563eb);
                background: color-mix(in srgb, var(--accent, #2563eb) 12%, transparent);
                padding: 3px 6px; border-radius: 999px; }
  .plugin-close { margin-left: auto; border: 0; background: transparent; cursor: pointer;
                  font-size: 12px; color: var(--nv-text-muted, rgba(29,29,31,0.65)); padding: 2px 4px; }
  .plugin-body { overflow-y: auto; }
  .plugin-status { padding: 14px 12px; font: 400 12px/1.4 -apple-system, sans-serif;
                   color: var(--nv-text-muted, rgba(29,29,31,0.65)); }
  .plugin-error { color: #b91c1c; }
  .plugin-rows { list-style: none; margin: 0; padding: 4px 0; }
  .plugin-row { display: flex; gap: 8px; align-items: flex-start; padding: 8px 12px;
                font: 400 12px/1.35 -apple-system, sans-serif; color: var(--nv-text, #1d1d1f); }
  .plugin-row-clickable { cursor: pointer; }
  .plugin-row-clickable:hover { background: var(--nv-btn-hover, rgba(15,23,42,0.06)); }
  .plugin-row-active { background: var(--nv-btn-active, rgba(15,23,42,0.12)); }
  .plugin-dot { width: 7px; height: 7px; border-radius: 50%; margin-top: 4px; flex: 0 0 auto; }
  .plugin-row-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .plugin-row-sub { color: var(--nv-text-muted, rgba(29,29,31,0.65)); font-size: 11px;
                    overflow-wrap: anywhere; }
  .plugin-highlight { position: absolute; border: 2px solid var(--accent, #2563eb);
                      background: rgba(37,99,235,0.16); border-radius: 3px;
                      pointer-events: none; z-index: 30; }

  @media (max-width: 560px) {
    .plugin-host { right: 12px; left: 12px; width: auto; }
  }
  `;

  function injectCSS() {
    if (document.getElementById('plugin-panel-css')) return;
    const style = document.createElement('style');
    style.id = 'plugin-panel-css';
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  root.PluginPanels = PluginPanels;
  root.PluginPanels.injectCSS = injectCSS;
})(window);
