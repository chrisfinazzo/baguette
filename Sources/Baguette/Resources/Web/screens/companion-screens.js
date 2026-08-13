// CompanionScreens — the extra screens a simulator can show beside its
// own glass, as one value. Built from
// `/simulators/<udid>/companion-screens.json`; the rail asks it what to
// draw rather than reaching into the payload and re-deriving the same
// three questions at every call site.
//
// Absence is the interesting case, not an error: a device usually has
// neither of these, and the rail's job then is to say how to get one.
// So every screen always gets an entry, and the entry carries its own
// status and its own instructions.
//
//   const screens = CompanionScreens.from(payload);
//   screens.entries()   // always one per kind, stable order
//   screens.openable()  // only the ones a click could show right now
//
// No DOM, no globals: plain payload in, plain values out.
(function (root) {
  'use strict';

  // Each screen's fixed identity — everything that doesn't depend on
  // what the host currently reports. `absent` is what the user reads
  // when the screen isn't there, and it is the whole point of the
  // entry existing in that case.
  const KINDS = [
    {
      id: 'external',
      // "External display", not "CarPlay". The plane binds whatever the
      // External Displays menu attached — the CarPlay entry is only one
      // of several resolutions it offers, and on some runtimes it is the
      // one that doesn't work while the others do. Promising CarPlay and
      // showing an 800×480 TVOut under that name is a small lie the rail
      // has no reason to tell.
      label: 'External display',
      absentTitle: 'No external display to stream',
      // Two different situations end up here and the steps have to cover
      // both, because from the browser they look identical. Either the
      // device has no CarPlay screen at all, or it has one that is
      // registered with no framebuffer behind it — an enable whose host
      // window has since gone. The second is the confusing one: the host
      // still lists the screen by name, but nothing composites to it and
      // even `simctl screenshot` times out waiting for surfaces. The
      // Disabled→CarPlay cycle is what clears it.
      instructions: [
        'Open Simulator.app and bring this device’s window to the front.',
        'Choose I/O → External Displays, then any entry — CarPlay, or one of the plain resolutions.',
        'If it was already set to that entry, pick Disabled first and choose it again — a display left registered without its window has no framebuffer to stream.',
        'Some runtimes attach the plain resolutions but not CarPlay. If CarPlay does nothing, try one of the others.',
        'Leave that window open, then press Check again.',
      ],
    },
    {
      id: 'watch',
      label: 'Apple Watch',
      absentTitle: 'No paired watch',
      instructions: [
        'Create a watch simulator in Xcode → Windows → Devices and Simulators.',
        'Pair it to this phone: xcrun simctl pair <watch-udid> <this-udid>',
        'Come back here and reload — a paired watch shows up on its own.',
      ],
    },
  ];

  /**
   * One companion screen, as the rail needs it.
   *
   * `status` is the only thing a caller has to branch on:
   *   'ready'      — attached and streamable; open it
   *   'needs-boot' — it exists but its device is not running
   *   'absent'     — not there; show `instructions`
   */
  class CompanionScreen {
    constructor(kind, report) {
      this.id = kind.id;
      this.absentTitle = kind.absentTitle;
      this.instructions = kind.instructions;
      this._kind = kind;
      this._report = report && typeof report === 'object' ? report : {};
    }

    /** The watch is a device of its own, so it is named after itself. */
    get label() {
      return this._report.name || this._kind.label;
    }

    /**
     * The device this screen streams from. Only the watch has one — a
     * CarPlay display is a second plane of the phone we are already
     * looking at, reached with `?display=carplay` on the same udid.
     */
    get udid() {
      return this._report.udid || null;
    }

    get status() {
      if (!this._report.available) return 'absent';
      // A watch that says it is available without saying which device
      // it is cannot be streamed, so it is no better than absent — and
      // pairing instructions are the useful thing to show.
      if (this.id === 'watch') {
        if (!this._report.udid) return 'absent';
        return this._report.state === 'Booted' ? 'ready' : 'needs-boot';
      }
      return 'ready';
    }

    get canOpen() {
      return this.status === 'ready';
    }

    /**
     * One line under the label — what is going on with this screen.
     *
     * An attached external reports its size, because that is the only
     * thing distinguishing the display you asked for from the one the
     * menu actually gave you.
     */
    get detail() {
      switch (this.status) {
        case 'ready':
          if (this.id === 'watch') return 'Booted';
          return this.size ? this.size.width + ' × ' + this.size.height : 'Attached';
        case 'needs-boot': return 'Not booted';
        default:           return this.absentTitle;
      }
    }

    /** The bound display's pixel size, when the host reported one. */
    get size() {
      const { width, height } = this._report;
      if (!width || !height) return null;
      return { width, height };
    }
  }

  class CompanionScreens {
    /** @param {object|null} payload  `/simulators/<udid>/companion-screens.json` */
    constructor(payload) {
      this.payload = payload && typeof payload === 'object' ? payload : {};
    }

    static from(payload) {
      return new CompanionScreens(payload);
    }

    /** One entry per kind, always, in a stable order. */
    entries() {
      return KINDS.map((kind) => new CompanionScreen(kind, this.payload[kind.id]));
    }

    /** Just the screens a click could show right now. */
    openable() {
      return this.entries().filter((entry) => entry.canOpen);
    }
  }

  root.Baguette = root.Baguette || {};
  root.Baguette._CompanionScreens = CompanionScreens;
  root.Baguette._CompanionScreen = CompanionScreen;
})(window);
