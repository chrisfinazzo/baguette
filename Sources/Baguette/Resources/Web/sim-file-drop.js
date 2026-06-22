// sim-file-drop.js — drag-and-drop files onto the device.
//
// Hangs `window.SimFileDrop` on the global so sim-native.js can make the
// focus view accept dropped files: an .ipa/.app installs an app, an
// image/video lands in Photos.
//
// This is a dumb sender. For each dropped file it POSTs the raw bytes to
// `POST /simulators/<udid>/files?name=<filename>` and shows the result.
// All domain logic — which file is an app vs media, which simctl verb,
// the "no home on a simulator" rejection — lives on the Swift side
// (`Server.addFile`, `AppBundle`, `MediaItem`). See
// docs/features/file-upload.md.

(function () {
  'use strict';

  // One-time injected styles for the drop overlay + toasts.
  function ensureStyles() {
    if (document.getElementById('simFileDropStyles')) return;
    const s = document.createElement('style');
    s.id = 'simFileDropStyles';
    s.textContent = `
      .sfd-host { position: relative; }
      .sfd-overlay {
        position: absolute; inset: 0; z-index: 40;
        display: none; align-items: center; justify-content: center;
        background: rgba(20, 22, 28, 0.55); backdrop-filter: blur(2px);
        border: 2.5px dashed rgba(255,255,255,0.7); border-radius: 18px;
        font: 600 15px/1.3 -apple-system, system-ui, sans-serif; color: #fff;
        text-align: center; pointer-events: none; padding: 24px;
      }
      .sfd-host.sfd-dragging .sfd-overlay { display: flex; }
      .sfd-toasts {
        position: absolute; left: 50%; bottom: 18px; transform: translateX(-50%);
        z-index: 41; display: flex; flex-direction: column; gap: 8px;
        align-items: center; pointer-events: none;
      }
      .sfd-toast {
        font: 500 13px/1.35 -apple-system, system-ui, sans-serif; color: #fff;
        background: rgba(28,30,38,0.92); border: 1px solid rgba(255,255,255,0.12);
        border-radius: 11px; padding: 8px 13px; max-width: 320px;
        box-shadow: 0 6px 22px rgba(0,0,0,0.35); transition: opacity .3s;
      }
      .sfd-toast.sfd-ok   { border-color: rgba(80,200,120,0.55); }
      .sfd-toast.sfd-err  { border-color: rgba(235,110,110,0.6); }
      .sfd-toast.sfd-busy { border-color: rgba(120,160,235,0.55); }
    `;
    document.head.appendChild(s);
  }

  function attach(el, opts) {
    if (!el || !opts || !opts.udid) return;
    const udid = opts.udid;
    ensureStyles();
    el.classList.add('sfd-host');

    const overlay = document.createElement('div');
    overlay.className = 'sfd-overlay';
    overlay.textContent = 'Drop to add to device — apps install, photos & videos go to Photos';
    el.appendChild(overlay);

    const toasts = document.createElement('div');
    toasts.className = 'sfd-toasts';
    el.appendChild(toasts);

    function toast(msg, kind) {
      const t = document.createElement('div');
      t.className = 'sfd-toast sfd-' + (kind || 'busy');
      t.textContent = msg;
      toasts.appendChild(t);
      if (kind !== 'busy') {
        setTimeout(() => { t.style.opacity = '0'; }, 3200);
        setTimeout(() => { t.remove(); }, 3600);
      }
      return t;
    }

    // dragenter/over must preventDefault for `drop` to fire. A depth
    // counter avoids flicker as the cursor crosses child elements.
    let depth = 0;
    el.addEventListener('dragenter', (e) => {
      if (!e.dataTransfer || Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') < 0) return;
      e.preventDefault();
      depth++;
      el.classList.add('sfd-dragging');
    });
    el.addEventListener('dragover', (e) => {
      if (!e.dataTransfer || Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') < 0) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    });
    el.addEventListener('dragleave', () => {
      depth = Math.max(0, depth - 1);
      if (depth === 0) el.classList.remove('sfd-dragging');
    });
    el.addEventListener('drop', (e) => {
      e.preventDefault();
      depth = 0;
      el.classList.remove('sfd-dragging');
      const files = e.dataTransfer && e.dataTransfer.files;
      if (!files || !files.length) return;
      for (let i = 0; i < files.length; i++) upload(files[i]);
    });

    async function upload(file) {
      const busy = toast('Adding ' + file.name + '…', 'busy');
      try {
        const res = await fetch(
          '/simulators/' + encodeURIComponent(udid) +
            '/files?name=' + encodeURIComponent(file.name),
          { method: 'POST', body: file }
        );
        busy.remove();
        let body = {};
        try { body = await res.json(); } catch (_) { /* non-JSON */ }
        if (res.ok && body.ok) {
          const what = body.kind === 'app' ? 'Installed' : 'Added';
          toast(what + ' ' + file.name, 'ok');
        } else {
          toast(file.name + ': ' + (body.error || ('HTTP ' + res.status)), 'err');
        }
      } catch (err) {
        busy.remove();
        toast(file.name + ': ' + (err && err.message ? err.message : 'upload failed'), 'err');
      }
    }
  }

  window.SimFileDrop = { attach };
})();
