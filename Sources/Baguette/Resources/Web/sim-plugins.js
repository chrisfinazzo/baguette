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
    // Also what the host resolves an unrecognised icon name to, so a
    // plugin naming a glyph added after this build still draws
    // something deliberate. Defined below, wired in after PUZZLE.
    puzzle:        '',
  };

  // The rail's own emblem — a puzzle piece. Names the rail as "the
  // plugins system" so the group reads as distinct from the toolbar.
  const PUZZLE =
    '<path d="M10 4.5a2 2 0 0 1 4 0c0 .3-.1.6-.2.9.2-.1.5-.1.7-.1h1.5a1 1 0 0 1 1 1v1.5c0 .2 0 .5-.1.7.3-.1.6-.2.9-.2a2 2 0 0 1 0 4c-.3 0-.6-.1-.9-.2.1.2.1.5.1.7v2.5a1 1 0 0 1-1 1h-2.5c-.2 0-.5 0-.7-.1.1.3.2.6.2.9a2 2 0 0 1-4 0c0-.3.1-.6.2-.9-.2.1-.5.1-.7.1H6a1 1 0 0 1-1-1v-2.5c0-.2 0-.5.1-.7-.3.1-.6.2-.9.2a2 2 0 0 1 0-4c.3 0 .6.1.9.2C5 8.6 5 8.3 5 8.1V6.4a1 1 0 0 1 1-1h1.5c.2 0 .5 0 .7.1-.1-.3-.2-.6-.2-.9z"/>';

  ICONS.puzzle = PUZZLE;

  // The severities the stylesheet draws a dot for. Anything else — a
  // level from a newer manifest, or a typo — falls back to `info`
  // rather than reaching the page as an unrecognised attribute value.
  const SEVERITIES = ['info', 'warn', 'error'];

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
     * @param {(point:{x:number,y:number}) => void} [opts.onTap]  device points
     * @param {(msg:string) => void} [opts.log]
     */
    constructor({ udid, mount, isBooted, onHighlight, onTap, log }) {
      this.udid = udid;
      this.mount = mount || document.body;
      this.isBooted = isBooted || (() => true);
      this.onHighlight = onHighlight || (() => {});
      this.onTap = onTap || (() => {});
      this.log = log || (() => {});
      this.plugins = [];
      this.openPanelID = null;
      this.rail = null;
      this.host = null;
      // The hover flyout: at most one open, owned by one group button.
      this.flyout = null;
      this.flyoutGroup = null;
      this.flyoutButton = null;
      this.flyoutCloseTimer = null;
      this.onFlyoutKeydown = (event) => { if (event.key === 'Escape') this.closeFlyout(); };
    }

    /**
     * Fetch the contributed panels and draw the rail.
     *
     * `keepRailOnFailure` separates two different failures. On a cold
     * start, an unreachable `/plugins.json` means this server has no
     * plugin support and the right answer is to mount nothing. On a
     * *reload* the rail was already on screen and the user is mid-task
     * — dropping it there would take away the "+" button, which is the
     * only in-browser way to add a plugin, with nothing but a page
     * refresh to bring it back.
     */
    async load({ keepRailOnFailure = false } = {}) {
      let payload;
      try {
        const res = await fetch('/plugins.json', { cache: 'no-cache' });
        if (!res.ok) throw new Error('plugins.json: ' + res.status);
        payload = await res.json();
      } catch (_) {
        if (!keepRailOnFailure) return; // no server-side plugins; nothing to mount
        payload = null;
      }
      this.plugins = (payload && payload.plugins) || [];
      this.render();
    }

    /**
     * The plugins that have something to show right now, each with the
     * panels it currently contributes.
     *
     * One plugin is one rail slot, however many tools it ships. A
     * plugin with eight panels used to spend eight slots and nothing
     * said the eight belonged together; grouping by the contributing
     * plugin makes the rail's length a count of what you installed,
     * not of what those things happen to contribute.
     */
    visibleGroups() {
      const out = [];
      for (const plugin of this.plugins) {
        const panels = (plugin.panels || []).filter(
          (panel) => !(panel.when === 'simulator.booted' && !this.isBooted())
        );
        if (!panels.length) continue;   // nothing to show ⇒ no slot
        out.push({ name: plugin.name, icon: plugin.icon, panels });
      }
      return out;
    }

    render() {
      this.buildRail();
      for (const group of this.visibleGroups()) this.addGroup(group);
      // The "+ Add" entry point always shows, so a fresh user with no
      // plugins can still add their first bakery from the browser.
      this.addAddButton();
    }

    /// Tear the rail down and re-fetch — used after an install so the
    /// new plugin's button appears without a page reload.
    async reload() {
      this.closeFlyout();
      if (this.rail) this.rail.remove();
      if (this.host) this.host.remove();
      this.rail = null;
      this.host = null;
      this.openPanelID = null;
      await this.load({ keepRailOnFailure: true });
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

    /**
     * One rail slot for one plugin.
     *
     * A plugin contributing a single panel keeps the old behaviour —
     * click opens it. Making you hover, wait, and then pick the only
     * item would be ceremony over a button. Only a plugin with more
     * than one tool earns the flyout.
     */
    addGroup(group) {
      const button = document.createElement('button');
      button.className = 'plugin-rail-btn';
      // The icon is a host-owned constant chosen by name — the only
      // markup here, and it never contains plugin input. The server
      // resolves which glyph represents the plugin (`Plugin.railIcon`),
      // so a plugin with no icon of its own already arrives wearing its
      // first panel's; the puzzle piece is the last resort.
      button.innerHTML = group.icon ? iconSVG(group.icon) : svgWrap(PUZZLE, 17);

      const single = group.panels.length === 1 ? group.panels[0] : null;
      // title / setAttribute, never innerHTML, for manifest text.
      if (single) {
        button.title = single.title + ' — ' + group.name;
        button.setAttribute('aria-label', single.title + ' (' + group.name + ')');
        button.addEventListener('click', () => this.toggle(group, single));
      } else {
        button.classList.add('plugin-rail-group');
        button.title = group.name + ' — ' + group.panels.length + ' tools';
        button.setAttribute('aria-label', group.name + ', ' + group.panels.length + ' tools');
        button.setAttribute('aria-haspopup', 'menu');
        button.setAttribute('aria-expanded', 'false');
        // Hover opens it; click and keyboard focus do too, so the rail
        // stays usable on a trackpad-less touch screen and by tab.
        button.addEventListener('mouseenter', () => this.openFlyout(group, button));
        button.addEventListener('mouseleave', () => this.scheduleFlyoutClose());
        button.addEventListener('focus', () => this.openFlyout(group, button));
        button.addEventListener('click', () => {
          if (this.flyoutGroup === group.name) this.closeFlyout();
          else this.openFlyout(group, button);
        });
      }

      group.button = button;
      this.rail.appendChild(button);
    }

    // --- the flyout ---------------------------------------------------
    //
    // Opens to the LEFT of the rail, aligned to the group button, and
    // lists each tool with its icon *and* its name. Icons alone stop
    // telling a plugin's tools apart once there are more than two or
    // three of them — the label is the point of the expansion.

    openFlyout(group, button) {
      this.cancelFlyoutClose();
      if (this.flyoutGroup === group.name) return;   // already showing
      this.closeFlyout();

      const flyout = document.createElement('div');
      flyout.className = 'plugin-flyout';
      flyout.setAttribute('role', 'menu');
      flyout.setAttribute('aria-label', group.name);

      const head = document.createElement('div');
      head.className = 'plugin-flyout-head';
      head.textContent = group.name;   // manifest text → textContent, never markup
      flyout.appendChild(head);

      for (const panel of group.panels) {
        const item = document.createElement('button');
        item.className = 'plugin-flyout-item';
        item.setAttribute('role', 'menuitem');
        if (this.openPanelID === panel.id) item.classList.add('active');

        const glyph = document.createElement('span');
        glyph.className = 'plugin-flyout-glyph';
        glyph.innerHTML = iconSVG(panel.icon);       // host constant
        const label = document.createElement('span');
        label.className = 'plugin-flyout-label';
        label.textContent = panel.title;             // untrusted → textContent
        item.appendChild(glyph);
        item.appendChild(label);

        item.addEventListener('click', () => {
          this.toggle(group, panel);
          this.closeFlyout();
        });
        flyout.appendChild(item);
      }

      flyout.addEventListener('mouseenter', () => this.cancelFlyoutClose());
      flyout.addEventListener('mouseleave', () => this.scheduleFlyoutClose());
      this.mount.appendChild(flyout);

      this.flyout = flyout;
      this.flyoutGroup = group.name;
      this.flyoutButton = button;
      button.setAttribute('aria-expanded', 'true');
      button.classList.add('expanded');
      document.addEventListener('keydown', this.onFlyoutKeydown);
      this.positionFlyout(flyout, button);
    }

    /// Centre the flyout on its button, then keep it on screen — a
    /// group near the top or bottom of a short window would otherwise
    /// hang off the edge.
    positionFlyout(flyout, button) {
      const rail = this.rail.getBoundingClientRect();
      const anchor = button.getBoundingClientRect();
      flyout.style.right = (window.innerWidth - rail.left + 8) + 'px';
      const height = flyout.offsetHeight;
      const centred = anchor.top + anchor.height / 2 - height / 2;
      const clamped = Math.max(12, Math.min(centred, window.innerHeight - height - 12));
      flyout.style.top = clamped + 'px';
    }

    /// A grace period so travelling from the button to the flyout
    /// across the 8px gap doesn't dismiss what you're reaching for.
    scheduleFlyoutClose() {
      this.cancelFlyoutClose();
      this.flyoutCloseTimer = setTimeout(() => this.closeFlyout(), 160);
    }

    cancelFlyoutClose() {
      if (this.flyoutCloseTimer) clearTimeout(this.flyoutCloseTimer);
      this.flyoutCloseTimer = null;
    }

    closeFlyout() {
      this.cancelFlyoutClose();
      if (this.flyoutButton) {
        this.flyoutButton.setAttribute('aria-expanded', 'false');
        this.flyoutButton.classList.remove('expanded');
      }
      if (this.flyout) this.flyout.remove();
      this.flyout = null;
      this.flyoutGroup = null;
      this.flyoutButton = null;
      document.removeEventListener('keydown', this.onFlyoutKeydown);
    }

    /// A "+" at the foot of the rail that opens the add-a-bakery modal.
    addAddButton() {
      const divider = document.createElement('div');
      divider.className = 'plugin-rail-divider';
      this.rail.appendChild(divider);

      const button = document.createElement('button');
      button.className = 'plugin-rail-btn plugin-rail-add';
      button.title = 'Add a plugin from a bakery';
      button.setAttribute('aria-label', 'Add a plugin');
      button.innerHTML = svgWrap('<path d="M12 5v14M5 12h14"/>', 18);
      button.addEventListener('click', () => this.openAddModal());
      this.rail.appendChild(button);
    }

    /// The rail highlights the *plugin* whose panel is open, not the
    /// panel — the panel no longer has a slot of its own to light up.
    toggle(group, panel) {
      if (this.openPanelID === panel.id) { this.close(); return; }
      for (const b of this.rail.querySelectorAll('.plugin-rail-btn')) {
        b.classList.toggle('active', b === group.button);
      }
      this.open(group.name, panel);
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
      await this.invoke(pluginName, panel, id, cmd, null);
    }

    /**
     * Run one of a plugin's commands and render the answer into the
     * open panel. Both the panel's own `source` and a `rowAction:
     * "run"` click land here, so a row that changes something re-renders
     * from the command's fresh output rather than from what the browser
     * assumed would happen.
     *
     * @param {string} id       plugin id
     * @param {string} cmd      command id within that plugin
     * @param {object|null} args  arguments from the clicked row, if any
     */
    async invoke(pluginName, panel, id, cmd, args) {
      const body = panel.body || {};
      let payload;
      try {
        const url = '/plugins/' + encodeURIComponent(id) + '/commands/' + encodeURIComponent(cmd)
                  + '?udid=' + encodeURIComponent(this.udid);
        const init = { method: 'POST' };
        if (args) {
          init.headers = { 'content-type': 'application/json' };
          init.body = JSON.stringify({ args });
        }
        const res = await fetch(url, init);
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

    /**
     * Copy a row's text, and say so when the browser won't.
     *
     * `navigator.clipboard` is undefined outside a secure context, and
     * while `127.0.0.1` counts as secure, `serve` accepts
     * `--allowed-hosts` — so the page can be reached by hostname over
     * plain http, where this is simply absent. Calling it there throws
     * inside the click handler and the row just looks selected with
     * nothing on the clipboard. `writeText` can also reject on a
     * permission failure, which was likewise unhandled.
     */
    copyToClipboard(text, row) {
      const clipboard = navigator.clipboard;
      if (!clipboard || typeof clipboard.writeText !== 'function') {
        this.noteRowError(row, 'clipboard needs https or localhost');
        return;
      }
      clipboard.writeText(text).catch((error) => {
        this.noteRowError(row, String((error && error.message) || error));
      });
    }

    /** A short-lived note on one row, for a failure that isn't the panel's. */
    noteRowError(row, message) {
      if (!row) return;
      const previous = row.querySelector('.plugin-inline-error');
      if (previous) previous.remove();
      const note = document.createElement('span');
      note.className = 'plugin-error plugin-inline-error';
      note.textContent = ' ' + message;
      row.appendChild(note);
      setTimeout(() => note.remove(), 4000);
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
      const action = new window.Baguette._PluginRowAction(rowAction);
      const items = rows.map((row, index) => {
        const severity = SEVERITIES.includes(row.severity) ? row.severity : 'info';
        const clickable = action.actionable(row) ? ' plugin-row-clickable' : '';
        return '<li class="plugin-row' + clickable + '" data-index="' + index + '">'
             + '<span class="plugin-dot" data-severity="' + severity + '"></span>'
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
        const intent = action.intent(row);
        if (!intent) return;   // an inert row stays inert, selection included
        for (const other of list.querySelectorAll('.plugin-row')) {
          other.classList.toggle('plugin-row-active', other === li);
        }
        if (intent.kind === 'highlight') this.onHighlight(intent.frame);
        if (intent.kind === 'tap') this.onTap(intent.point);
        if (intent.kind === 'copy') this.copyToClipboard(intent.text, li);
        if (intent.kind === 'run') {
          // The row names a command within its own plugin; the plugin
          // id comes from the panel's own source, so a row can never
          // reach into a different plugin.
          const pluginID = String((panel.body || {}).source || '').split(':')[0];
          this.invoke(pluginName, panel, pluginID, intent.command, intent.args);
        }
      });
    }

    // --- add-a-bakery modal ------------------------------------------
    //
    // Preview only. Cloning a repo and reading its menu is safe and
    // needs the browser; *installing* writes files that later run as
    // programs, and this page's only protection is a set of origin
    // heuristics. A terminal carries trust context a web page can't —
    // you typed the command — so the modal ends by handing you one.

    openAddModal() {
      const overlay = document.createElement('div');
      overlay.className = 'plugin-modal-overlay';
      overlay.innerHTML =
        '<div class="plugin-modal" role="dialog" aria-label="Add a plugin">'
        + '<div class="plugin-head">'
        +   '<span class="plugin-title">Add a plugin</span>'
        +   '<button class="plugin-close" aria-label="Close">✕</button>'
        + '</div>'
        + '<div class="plugin-modal-body">'
        +   '<label class="plugin-field-label">Bakery — a git repo with a baguette.json</label>'
        +   '<div class="plugin-field-row">'
        +     '<input class="plugin-input" type="text" placeholder="owner/repo or a git URL" spellcheck="false">'
        +     '<button class="plugin-btn plugin-preview-btn">Preview</button>'
        +   '</div>'
        +   '<div class="plugin-modal-result"></div>'
        + '</div>'
        + '</div>';
      this.mount.appendChild(overlay);

      const close = () => overlay.remove();
      overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
      overlay.querySelector('.plugin-close').addEventListener('click', close);

      const input = overlay.querySelector('.plugin-input');
      const result = overlay.querySelector('.plugin-modal-result');
      const preview = () => this.previewInto(input.value.trim(), result, close);
      overlay.querySelector('.plugin-preview-btn').addEventListener('click', preview);
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') preview(); });
      input.focus();
    }

    async previewInto(ref, result, closeModal) {
      if (!ref) return;
      result.innerHTML = '<div class="plugin-status">Fetching…</div>';
      let data;
      try {
        const res = await fetch('/bakeries/preview', {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ ref }),
        });
        data = await res.json();
        if (!res.ok) throw new Error(data.error || 'preview failed');
      } catch (error) {
        result.innerHTML = '<div class="plugin-status plugin-error">' + escapeHTML(String(error.message || error)) + '</div>';
        return;
      }

      const shortCommit = String(data.commit || '').slice(0, 10);
      // Each offered plugin becomes the command that installs it, not a
      // button that does. Installing puts files on the machine that
      // later run as programs, and a terminal carries trust context a
      // web page can't — you typed it. See `docs/features/plugins.md`.
      const rows = (data.plugins || []).map((p) =>
        '<li class="plugin-offer">'
        + '<span class="plugin-row-title">' + escapeHTML(p.name) + '</span>'
        + '<code class="plugin-cmd">baguette plugin install '
        +   escapeHTML(ref) + '/' + escapeHTML(p.name) + '</code>'
        + '<button class="plugin-btn plugin-copy-cmd" data-plugin="' + escapeHTML(p.name) + '">Copy</button>'
        + '</li>').join('');

      result.innerHTML =
        '<div class="plugin-warn">'
        +   '⚠ Plugins from <b>' + escapeHTML(data.name || ref) + '</b> run as programs on your Mac '
        +   'with your permissions. Only add sources you trust. '
        +   '<span class="plugin-commit">@' + escapeHTML(shortCommit) + '</span>'
        + '</div>'
        + '<ul class="plugin-offers">' + rows + '</ul>'
        + '<div class="plugin-status">Run one of these in a terminal, then reopen the rail.</div>';

      for (const btn of result.querySelectorAll('.plugin-copy-cmd')) {
        btn.addEventListener('click', () => {
          const row = btn.closest('.plugin-offer');
          const cmd = row && row.querySelector('.plugin-cmd');
          this.copyToClipboard(cmd ? cmd.textContent : '', row);
        });
      }
    }

  }

  // No CSS here. The rail, its flyout and the panel are styled by the
  // focus-mode stylesheet in sim-native.html, under `#simNativeView`,
  // where the --nv-* theme tokens are defined — same arrangement as the
  // logs, status-bar, location and a11y panels. A stylesheet written
  // beside this module can't see those tokens, so every colour in it had
  // to carry a guessed fallback, and the guesses were light-theme values.
  root.PluginPanels = PluginPanels;
})(window);
