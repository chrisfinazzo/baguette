// sim-3d.js — one-shot 3D device preview for focus mode.
//
// Fetches public model metadata, builds variant controls dynamically,
// and POSTs render options to /render-3d.png. The server owns all USD
// paths and model instructions; this module sends only public IDs.
(function () {
  'use strict';

  const CUBE =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="1.6" stroke-linejoin="round" width="15" height="15">' +
      '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9z"/>' +
      '<path d="m4 7.5 8 4.5 8-4.5M12 12v9"/></svg>';

  function Sim3DPanel() {
    this.host = null;
    this.udid = '';
    this.model = null;
    this.previewURL = '';
    this.controller = null;
    this.rotation = { x: -8, y: 18, z: 0 };
    this.variants = {};
  }

  Sim3DPanel.prototype.attach = async function (host, udid) {
    this.host = host;
    this.udid = udid;
    this.renderLoading('Loading model…');
    try {
      const response = await fetch(
          '/simulators/' + encodeURIComponent(udid) + '/3d-model.json',
          { cache: 'no-store' }
      );
      if (!response.ok) {
        throw new Error(response.status === 404
          ? 'No 3D model is installed for this simulator.'
          : 'Could not load model metadata.');
      }
      this.model = await response.json();
      (this.model.variantSets || []).forEach((set) => {
        this.variants[set.id] = set.default;
      });
      this.renderControls();
      await this.refresh();
    } catch (error) {
      this.renderError(error.message || String(error));
    }
  };

  Sim3DPanel.prototype.detach = function () {
    if (this.controller) this.controller.abort();
    this.controller = null;
    if (this.previewURL) URL.revokeObjectURL(this.previewURL);
    this.previewURL = '';
    if (this.host) this.host.innerHTML = '';
    this.host = null;
  };

  Sim3DPanel.prototype.renderLoading = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty"><span class="r3d-spinner"></span>' +
        '<span></span></div>';
    this.host.querySelector('.r3d-empty span:last-child').textContent = message;
  };

  Sim3DPanel.prototype.renderError = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty r3d-error">' + CUBE + '<strong>3D preview unavailable</strong>' +
        '<span data-role="message"></span>' +
        '<button type="button" data-role="retry">Try Again</button></div>';
    this.host.querySelector('[data-role="message"]').textContent = message;
    this.host.querySelector('[data-role="retry"]').addEventListener(
        'click', () => this.attach(this.host, this.udid)
    );
  };

  Sim3DPanel.prototype.renderControls = function () {
    if (!this.host || !this.model) return;
    const variantHTML = (this.model.variantSets || []).map((set) => {
      const choices = (set.choices || []).map((choice) => {
        const color = choice.previewColor
          ? '<i style="--swatch:' + escapeAttr(choice.previewColor) + '"></i>'
          : '';
        return '<button type="button" class="r3d-choice" data-set="' +
            escapeAttr(set.id) + '" data-choice="' + escapeAttr(choice.id) + '">' +
            color + '<span>' + escapeHTML(choice.displayName) + '</span></button>';
      }).join('');
      return '<section class="r3d-section"><label>' +
          escapeHTML(set.displayName) + '</label><div class="r3d-choices">' +
          choices + '</div></section>';
    }).join('');

    this.host.innerHTML =
        '<div class="r3d-preview">' +
          '<img data-role="preview" alt="Rendered 3D device preview">' +
          '<div class="r3d-progress" data-role="progress"><span class="r3d-spinner"></span>Rendering…</div>' +
        '</div>' +
        '<div class="r3d-model-name">' + escapeHTML(this.model.displayName) + '</div>' +
        variantHTML +
        '<section class="r3d-section"><label>Camera</label>' +
          '<div class="r3d-presets">' +
            '<button type="button" data-preset="-8,18,0">Hero</button>' +
            '<button type="button" data-preset="0,0,0">Front</button>' +
            '<button type="button" data-preset="0,38,0">Side</button>' +
            '<button type="button" data-preset="-28,28,0">Top</button>' +
          '</div>' +
          rangeRow('x', 'Tilt', -45, 45, this.rotation.x) +
          rangeRow('y', 'Turn', -180, 180, this.rotation.y) +
          rangeRow('z', 'Roll', -45, 45, this.rotation.z) +
        '</section>' +
        '<div class="r3d-footer">' +
          '<button type="button" class="r3d-download" data-role="download">Download PNG</button>' +
          '<button type="button" class="r3d-render" data-role="render">Render</button>' +
        '</div>';

    this.host.querySelectorAll('.r3d-choice').forEach((button) => {
      const selected = this.variants[button.dataset.set] === button.dataset.choice;
      button.classList.toggle('active', selected);
      button.addEventListener('click', () => {
        this.variants[button.dataset.set] = button.dataset.choice;
        this.host.querySelectorAll(
            '.r3d-choice[data-set="' + cssEscape(button.dataset.set) + '"]'
        ).forEach((candidate) => {
          candidate.classList.toggle(
              'active',
              candidate.dataset.choice === button.dataset.choice
          );
        });
        this.refresh();
      });
    });

    this.host.querySelectorAll('[data-axis]').forEach((range) => {
      const value = this.host.querySelector(
          '[data-value="' + range.dataset.axis + '"]'
      );
      range.addEventListener('input', () => {
        this.rotation[range.dataset.axis] = Number(range.value);
        if (value) value.textContent = range.value + '°';
      });
      range.addEventListener('change', () => this.refresh());
      range.addEventListener('pointerup', () => this.refresh());
    });
    this.host.querySelectorAll('[data-preset]').forEach((button) => {
      button.addEventListener('click', () => {
        const values = button.dataset.preset.split(',').map(Number);
        ['x', 'y', 'z'].forEach((axis, index) => {
          this.rotation[axis] = values[index];
          const range = this.host.querySelector('[data-axis="' + axis + '"]');
          const label = this.host.querySelector('[data-value="' + axis + '"]');
          if (range) range.value = String(values[index]);
          if (label) label.textContent = values[index] + '°';
        });
        this.refresh();
      });
    });
    this.host.querySelector('[data-role="render"]').addEventListener(
        'click', () => this.refresh()
    );
    this.host.querySelector('[data-role="download"]').addEventListener(
        'click', () => this.download()
    );
  };

  Sim3DPanel.prototype.refresh = async function () {
    if (!this.host || !this.model) return;
    if (this.controller) this.controller.abort();
    this.controller = new AbortController();
    const progress = this.host.querySelector('[data-role="progress"]');
    const renderButton = this.host.querySelector('[data-role="render"]');
    if (progress) progress.hidden = false;
    if (renderButton) renderButton.disabled = true;
    try {
      const response = await fetch(
          '/simulators/' + encodeURIComponent(this.udid) + '/render-3d.png',
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              rotation: this.rotation,
              variants: this.variants,
              size: { width: 1000, height: 760 },
              fit: 'cover',
              background: 'transparent',
            }),
            signal: this.controller.signal,
          }
      );
      if (!response.ok) {
        const detail = await response.json().catch(() => null);
        throw new Error((detail && detail.error) || ('render failed (HTTP ' + response.status + ')'));
      }
      const blob = await response.blob();
      if (this.previewURL) URL.revokeObjectURL(this.previewURL);
      this.previewURL = URL.createObjectURL(blob);
      const image = this.host.querySelector('[data-role="preview"]');
      if (image) {
        image.src = this.previewURL;
        image.hidden = false;
      }
    } catch (error) {
      if (error && error.name === 'AbortError') return;
      const preview = this.host.querySelector('.r3d-preview');
      if (preview) preview.setAttribute('data-error', error.message || String(error));
    } finally {
      if (progress) progress.hidden = true;
      if (renderButton) renderButton.disabled = false;
    }
  };

  Sim3DPanel.prototype.download = function () {
    if (!this.previewURL) return;
    const link = document.createElement('a');
    link.href = this.previewURL;
    link.download = (this.model.id || 'device') + '-3d.png';
    document.body.appendChild(link);
    link.click();
    link.remove();
  };

  function rangeRow(axis, label, min, max, value) {
    return '<div class="r3d-range-row"><span>' + label + '</span>' +
        '<input type="range" min="' + min + '" max="' + max + '" value="' +
        value + '" data-axis="' + axis + '">' +
        '<output data-value="' + axis + '">' + value + '°</output></div>';
  }

  function escapeHTML(value) {
    const div = document.createElement('div');
    div.textContent = String(value || '');
    return div.innerHTML;
  }

  function escapeAttr(value) {
    return escapeHTML(value).replace(/"/g, '&quot;');
  }

  function cssEscape(value) {
    return window.CSS && CSS.escape ? CSS.escape(value) : value.replace(/"/g, '\\"');
  }

  window.Sim3DPanel = Sim3DPanel;
})();
