<p align="center">
  <img src="assets/logo.png" alt="Baguette" width="240">
</p>

<h1 align="center">Baguette</h1>

<p align="center"><em>Bon appétit.</em></p>

<p align="center">
  Headless iOS Simulator manager + host-side input injection for iOS 26.
</p>

<p align="center">
  <a href="https://github.com/tddworks/baguette/actions/workflows/ci.yml"><img src="https://github.com/tddworks/baguette/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://codecov.io/gh/tddworks/baguette"><img src="https://codecov.io/gh/tddworks/baguette/branch/main/graph/badge.svg" alt="Coverage"></a>
  <a href="https://github.com/tddworks/baguette/releases/latest"><img src="https://img.shields.io/github/v/release/tddworks/baguette?sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tddworks/baguette" alt="License"></a>
  <img src="https://img.shields.io/badge/Swift-6.1-orange?logo=swift" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/macOS-15%2B-blue?logo=apple" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Xcode-26-1575F9?logo=xcode" alt="Xcode 26">
</p>

A single Swift CLI — **`baguette`** — that creates / boots / shuts down
simulator devices, streams their screens at 60 fps, and injects taps
/ swipes / multi-finger touches without booting the Simulator.app GUI.
Optionally serves a self-contained web UI on `localhost` so you can
control any booted simulator from a browser.

## Demo

https://github.com/user-attachments/assets/e904413f-16bb-4b3d-86d5-162333403cee

https://github.com/user-attachments/assets/c49c9f4b-0e4b-47ea-9272-3223b1ac7739

https://github.com/user-attachments/assets/65dc62ee-f0c7-48fb-9c57-5bd267c8c02f

> The raw clip lives at [`assets/demo.mp4`](assets/demo.mp4) — drag
> it into a GitHub web edit of this README to upload as a CDN-hosted
> video and replace the line above with the auto-generated URL.

- **Frame streaming** — MJPEG or H.264 / AVCC over stdout or WebSocket.
  Runtime-tunable bitrate / fps / scale.
- **Host-HID input** — taps / swipes / streaming 1- and 2-finger gestures /
  home, lock, power, action, volume buttons / Mac keyboard / scroll wheel,
  all through SimulatorKit's 9-argument
  `IndigoHIDMessageForMouseNSEvent` from Xcode 26's preview-kit. No dylib
  injection, no `DYLD_INSERT_LIBRARIES`, no per-app priming.
- **Accessibility tree** — `baguette describe-ui` returns the on-screen
  AX tree as JSON: per-node `role`, `label`, `value`, `identifier`, and
  `frame` in the same device-point coordinates as `tap` / `swipe`. Hit-test
  mode (`--x --y`) returns the topmost node under a coordinate. Powered by
  the private `AccessibilityPlatformTranslation` framework with a
  `bridgeTokenDelegate` we install ourselves to make the dispatcher work
  out of Simulator.app.
- **Live unified-log stream** — `baguette logs --udid <X>` streams the
  booted simulator's `os_log` output line-by-line to stdout; `WS
/simulators/:udid/logs` does the same to a browser. Predicate /
  bundle-id filters supported.
- **Standalone web UI** — `baguette serve` opens `http://localhost:8421/simulators`
  with a list page, live stream, gesture input, and DeviceKit-sourced
  bezels for every simulator family.
- **Device farm** — `http://localhost:8421/farm` is an interactive
  multi-device dashboard. Every booted simulator streams in a wall / grid
  / list, with filtering and sorting; click a tile to focus it for
  full-quality streaming + gesture and hardware-button input through the
  same `GestureDispatcher` → `IndigoHIDInput` pipeline as the CLI.
- **TDD non-negotiable, layered, mock-injected** — bounded-context
  Domain / Infrastructure / App split; ~290 Swift Testing cases backed
  by auto-generated `MockXxx` fakes for every external port (`Input`,
  `Screen`, `Accessibility`, `LogStream`, `Chromes`, `DeviceHost`).
  Adapters take `any DeviceHost` rather than the concrete
  `CoreSimulators` so error-path branches are unit-tested without a
  booted sim. `swift test` requires no simulator at all.

