// sim-plugins.js — renders plugin contributions into focus mode.
//
// The host owns every pixel. A plugin ships a manifest describing what
// it wants (a titled panel, an icon from baguette's own set, a list fed
// by one of its commands); this file draws it with the same markup the
// built-in panels use. Nothing a plugin ships is ever loaded into this
// page — no plugin <script>, no plugin CSS, no plugin HTML. Every
// string that arrives from `/plugins.json` goes through `escapeHTML`
// or `textContent`.
//
// That constraint is deliberate. sim.html is the origin the server's
// ~70 lines of Origin / Sec-Fetch-Site / DNS-rebind checks exist to
// protect; a same-origin plugin script would make all of it moot.
//
// Wire:
//   GET  /plugins.json                        → manifests
//   POST /plugins/<id>/commands/<cmd>?udid=   → {"ok",…,"rows":[…]}
(function (root) {
  'use strict';

  // Glyphs matching Domain/Plugin/PanelBody.swift's `PluginIcon`. A
  // manifest names one; it can never supply markup. Keep the two in
  // sync — an icon the host doesn't have is rejected at parse time,
  // so a missing case here means a plugin that validated can't render.
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

  const SEVERITY_COLOR = {
    error: '#b91c1c',
    warn:  '#b45309',
    info:  '#64748b',
  };

  function escapeHTML(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function iconSVG(name) {
    const body = ICONS[name] || ICONS.list;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" '
         + 'stroke-linecap="round" stroke-linejoin="round" width="17" height="17" aria-hidden="true">'
         + body + '</svg>';
  }

  class PluginPanels {
    /**
     * @param {object} opts
     * @param {string} opts.udid
     * @param {HTMLElement} opts.toolbar   where buttons are appended
     * @param {HTMLElement} opts.host      where panels are mounted
     * @param {() => boolean} [opts.isBooted]
     * @param {(frame:object|null) => void} [opts.onHighlight]
     * @param {(msg:string, isErr?:boolean) => void} [opts.log]
     */
    constructor({ udid, toolbar, host, isBooted, onHighlight, log }) {
      this.udid = udid;
      this.toolbar = toolbar;
      this.host = host;
      this.isBooted = isBooted || (() => true);
      this.onHighlight = onHighlight || (() => {});
      this.log = log || (() => {});
      this.plugins = [];
      this.openPanelID = null;
    }

    async load() {
      let payload;
      try {
        const res = await fetch('/plugins.json', { cache: 'no-cache' });
        if (!res.ok) return;
        payload = await res.json();
      } catch (_) {
        return; // no server-side plugins; the toolbar just stays as it was
      }
      this.plugins = (payload && payload.plugins) || [];
      this.render();
    }

    render() {
      for (const plugin of this.plugins) {
        for (const panel of plugin.panels || []) {
          if (panel.when === 'simulator.booted' && !this.isBooted()) continue;
          this.addButton(panel);
        }
      }
    }

    addButton(panel) {
      const button = document.createElement('button');
      button.className = 'ico-btn';
      button.id = 'plugin-' + panel.id;
      // textContent / setAttribute, never innerHTML, for manifest text.
      button.title = panel.title;
      button.setAttribute('aria-label', panel.title);
      // The icon is a host-owned constant selected by name — the only
      // markup here, and it never contains plugin input.
      button.innerHTML = iconSVG(panel.icon);
      button.addEventListener('click', () => this.toggle(panel));
      this.toolbar.appendChild(button);
    }

    toggle(panel) {
      if (this.openPanelID === panel.id) { this.close(); return; }
      this.open(panel);
    }

    close() {
      this.openPanelID = null;
      this.host.innerHTML = '';
      this.host.hidden = true;
      this.onHighlight(null);
    }

    async open(panel) {
      this.openPanelID = panel.id;
      this.host.hidden = false;
      this.renderShell(panel, '<div class="plugin-status">Running…</div>');

      const body = panel.body || {};
      if (body.kind !== 'list') {
        this.renderShell(panel, '<div class="plugin-status">Unsupported panel</div>');
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
        this.renderShell(panel, this.statusHTML('Could not reach the server: ' + error));
        return;
      }

      if (!payload.ok) {
        this.renderShell(panel, this.statusHTML(payload.error || payload.message || 'Plugin failed'));
        return;
      }
      this.renderRows(panel, payload.rows || [], body.rowAction);
    }

    statusHTML(message) {
      return '<div class="plugin-status plugin-error">' + escapeHTML(message) + '</div>';
    }

    renderShell(panel, innerHTML) {
      this.host.innerHTML =
        '<div class="plugin-card">'
        + '<div class="plugin-head">'
        +   '<span class="plugin-title">' + escapeHTML(panel.title) + '</span>'
        +   '<button class="plugin-close" aria-label="Close">✕</button>'
        + '</div>'
        + '<div class="plugin-body">' + innerHTML + '</div>'
        + '</div>';
      const close = this.host.querySelector('.plugin-close');
      if (close) close.addEventListener('click', () => this.close());
    }

    renderRows(panel, rows, rowAction) {
      if (!rows.length) {
        this.renderShell(panel, '<div class="plugin-status">Nothing to report</div>');
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
      this.renderShell(panel, '<ul class="plugin-rows">' + items + '</ul>');

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

  // Host-owned styling for the panel chrome. Injected here rather
  // than added to sim-native.html so the module stays self-contained;
  // no plugin ever contributes CSS.
  const CSS = `
  .plugin-host { position: fixed; right: 16px; bottom: 16px; width: 340px;
                 max-height: 60vh; z-index: 40; }
  .plugin-card { background: var(--nv-bar-bg, rgba(255,255,255,0.92));
                 border: 1px solid var(--nv-bar-border, rgba(15,23,42,0.10));
                 border-radius: 14px; box-shadow: 0 8px 30px rgba(15,23,42,0.18);
                 backdrop-filter: blur(18px) saturate(1.5);
                 -webkit-backdrop-filter: blur(18px) saturate(1.5);
                 overflow: hidden; display: flex; flex-direction: column;
                 max-height: 60vh; }
  .plugin-head { display: flex; align-items: center; justify-content: space-between;
                 padding: 10px 12px; border-bottom: 1px solid var(--nv-divider, rgba(15,23,42,0.10)); }
  .plugin-title { font: 600 12px/1 -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
                  color: var(--nv-text, #1d1d1f); letter-spacing: 0.02em; }
  .plugin-close { border: 0; background: transparent; cursor: pointer; font-size: 12px;
                  color: var(--nv-text-muted, rgba(29,29,31,0.65)); padding: 2px 4px; }
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
  .plugin-highlight { position: absolute; border: 2px solid #2563eb;
                      background: rgba(37,99,235,0.16); border-radius: 3px;
                      pointer-events: none; z-index: 30; }
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
