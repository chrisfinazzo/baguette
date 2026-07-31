// sim-3d.js — live server-rendered 3D simulator stream.
(function () {
  'use strict';

  function Sim3DPanel() {
    this.host = null;
    this.stage = null;
    this.canvas = null;
    this.context = null;
    this.udid = '';
    this.model = null;
    this.socket = null;
    this.decoder = null;
    this.format = 'mjpeg';
    this.rotation = { x: -8, y: 18, z: 0 };
    this.zoom = 1;
    this.mode = 'pose';
    this.variants = {};
    this.deviceSize = { width: 1, height: 1 };
    this.onFps = null;
    this.frames = 0;
    this.fpsStarted = 0;
    this.pointer = null;
    this.restartTimer = null;
    this.cameraFrame = 0;
    this.generation = 0;
  }

  Sim3DPanel.prototype.attach = async function (host, stage, udid, options) {
    this.host = host;
    this.stage = stage;
    this.udid = udid;
    options = options || {};
    this.deviceSize = options.deviceSize || this.deviceSize;
    this.onFps = options.onFps || null;
    this.format = options.format === 'avcc' ? 'avcc' : 'mjpeg';
    this.renderLoading('Loading 3D model…');
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
      this.mountStage();
      this.start();
    } catch (error) {
      this.renderError(error.message || String(error));
    }
  };

  Sim3DPanel.prototype.mountStage = function () {
    if (!this.stage) return;
    this.stage.innerHTML =
        '<canvas class="r3d-live-canvas" aria-label="Live 3D simulator"></canvas>' +
        '<div class="r3d-live-state" data-role="live-state">' +
          '<span class="r3d-spinner"></span><span>Loading model…</span>' +
        '</div>';
    this.canvas = this.stage.querySelector('canvas');
    this.context = this.canvas.getContext('2d', { alpha: false });
    this.stage.addEventListener('pointerdown', (event) => this.pointerDown(event));
    this.stage.addEventListener('pointermove', (event) => this.pointerMove(event));
    this.stage.addEventListener('pointerup', (event) => this.pointerUp(event));
    this.stage.addEventListener('pointercancel', () => { this.pointer = null; });
    this.stage.addEventListener('dblclick', () => this.resetCamera());
    this.stage.addEventListener('wheel', (event) => this.zoomCamera(event), {
      passive: false,
    });
  };

  Sim3DPanel.prototype.start = function () {
    this.stop();
    if (!this.canvas || !this.model) return;
    this.frames = 0;
    this.fpsStarted = 0;
    const generation = ++this.generation;
    const size = this.outputSize();
    const params = new URLSearchParams({
      rotation: [this.rotation.x, this.rotation.y, this.rotation.z].join(','),
      width: String(size.width),
      height: String(size.height),
      fit: 'cover',
      background: '#eef1f5',
    });
    Object.keys(this.variants).forEach((set) => {
      params.append('variant', set + ':' + this.variants[set]);
    });
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const path = '/simulators/' + encodeURIComponent(this.udid) +
        '/stream.3d.' + this.format + '?' + params.toString();
    const socket = new WebSocket(scheme + '//' + location.host + path);
    socket.binaryType = 'arraybuffer';
    this.socket = socket;
    this.decoder = window.FrameDecoder.create(this.format, {
      onFrame: (frame) => this.paint(frame, generation),
      onLog: (message, error) => {
        if (error && generation === this.generation) {
          this.setState(message || '3D decode failed', false, true);
        }
      },
    });
    this.setState('Loading model…', true);
    socket.addEventListener('open', () => {
      this.setState('Waiting for frame…', true);
      this.sendCamera();
    });
    socket.addEventListener('message', (event) => {
      if (generation !== this.generation) return;
      if (typeof event.data === 'string') {
        let envelope = null;
        try { envelope = JSON.parse(event.data); } catch (_) {}
        if (envelope && envelope.error) this.setState(envelope.error, false, true);
      }
      this.decoder.feed(event);
    });
    socket.addEventListener('close', () => {
      if (generation === this.generation && this.canvas &&
          !this.canvas.hasAttribute('data-painted')) {
        this.setState('3D stream disconnected', false, true);
      }
    });
    socket.addEventListener('error', () => {
      if (generation === this.generation) this.setState('3D stream failed', false, true);
    });
  };

  Sim3DPanel.prototype.stop = function () {
    this.generation += 1;
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = null;
    if (this.cameraFrame) cancelAnimationFrame(this.cameraFrame);
    this.cameraFrame = 0;
    if (this.socket) {
      try { this.socket.close(); } catch (_) {}
    }
    this.socket = null;
    if (this.decoder) {
      this.decoder.dispose();
      this.decoder = null;
    }
  };

  Sim3DPanel.prototype.paint = function (frame, generation) {
    if (generation !== this.generation || !this.canvas) {
      if (frame && typeof frame.close === 'function') frame.close();
      return;
    }
    const width = frame.displayWidth || frame.width;
    const height = frame.displayHeight || frame.height;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.context.drawImage(frame, 0, 0);
    if (typeof frame.close === 'function') frame.close();
    this.setState('', false);
    this.countFrame();
  };

  Sim3DPanel.prototype.setFormat = function (format) {
    const next = format === 'avcc' ? 'avcc' : 'mjpeg';
    if (this.format === next) return;
    this.format = next;
    this.renderControls();
    this.start();
  };

  Sim3DPanel.prototype.detach = function () {
    this.stop();
    if (this.host) this.host.innerHTML = '';
    if (this.stage) this.stage.innerHTML = '';
    this.host = null;
    this.stage = null;
    this.canvas = null;
    this.context = null;
  };

  Sim3DPanel.prototype.send = function (payload) {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(payload));
      return true;
    }
    return false;
  };

  Sim3DPanel.prototype.scheduleRestart = function (delay) {
    if (this.restartTimer) clearTimeout(this.restartTimer);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start();
    }, delay == null ? 80 : delay);
  };

  Sim3DPanel.prototype.renderLoading = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty"><span class="r3d-spinner"></span><span></span></div>';
    this.host.querySelector('.r3d-empty span:last-child').textContent = message;
  };

  Sim3DPanel.prototype.renderError = function (message) {
    if (!this.host) return;
    this.host.innerHTML =
        '<div class="r3d-empty r3d-error"><strong>3D stream unavailable</strong>' +
        '<span data-role="message"></span>' +
        '<button type="button" data-role="retry">Try Again</button></div>';
    this.host.querySelector('[data-role="message"]').textContent = message;
    this.host.querySelector('[data-role="retry"]').addEventListener(
        'click', () => this.attach(this.host, this.stage, this.udid, {
          deviceSize: this.deviceSize, onFps: this.onFps, format: this.format,
        })
    );
  };

  Sim3DPanel.prototype.renderControls = function () {
    const variants = (this.model.variantSets || []).map((set) => {
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
        '<div class="r3d-live-summary"><strong>' +
          escapeHTML(this.model.displayName) + '</strong><span>Live ' +
          escapeHTML(this.format.toUpperCase()) + '</span></div>' +
        variants +
        '<section class="r3d-section"><label>Camera</label>' +
          '<div class="r3d-presets">' +
            '<button type="button" class="r3d-mode active" data-mode="pose">Pose</button>' +
            '<button type="button" class="r3d-mode" data-mode="interact">Interact</button>' +
          '</div>' +
          '<div class="r3d-presets">' +
            '<button type="button" data-preset="-8,18,0">Hero</button>' +
            '<button type="button" data-preset="0,0,0">Front</button>' +
            '<button type="button" data-preset="0,38,0">Side</button>' +
            '<button type="button" data-preset="-28,28,0">Top</button>' +
          '</div>' +
          rangeRow('x', 'Tilt', -45, 45, this.rotation.x) +
          rangeRow('y', 'Turn', -80, 80, this.rotation.y) +
          rangeRow('z', 'Roll', -45, 45, this.rotation.z) +
        '</section>' +
        '<div class="r3d-footer">' +
          '<button type="button" class="r3d-download" data-role="download">Save Frame</button>' +
        '</div>';

    this.host.querySelectorAll('.r3d-choice').forEach((button) => {
      button.classList.toggle(
          'active', this.variants[button.dataset.set] === button.dataset.choice
      );
      button.addEventListener('click', () => {
        this.variants[button.dataset.set] = button.dataset.choice;
        this.host.querySelectorAll(
            '.r3d-choice[data-set="' + cssEscape(button.dataset.set) + '"]'
        ).forEach((candidate) => candidate.classList.toggle(
            'active', candidate.dataset.choice === button.dataset.choice
        ));
        this.scheduleRestart(0);
      });
    });
    this.host.querySelectorAll('[data-axis]').forEach((range) => {
      const output = this.host.querySelector(
          '[data-value="' + range.dataset.axis + '"]'
      );
      range.addEventListener('input', () => {
        this.rotation[range.dataset.axis] = Number(range.value);
        if (output) output.textContent = range.value + '°';
        this.sendCamera();
      });
    });
    this.host.querySelectorAll('[data-preset]').forEach((button) => {
      button.addEventListener('click', () => {
        const values = button.dataset.preset.split(',').map(Number);
        ['x', 'y', 'z'].forEach((axis, index) => {
          this.rotation[axis] = values[index];
          const range = this.host.querySelector('[data-axis="' + axis + '"]');
          const output = this.host.querySelector('[data-value="' + axis + '"]');
          if (range) range.value = String(values[index]);
          if (output) output.textContent = values[index] + '°';
        });
        this.sendCamera();
      });
    });
    this.host.querySelectorAll('[data-mode]').forEach((button) => {
      button.addEventListener('click', () => {
        this.mode = button.dataset.mode;
        this.host.querySelectorAll('[data-mode]').forEach((candidate) => {
          candidate.classList.toggle('active', candidate.dataset.mode === this.mode);
        });
      });
    });
    this.host.querySelector('[data-role="download"]').addEventListener(
        'click', () => this.download()
    );
  };

  Sim3DPanel.prototype.outputSize = function () {
    const rect = this.stage ? this.stage.getBoundingClientRect() : null;
    const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
    return {
      width: Math.max(480, Math.min(1600, Math.round((rect && rect.width || 960) * ratio))),
      height: Math.max(480, Math.min(1600, Math.round((rect && rect.height || 960) * ratio))),
    };
  };

  Sim3DPanel.prototype.setState = function (message, busy, error) {
    if (!this.stage) return;
    const state = this.stage.querySelector('[data-role="live-state"]');
    if (!state) return;
    state.hidden = !message;
    state.toggleAttribute('data-error', !!error);
    const label = state.querySelector('span:last-child');
    if (label) label.textContent = message || '';
    const spinner = state.querySelector('.r3d-spinner');
    if (spinner) spinner.hidden = !busy;
    if (!message && this.canvas) this.canvas.setAttribute('data-painted', '');
  };

  Sim3DPanel.prototype.countFrame = function () {
    const now = performance.now();
    if (!this.fpsStarted || now - this.fpsStarted > 2000) {
      this.fpsStarted = now;
      this.frames = 1;
      return;
    }
    this.frames += 1;
    const elapsed = now - this.fpsStarted;
    if (elapsed >= 1000) {
      const fps = Math.round(this.frames * 1000 / elapsed);
      if (this.onFps && fps > 0) this.onFps(fps);
      this.frames = 0;
      this.fpsStarted = now;
    }
  };

  Sim3DPanel.prototype.pointerDown = function (event) {
    if (!this.canvas || !this.canvas.hasAttribute('data-painted')) return;
    this.stage.setPointerCapture(event.pointerId);
    this.pointer = {
      x: event.clientX, y: event.clientY, time: performance.now(),
      rotation: { x: this.rotation.x, y: this.rotation.y, z: this.rotation.z },
    };
  };

  Sim3DPanel.prototype.pointerMove = function (event) {
    if (!this.pointer || this.mode !== 'pose') return;
    this.rotation.x = Math.max(-80, Math.min(80,
        this.pointer.rotation.x + (event.clientY - this.pointer.y) * 0.35));
    this.rotation.y = Math.max(-180, Math.min(180,
        this.pointer.rotation.y + (event.clientX - this.pointer.x) * 0.35));
    this.syncCameraControls();
    this.sendCamera();
  };

  Sim3DPanel.prototype.pointerUp = function (event) {
    if (!this.pointer) return;
    const start = this.pointer;
    this.pointer = null;
    if (this.mode === 'pose') return;
    const rect = this.canvas.getBoundingClientRect();
    const point = (x, y) => ({
      x: Math.max(0, Math.min(this.deviceSize.width,
          (x - rect.left) / rect.width * this.deviceSize.width)),
      y: Math.max(0, Math.min(this.deviceSize.height,
          (y - rect.top) / rect.height * this.deviceSize.height)),
    });
    const a = point(start.x, start.y);
    const b = point(event.clientX, event.clientY);
    const distance = Math.hypot(b.x - a.x, b.y - a.y);
    if (distance < 8) {
      this.send({
        type: 'tap', x: b.x, y: b.y,
        width: this.deviceSize.width, height: this.deviceSize.height,
      });
    } else {
      this.send({
        type: 'swipe',
        startX: a.x, startY: a.y, endX: b.x, endY: b.y,
        width: this.deviceSize.width, height: this.deviceSize.height,
        duration: Math.max(0.1, (performance.now() - start.time) / 1000),
      });
    }
  };

  Sim3DPanel.prototype.sendCamera = function () {
    if (this.cameraFrame) return;
    this.cameraFrame = requestAnimationFrame(() => {
      this.cameraFrame = 0;
      this.send({
        type: 'set_3d_camera',
        rotation: this.rotation,
        zoom: this.zoom,
      });
    });
  };

  Sim3DPanel.prototype.syncCameraControls = function () {
    ['x', 'y', 'z'].forEach((axis) => {
      const value = Math.round(this.rotation[axis]);
      const range = this.host && this.host.querySelector('[data-axis="' + axis + '"]');
      const output = this.host && this.host.querySelector('[data-value="' + axis + '"]');
      if (range) range.value = String(value);
      if (output) output.textContent = value + '°';
    });
  };

  Sim3DPanel.prototype.resetCamera = function () {
    this.rotation = { x: 0, y: 0, z: 0 };
    this.zoom = 1;
    this.syncCameraControls();
    this.sendCamera();
  };

  Sim3DPanel.prototype.zoomCamera = function (event) {
    if (this.mode !== 'pose') return;
    event.preventDefault();
    this.zoom = Math.max(0.5, Math.min(3,
        this.zoom * Math.exp(-event.deltaY * 0.0015)));
    this.sendCamera();
  };

  Sim3DPanel.prototype.download = function () {
    if (!this.canvas || !this.canvas.hasAttribute('data-painted')) return;
    const link = document.createElement('a');
    link.href = this.canvas.toDataURL('image/png');
    link.download = (this.model.id || 'device') + '-live-3d.png';
    link.click();
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