## Install

```bash
brew install tddworks/tap/baguette
```

Apple Silicon only. Requires Xcode 26 — `baguette` links against private
SimulatorKit / CoreSimulator frameworks shipped with Xcode.

## Quickstart

```bash
# Start the web UI
baguette serve

# Single-device dashboard — list, boot/shutdown, per-device stream pages
open http://localhost:8421/simulators

# Device farm — every booted simulator side-by-side, click to focus
open http://localhost:8421/farm
```

`/simulators` lists every simulator on the machine with Boot / Shutdown
buttons; click any booted device to open its Stream page — live frames,
mouse/touch input, and the DeviceKit-sourced bezel.

`/farm` is the multi-device control surface. See
[Device farm](#device-farm) below.

Headless from the terminal works too:

```bash
baguette list
baguette boot --udid <UDID>
baguette tap --udid <UDID> --x 219 --y 478 --width 438 --height 954
```

## Build from source

```bash
make           # release build via ./build.sh
swift test     # run the test suite
```

Hybrid build: SPM fetches dependencies (`ArgumentParser`, `Mockable`,
`Hummingbird`, `HummingbirdWebSocket`); `swiftc` compiles everything
with an Objective-C bridging header targeting `arm64e-apple-macos26.0`,
linking `CoreSimulator`, `SimulatorKit`, `IOSurface`, `VideoToolbox`,
`CoreGraphics`, `ImageIO` from Xcode's private frameworks.

## CLI

```
baguette <command> [options]

  list [--json]                              List devices (default + custom sets;
                                             --json emits {"running":[…],"available":[…]})
  boot     --udid <UDID>                     Boot headlessly
  shutdown --udid <UDID>                     Shutdown
  stream   --udid <UDID> [--fps 60] [--format mjpeg|avcc]
                                             Stream frames on stdout
  screenshot --udid <UDID> [--output <path>] [--quality 0.85] [--scale 1]
                                             Capture one JPEG frame
                                             (defaults to stdout)
  describe-ui --udid <UDID> [--x <px> --y <px>] [--output <path>]
                                             Dump on-screen accessibility tree
                                             as JSON (full tree or hit-test);
                                             frames are in DEVICE POINTS so
                                             they pipe straight back into a tap.
  logs --udid <UDID> [--level info|debug|default]
                     [--style default|compact|json|ndjson|syslog]
                     [--predicate <NSPredicate>] [--bundle-id <id>]
                                             Stream the booted simulator's
                                             unified log to stdout, line by line
                                             (SIGINT to stop). Levels are the
                                             three the iOS-runtime `log stream`
                                             accepts — not host-`log`'s five.
  input    --udid <UDID>                     Read JSON gestures from stdin

  # Standalone web UI on localhost. Serves /simulators (single-device
  # dashboard) and /farm (multi-device dashboard) — both backed by the
  # same WS endpoint and HID pipeline.
  serve    [--port 8421] [--host 127.0.0.1] [--device-set <path>]

  # DeviceKit chrome / bezel data.
  chrome layout    --udid <UDID>             Print bezel layout JSON
  chrome composite --udid <UDID>             Write composite PNG to stdout
  chrome layout    --device-name "iPhone 17 Pro"
  chrome composite --device-name "iPhone 17 Pro"

  # One-shot gestures — same HID path as `input`, one gesture per
  # invocation. Coordinates are in DEVICE POINTS; `width` / `height`
  # are the simulator's screen size in points.
  tap     --udid … --x … --y … --width … --height … [--duration 0.05]
  swipe   --udid … --startX … --startY … --endX … --endY … --width … --height …
  pinch   --udid … --cx … --cy … --startSpread … --endSpread … --width … --height …
  pan     --udid … --x1 … --y1 … --x2 … --y2 … --dx … --dy … --width … --height …
  press   --udid … --button home|lock
```

## `baguette serve` — the web UI

```bash
baguette serve --port 8421
# [baguette] listening on http://127.0.0.1:8421/simulators
```

Open `http://localhost:8421/simulators` in any browser. You get the
device list (RUNNING / AVAILABLE sections), Boot / Shutdown buttons,
and a Stream page per device with live frames + gesture input + the
DeviceKit-sourced bezel.

The HTML is editable on disk — `Sources/Baguette/Resources/Web/sim.html`
opens directly in any browser via `file://` (preview mode), and points
to its sibling `.js` files. Set `BAGUETTE_WEB_DIR` to override the
served root for live-iteration without rebuilding.

### Routes (single resource tree, no `/api/` prefix)

| Method | Path                                                        | Backed by                                                                    |
| ------ | ----------------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------- |
| `GET`  | `/`                                                         | 302 → `/simulators`                                                          |
| `GET`  | `/simulators`                                               | list HTML                                                                    |
| `GET`  | `/simulators.json`                                          | list JSON `{running, available}`                                             |
| `GET`  | `/simulators/:udid`                                         | stream HTML                                                                  |
| `POST` | `/simulators/:udid/boot`                                    | `simulator.boot()`                                                           |
| `POST` | `/simulators/:udid/shutdown`                                | `simulator.shutdown()`                                                       |
| `GET`  | `/simulators/:udid/chrome.json`                             | DeviceKit bezel layout                                                       |
| `GET`  | `/simulators/:udid/bezel.png`                               | rasterized bezel PNG                                                         |
| `GET`  | `/simulators/:udid/screenshot.jpg`                          | one-shot JPEG of the framebuffer (`?quality=&scale=`)                        |
| `WS`   | `/simulators/:udid/stream?format=mjpeg                      | avcc`                                                                        | live frames + control + input + `describe_ui` |
| `WS`   | `/simulators/:udid/logs?level=&style=&predicate=&bundleId=` | live unified-log stream (one `{"type":"log","line":…}` text frame per entry) |
| `GET`  | `/farm`                                                     | device-farm HTML                                                             |
| `GET`  | `/farm/:file`                                               | farm UI asset (`farm.css`, `farm-*.js`, …)                                   |
| `GET`  | `/<file>.{html,js,css}`                                     | static UI asset                                                              |

### One bidirectional WebSocket per stream

The same WS carries everything for a viewing session:

- **Server → Browser** — encoded binary frames (one per WS message).
  - MJPEG: raw JPEG bytes per frame.
  - AVCC: 1-byte tag + payload — `0x01` avcC description, `0x02` keyframe,
    `0x03` delta, `0x04` JPEG seed (renders before H.264 IDR lands).
- **Browser → Server** — text JSON, one line per message:
  - Stream control: `{"type":"set_bitrate","bps":N}` /
    `{"type":"set_fps","fps":N}` / `{"type":"set_scale","scale":N}` /
    `{"type":"force_idr"}` / `{"type":"snapshot"}`.
  - Gesture input: same wire format as `baguette input` (see below).

No `/event` POST, no UDID-keyed registry — the WS handler closure owns
the live stream + simulator handle for the duration.

## Device farm

```bash
baguette serve
open http://localhost:8421/farm
```

A multi-device dashboard for the booted simulators on the host. Every
device renders in a single page; the same WebSocket pipeline that powers
`/simulators/:udid` drives every tile.

**What it does**

- **Three view modes** — Grid (compact thumbnails), Wall (large tiles
  with bezels), and List (one-row-per-device with metadata). Toggle from
  the header.
- **Filter and sort** — by device family, OS version, run state. The
  rail on the left holds filter state across view changes.
- **Click to focus** — clicking any tile re-parents its `<canvas>` into
  a full-quality focused pane on the right. The thumbnail keeps streaming
  at low bitrate; only the focused tile pays for full-rate frames. No
  separate mirror video element — the same canvas appears in two places.
- **Input on the focused tile** — gestures, hardware buttons (home /
  lock), and the pinch overlay all round-trip through `SimInputBridge`
  → `GestureDispatcher` → `IndigoHIDInput`. Anything the CLI can drive,
  the focused tile can drive.
- **Bezels** — each tile renders with its DeviceKit bezel by default,
  with a **9-slice composition fallback** for devices without a packaged
  asset. Toggle to a raw (no-bezel) display mode from the tile menu.

**What's served**

`/farm` is a thin HTML shell at `Resources/Web/farm/farm.html` that
loads five IIFE component scripts from `/farm/<name>.js`:

| Script           | Job                                              |
| ---------------- | ------------------------------------------------ |
| `farm-views.js`  | Grid / Wall / List renderers (pure DOM)          |
| `farm-tile.js`   | `FarmTile` — per-device thumbnail StreamSession  |
| `farm-focus.js`  | `FarmFocus` — focused-device pane                |
| `farm-filter.js` | `FarmFilter` — filter state + sidebar wiring     |
| `farm-app.js`    | `FarmApp` — orchestrator (boot, fetch, dispatch) |

`BAGUETTE_WEB_DIR` overrides the served root, so you can iterate on the
farm UI without rebuilding — point it at `Sources/Baguette/Resources/Web`
on disk and reload the browser.

## Wire protocol — `baguette input`

Newline-delimited JSON on stdin → `{"ok":true}` / `{"ok":false,"error":…}`
on stdout, one ack per line.

```json
{"type":"tap",   "x":219, "y":478, "width":438, "height":954, "duration":0.05}
{"type":"swipe", "startX":219,"startY":760, "endX":219,"endY":190,
                 "width":438,"height":954, "duration":0.3}

// 1-finger streaming (phase-driven)
{"type":"touch1-down", "x":219, "y":478, "width":438,"height":954}
{"type":"touch1-move", "x":225, "y":485, "width":438,"height":954}
{"type":"touch1-up",   "x":225, "y":485, "width":438,"height":954}

// 2-finger streaming (the primary pinch / pan path for real-time gestures)
{"type":"touch2-down", "x1":175,"y1":478, "x2":263,"y2":478, "width":438,"height":954}
{"type":"touch2-move", "x1":150,"y1":478, "x2":288,"y2":478, "width":438,"height":954}
{"type":"touch2-up",   "x1":150,"y1":478, "x2":288,"y2":478, "width":438,"height":954}

// Buttons (only home / lock reach a working target on iOS 26.4)
{"type":"button", "button":"home"}
{"type":"button", "button":"lock"}

// Scroll
{"type":"scroll", "deltaX":0, "deltaY":-50}

// One-shot pinch (server interpolates 10 steps)
{"type":"pinch", "cx":219,"cy":478, "startSpread":60,"endSpread":240,
                 "width":438,"height":954, "duration":0.6}

// One-shot parallel pan of two fingers
{"type":"pan", "x1":175,"y1":478, "x2":263,"y2":478,
               "dx":0,"dy":200, "width":438,"height":954, "duration":0.5}
```

**Coordinate convention.** All `x` / `y` / `startX` / `endX` / `x1` / `x2`
are in **device points** — same units as `width` and `height`. The HID
adapter normalises internally before handing them to the C function.
A "tap at the centre of an iPhone 17 Pro Max" is `x:219, y:478` (half of
438×954), not `x:0.5, y:0.5`. The browser UI multiplies its normalized
coordinates by `width` / `height` before serialising.

### Not yet wired

- `key` / `type` — keyboard isn't on the host-HID path yet (preview-kit
  recipe still WIP). Routes through external tools today.
