// sim-network.js — network-conditioning panel for the focus page.
//
// Hangs `window.NetworkPanel` on the global so sim-native.js can surface a
// floating glass card that conditions what the simulator's apps see of the
// network — latency, downlink bandwidth, request loss, and hard offline.
//
// The panel is a dumb sender: every change debounces into a
// `POST /simulators/<udid>/network` and "Stop conditioning" sends `DELETE`.
// Swift owns all domain logic — the preset figures, validation, and the
// pacing arithmetic. Even the list of preset *names* comes from the server,
// so adding one shows up here without an edit. The one piece of logic on
// this side, deciding which of the three mutually exclusive sources a body
// states, lives in `NetworkConditionForm` where it is unit-tested.
//
// See `docs/features/network.md`.

(function () {
  'use strict';

  const PROFILE_LABELS = {
    wifi: 'Wi-Fi', dsl: 'DSL', lte: 'LTE', '3g': '3G', edge: 'Edge',
    'very-bad-network': 'Very bad', '100-loss': '100% loss',
  };

  class NetworkPanel {
    constructor() {
      this.host = null;
      this.udid = null;
      this._timer = null;
      this.profiles = [];
      // What the controls currently say. Starts unconditioned; `_hydrate`
      // replaces it with whatever the device is actually subject to.
      this.state = {
        profile: null, latencyMs: 0, bandwidthKbps: 0, lossPercent: 0, offline: false,
      };
      /** Called with a `NetworkConditionForm` whenever the armed state may
       *  have changed, so the toolbar can show a throttle is on even while
       *  this card is closed. */
      this.onArmedChange = null;
    }

    /** @param {HTMLElement} host @param {string} udid */
    attach(host, udid) {
      if (!host || !udid) return;
      this.host = host;
      this.udid = udid;
      this._build();
      this._hydrate();
    }

    detach() {
      if (this._timer) { clearTimeout(this._timer); this._timer = null; }
      if (this.host) { this.host.innerHTML = ''; this.host = null; }
    }

    refresh() { this._hydrate(); }

    _form() {
      return new window.Baguette._NetworkConditionForm(this.state);
    }

    // Read what this simulator is actually subject to, so the card opens
    // showing the truth rather than whatever was last typed into it.
    async _hydrate() {
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(this.udid)}/network`);
        if (!res.ok) return;
        this._absorb(await res.json());
      } catch (e) { /* keep what we have */ }
    }

    _absorb(data) {
      if (!data) return;
      if (Array.isArray(data.profiles)) this.profiles = data.profiles;
      const form = window.Baguette._NetworkConditionForm.fromState(data);
      this.state = {
        // A preset resolves to numbers server-side, and the server reports
        // those numbers rather than the name it was given — so the pills
        // deselect once applied. The numbers are the honest readout.
        profile: null,
        latencyMs: form.latencyMs || 0,
        bandwidthKbps: form.bandwidthKbps || 0,
        lossPercent: form.lossPercent || 0,
        offline: form.offline,
      };
      if (this.host) this._build();
      this._announce();
    }

    _announce() {
      if (this.onArmedChange) this.onArmedChange(this._form());
    }

    // ---- view construction --------------------------------------

    _build() {
      const s = this.state;
      const off = s.offline;
      this.host.innerHTML =
        '<div class="nw-section">' +
          '<p class="nw-section-title">Preset</p>' +
          '<div class="nw-pills" data-pills="profile">' +
            this.profiles.map((p) =>
              `<button class="nw-pill" data-p="${escapeAttr(p)}" ${off ? 'disabled' : ''}>` +
              `${escapeAttr(PROFILE_LABELS[p] || p)}</button>`
            ).join('') +
          '</div>' +
        '</div>' +
        '<div class="nw-section">' +
          '<p class="nw-section-title">Custom</p>' +
          this._numberRow('Latency', 'latencyMs', s.latencyMs, 'ms', off) +
          this._numberRow('Bandwidth', 'bandwidthKbps', s.bandwidthKbps, 'kbps', off) +
          this._numberRow('Loss', 'lossPercent', s.lossPercent, '%', off) +
          '<p class="nw-hint">Leave bandwidth at 0 to keep the link unmetered.</p>' +
        '</div>' +
        '<div class="nw-section">' +
          '<label class="nw-toggle">' +
            `<input type="checkbox" data-k="offline" ${off ? 'checked' : ''}>` +
            '<span>Offline — report no connection at all</span>' +
          '</label>' +
        '</div>' +
        '<div class="nw-section nw-footer">' +
          `<span class="nw-state ${this._form().isConditioning ? 'on' : ''}">` +
            escapeAttr(this._form().describe()) +
          '</span>' +
          '<button class="nw-clear" data-act="clear">Stop conditioning</button>' +
        '</div>' +
        '<p class="nw-note">Only apps launched after conditioning starts are affected. ' +
        'Changing it afterwards reaches a running app without a relaunch.</p>';

      this._wire();
    }

    _numberRow(label, key, value, unit, disabled) {
      return `<div class="nw-row">
        <span class="nw-row-label">${label}</span>
        <span class="nw-row-control">
          <input class="nw-field" data-k="${key}" type="number" min="0" step="1"
                 value="${Number(value) || 0}" aria-label="${label} in ${unit}"
                 ${disabled ? 'disabled' : ''}>
          <span class="nw-unit">${unit}</span>
        </span>
      </div>`;
    }

    // ---- event wiring -------------------------------------------

    _wire() {
      const h = this.host;

      const pills = h.querySelector('[data-pills="profile"]');
      if (pills) {
        pills.addEventListener('click', (e) => {
          const b = e.target.closest('.nw-pill');
          if (!b || b.disabled) return;
          this.state.profile = b.getAttribute('data-p');
          pills.querySelectorAll('.nw-pill').forEach((c) => c.classList.remove('active'));
          b.classList.add('active');
          this._scheduleApply();
        });
      }

      h.querySelectorAll('input[data-k]').forEach((el) => {
        const key = el.getAttribute('data-k');
        el.addEventListener(key === 'offline' ? 'change' : 'input', () => {
          if (key === 'offline') {
            this.state.offline = el.checked;
          } else {
            this.state[key] = Number(el.value);
            // Typing a number means the numbers are what's wanted. Leaving
            // a preset selected would make the request state two sources
            // and get it refused, so the pill lets go.
            this.state.profile = null;
            h.querySelectorAll('.nw-pill').forEach((c) => c.classList.remove('active'));
          }
          this._scheduleApply();
        });
      });

      const clearBtn = h.querySelector('[data-act="clear"]');
      if (clearBtn) clearBtn.onclick = () => this.clear();
    }

    // ---- network --------------------------------------------------

    _scheduleApply() {
      if (this._timer) clearTimeout(this._timer);
      this._timer = setTimeout(() => {
        this._timer = null;
        this._enqueue(() => this._apply());
      }, 300);
    }

    /// Every apply and clear goes through one chain, because the two are not
    /// interchangeable in flight: typing a number and then hitting Stop could
    /// otherwise land the POST *after* the DELETE and leave the device
    /// throttled while the card said it had stopped — which is precisely the
    /// state this feature spends the rest of its design trying to prevent.
    _enqueue(task) {
      this._chain = (this._chain || Promise.resolve()).then(task, task);
      return this._chain;
    }

    async _apply() {
      if (!this.udid) return;
      const body = this._form().toBody();
      // Nothing selected is a clear, not a POST the route would refuse.
      if (!body) return this._clear();
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(this.udid)}/network`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (res.ok) this._absorb(await res.json());
      } catch (e) {
        console.warn('[network] conditioning failed', e);
      }
    }

    clear() {
      // Drop a debounced apply that hasn't fired yet: it describes a state
      // the user has just abandoned, and running it after the DELETE would
      // re-arm the throttle they were trying to stop.
      if (this._timer) { clearTimeout(this._timer); this._timer = null; }
      return this._enqueue(() => this._clear());
    }

    async _clear() {
      if (!this.udid) return;
      try {
        const res = await fetch(`/simulators/${encodeURIComponent(this.udid)}/network`,
                                { method: 'DELETE' });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
      } catch (e) {
        // A failed DELETE must not read as stopped — the device is still
        // conditioned. Re-read rather than assuming either way, so the card
        // and the badge keep telling the truth.
        console.warn('[network] clear failed', e);
        await this._hydrate();
        return;
      }
      this.state = {
        profile: null, latencyMs: 0, bandwidthKbps: 0, lossPercent: 0, offline: false,
      };
      if (this.host) this._build();
      this._announce();
    }
  }

  function escapeAttr(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  window.NetworkPanel = NetworkPanel;
})();