- `siri` button — crashes `backboardd` via every known Indigo path.

## `baguette stream` — frame streaming

```bash
baguette stream --udid <UDID> --format avcc --fps 60 | ffplay -
```

Outputs length-prefixed binary frames on stdout. AVCC carries a 1-byte
type prefix per chunk:

| Prefix | Meaning                                             |
| ------ | --------------------------------------------------- |
| `0x01` | avcC description — feed to `VideoDecoder.configure` |
| `0x02` | Keyframe (IDR) AVCC payload                         |
| `0x03` | Delta frame                                         |
| `0x04` | JPEG seed — paints before H.264 IDR lands           |

Runtime control: while streaming, write one JSON line per command to
stdin to retune without restarting.

```json
{"type":"set_bitrate","bps":4000000}
{"type":"set_fps","fps":30}
{"type":"set_scale","scale":2}
{"type":"force_idr"}
{"type":"snapshot"}
```

## `baguette chrome` — DeviceKit bezel data

```bash
baguette chrome layout --device-name "iPhone 17 Pro" | jq .
baguette chrome composite --device-name "iPhone 17 Pro" > iphone17pro.png
```

Reads Apple's own DeviceKit chrome bundles
(`/Library/Developer/DeviceKit/Chrome/`) and emits the bezel layout
JSON or rasterizes the composite PDF to PNG. The `serve` page uses
this for every simulator family — no hand-curated bezel table to keep
in sync.

## Source layout

Bounded contexts mirror across `Domain/` and `Infrastructure/` so a
feature lives in one place across both layers.

```
.
├── Makefile                          wraps build.sh
├── build.sh                          hybrid SPM + swiftc, arm64e-apple-macos26.0
├── Package.swift                     SPM manifest
│
├── Sources/Baguette/
│   ├── App/                          CLI dispatch + use-case orchestration
│   │   ├── RootCommand.swift
│   │   ├── GestureDispatcher.swift   JSON line → Gesture → Input
│   │   ├── ReconfigParser.swift      runtime stream-control parser
│   │   ├── Logger.swift
│   │   └── Commands/                 one file per CLI subcommand
│   │       (list / boot / shutdown / stream / input / serve / chrome /
│   │        screenshot / describe-ui / logs / gesture one-shots /
│   │        keyboard / press)
│   │
│   ├── Domain/                       pure Swift, no Apple private APIs
│   │   ├── Common/                   CoordinateTypes (Point, Size, Rect, Insets,
│   │   │                             HIDUsage, DeviceButton)
│   │   ├── Simulator/                Simulator value type + Simulators aggregate +
│   │   │                             DeviceHost port (the seam adapters depend on)
│   │   ├── Input/                    Input port + Gesture / GestureRegistry +
│   │   │                             Tap / Swipe / Touch1 / Touch2 / Press /
│   │   │                             Scroll / Pinch / Pan / Key / TypeText /
│   │   │                             Keyboard
│   │   ├── Screen/                   Screen port (frame source)
│   │   ├── Stream/                   Stream port + StreamConfig / StreamFormat
│   │   │                             + Envelope (MJPEG / AVCC framing)
│   │   ├── Chrome/                   Chromes aggregate + DeviceChrome /
│   │   │                             DeviceProfile (bezel layout)
│   │   ├── Accessibility/            AXNode value type + Accessibility port
│   │   │                             (on-screen UI tree)
│   │   └── Logs/                     LogFilter value type + LogStream port
│   │                                 (live unified-log feed)
│   │
│   ├── Infrastructure/               concrete @Mockable port impls (private-API
│   │                                 code lives ONLY here)
│   │   ├── Simulator/                CoreSimulators (CoreSimulator + SimulatorKit
│   │   │                             ObjC bridge); conforms to Simulators +
│   │   │                             DeviceHost
│   │   ├── Input/                    IndigoHIDInput (9-arg
│   │   │                             IndigoHIDMessageForMouseNSEvent + button +
│   │   │                             HIDArbitrary + keyboard paths)
│   │   ├── Screen/                   SimulatorKitScreen (framebuffer callbacks),
│   │   │                             ScreenSnapshot (one-shot JPEG capture)
│   │   ├── Stream/                   MJPEG / AVCC encoders, JPEG / H.264
│   │   │                             encoders, Scaler, SeedFilter, Stdout /
│   │   │                             WebSocket FrameSinks, ControlChannel
│   │   ├── Chrome/                   LiveChromes + ChromeStore /
│   │   │                             FileSystemChromeStore + PDFRasterizer
│   │   ├── Accessibility/            AXPTranslatorAccessibility (AXPTranslator +
│   │   │                             TokenDispatcher bridge for the iOS-26
│   │   │                             out-of-Simulator.app accessibility path)
│   │   ├── Logs/                     SimDeviceLogStream (shells out to
│   │   │                             `xcrun simctl spawn` for the in-sim
│   │   │                             `/usr/bin/log stream` child)
│   │   └── Server/                   Server (Hummingbird HTTP + WS) + WebRoot
│   │
│   └── Resources/Web/                static UI for `serve`
│       ├── sim.html                  list + stream entry, opens via file://
│       ├── sim-list.js               list page renderer
│       ├── sim-stream.js             stream-page orchestrator
│       ├── sim-stream.html           stream view markup
│       ├── sim-input.js              SimInput / MouseGestureSource / PinchOverlay
│       ├── sim-input-bridge.js       SimInput → baguette wire-format mapper
│       ├── sim-native.js             focus-mode (single-sim fullscreen) view
│       ├── frame-decoder.js          MJPEG / AVCC strategy
│       ├── device-frame.js           bezel + screen DOM
│       ├── stream-session.js         WebSocket + paint loop
│       ├── capture-gallery.js        screenshot fetch + thumbs
│       └── farm/                     multi-device dashboard (farm.html, farm.css,
│                                     farm-tile.js, farm-grid.js, …)
│
└── Tests/BaguetteTests/              mirrors Sources/ contexts
    ├── App/                          GestureDispatcher / ReconfigParser /
    │                                 Logger / Commands (CommandParsing,
    │                                 ChromeCommand) tests
    ├── Simulator/                    Simulator / Simulators / DeviceHost tests
    ├── Input/                        Gesture / GestureRegistry / Keyboard /
    │                                 IndigoHIDInput error-path tests
    ├── Screen/                       (none yet — Screen port covered via
    │                                 mocks in Server tests)
    ├── Stream/                       Envelope / StreamConfig / StreamFormat tests
    ├── Server/                       BezelRoutes / WebRootSubdir tests
    ├── Chrome/                       DeviceChrome / DeviceProfile / LiveChromes /
    │                                 CoreGraphicsPDFRasterizer / integration tests
    ├── Accessibility/                AXNode / Accessibility port /
    │                                 AXPTranslatorAccessibility error-path tests
    └── Logs/                         LogFilter / LogStream port /
                                      SimDeviceLogStream error-path tests
```

## Testing

**TDD is non-negotiable** — every behaviour change to a Domain or
Infrastructure type lands in a failing `@Test` under `Tests/` first,
then the smallest implementation that turns it green, then refactor.
Read `CLAUDE.md`'s "TDD is non-negotiable" pre-implementation gate
before contributing — that's the project's primary rule and it
overrides "the change is small" / "I'll add the test after".

~290 tests using **Swift Testing** (`@Suite`, `@Test`, `#expect`),
not XCTest. Chicago-school state-based: every external boundary is
an `@Mockable` protocol (`Input`, `Screen`, `Accessibility`,
`LogStream`, `Chromes`, `DeviceHost`); tests substitute
auto-generated `MockXxx` fakes, and assert on returned values rather
than recorded calls.

Adapters that talk to private SimulatorKit / CoreSimulator /
AccessibilityPlatformTranslation symbols (`IndigoHIDInput`,
`AXPTranslatorAccessibility`, `SimDeviceLogStream`,
`SimulatorKitScreen`) take `any DeviceHost` rather than the concrete
`CoreSimulators` aggregate, so their error-path branches —
`simulatorNotBooted`, idempotent `stop`, host-deallocated, etc. —
are unit-tested via `MockDeviceHost` without needing a real booted
simulator. The successful private-API call path stays
integration-only — manually smoke-tested through the CLI and serve
UI against a booted iOS sim.

```bash
swift test                                              # all tests
swift test --filter Simulators                          # one suite
swift test --filter "GestureRegistry/parses tap"        # one test
```

The `MOCKING` compilation flag is set under `.debug` only, so release
builds (via `./build.sh`) carry no mock code.

## Why this works on iOS 26.4 when older tools don't

iOS 26 changed `SimulatorHID`'s wire format. Public tools like `idb` and
`AXe` call `IndigoHIDMessageForMouseNSEvent` with the old 5-argument
signature; those messages now route to a pointer-service target that
silently drops or crashes `backboardd`. Baguette uses the **9-argument
signature from Xcode 26's preview-kit**, which routes through digitizer
target `0x32` — the target iOS 26 still honours.

That single calling-convention change is the entire difference. The
recipe is heavily commented in `Sources/Baguette/Infrastructure/Input/IndigoHIDInput.swift`,
and the layered design is documented in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
