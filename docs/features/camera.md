# Camera

Pipe a camera source into an iOS app's `AVCaptureVideoPreviewLayer`,
`AVCapturePhotoOutput`, and `UIImagePickerController` running inside
the simulator. The source can be a **live Mac webcam** (FaceTime HD,
USB, Continuity Camera), a **still image**, or a **looping video** —
the app sees it as if it were a real iOS camera — barcode scanners
scan, profile-photo uploads work, viewfinders fill — without opening
Xcode, without installing a separate menu-bar app. Point a video of a
barcode at a scanner, or a fixed headshot at a profile-photo picker,
entirely from the browser.

Two halves cooperate:

- **Mac side** (this repo, Swift): a `CameraSession` orchestrator
  driven from the browser's camera panel. It selects one of three
  frame producers by `CameraSource` — `AVCameraCapture` (webcam, off
  an `AVCaptureSession`), `ImageFileCapture` (a decoded still re-emitted
  at ~30 fps), or `VideoFileCapture` (an `AVAssetReader` looped) — and
  writes their BGRA frames into a fixed-size mmap'd file
  (`/tmp/SimCam.bgra`). File sources are downscaled to fit the canvas
  via the pure `ScaleToFit`.
- **iOS-Simulator side** (`VirtualCamera/`, vendored from
  `asc-pro/SimCam`): a small ObjC dylib that hooks AVFoundation /
  UIImagePickerController inside every simulator-launched app and
  substitutes the shared-buffer frame for the (non-existent)
  hardware camera. Loaded via `DYLD_INSERT_LIBRARIES`.

The browser is the picker; baguette is the producer; the dylib is the
consumer — and the dylib is **source-agnostic**: image and video
frames are indistinguishable from webcam frames at the shared-buffer
boundary, so adding file sources needed no dylib change. No CLI verb —
the surface is the browser's camera control card and its WebSocket.

## Entry points

- Browser camera card on `/simulators/<UDID>` (sidebar view, under
  the Camera disclosure). A source selector (Webcam / Image / Video),
  a device dropdown or a file chooser, Start/Stop, Fit/Fill, Mirror,
  live FPS.
- Wire JSON over the `/simulators/:udid/camera` WebSocket + the
  `POST /simulators/:udid/camera-source` upload route — agents can
  drive the same flow programmatically.

## Wire JSON

The browser opens `ws://<host>:<port>/simulators/<udid>/camera` and
exchanges text frames.

**Browser → server:**

```json
{ "type": "camera_list" }
{ "type": "camera_start",
  "source": "webcam",          // "webcam" | "image" | "video"; default "webcam"
  "deviceUID": "0x14600000046d0825",  // required for webcam, ignored otherwise
  "fit": "fit",                // "fit" | "fill"
  "mirror": false }
{ "type": "camera_start", "source": "image", "fit": "fit", "mirror": false }
{ "type": "camera_start", "source": "video", "fit": "fill", "mirror": false }
{ "type": "camera_stop" }
{ "type": "camera_set_flags",
  "fit": "fill",
  "mirror": true }
```

For `image` / `video` there is **no path on the wire** — the browser
uploads the file first (see the route below) and the server resolves
the staged host file for this udid. A missing `source` defaults to
`webcam`, so pre-existing clients keep working.

**Server → browser:**

```json
{ "type": "camera_devices",
  "devices": [
    { "uid": "0x14600000046d0825",
      "name": "FaceTime HD Camera",
      "isDefault": true }
  ]
}
{ "type": "camera_state",
  "ok": true,
  "phase": "streaming",        // "idle" | "streaming"
  "fps": 29.97,
  "source": "webcam",          // "webcam" | "image" | "video" while streaming
  "device": "0x14600000046d0825" }  // present only for a webcam source
{ "type": "camera_state",
  "ok": false,
  "phase": "idle",
  "fps": 0,
  "error": "Camera access denied. Open System Settings → Privacy → Camera and enable baguette." }
```

### Uploading an image / video source

```
POST /simulators/:udid/camera-source?name=<filename>
     body = raw file bytes (application/octet-stream)
     → { "ok": true, "kind": "image" }   // or "video"
```

Accepts images (`png jpg jpeg gif heic heif`) and videos
(`mov mp4 m4v`); anything else is refused `415` before the body is
read. Unlike `/files` (consumed synchronously by `simctl`), the bytes
are staged into a **persistent per-udid slot** because the camera
WebSocket streams them *later* — a new upload replaces the previous
one, and the slot is cleared when the camera socket closes. The
browser never sends a host path; `camera_start` just names the
`source` kind and the server reads the staged file. `?name=` is
reduced to its last path component, so it can't escape the slot.

`camera_devices` lands once on connect and again after every
`camera_list`. `camera_state` lands after every `camera_start` /
`camera_stop` / `camera_set_flags`.

## Pipeline

```
   Browser              Server (baguette)                         iOS Simulator
┌────────────┐  WS    ┌────────────────────────┐               ┌──────────────────┐
│ sim-camera │◀─────▶│ /simulators/:udid/camera │               │ AVCaptureVideo   │
│ .js (card) │  JSON  │  CameraSession (state) │               │ PreviewLayer .   │
└────────────┘        │   ├─ AVCameraCapture   │               │  setSession:     │
                      │   │   (BGRAConverter)  │               │  hook  ▲         │
                      │   ├─ SharedMemoryFrame │               │        │         │
                      │   │   Sink (mmap)     ─┼───────────────┼──▶ /tmp/SimCam   │
                      │   │                    │  24-byte hdr  │   .bgra (read)   │
                      │   └─ SimctlSimulator   │  + BGRA       │        │         │
                      │       Injection ──────▶│  launchctl    │  VirtualCamera   │
                      └────────────────────────┘  setenv       │    .dylib        │
                                                  DYLD_INSERT  │  (DisplayLink)   │
                                                  _LIBRARIES   └──────────────────┘
```

### Mac side (this repo)

- `Domain/Camera/` — pure value types and `@Mockable` collaborators:
  - `CameraDevice` — `{uid, name, isDefault}`, structurally equal.
  - `CameraFrame` — BGRA bytes + dims + sequence + timestamp,
    validated on construction (rejects oversized frames or
    mismatched pixel data length).
  - `CameraFlags` — `{fillGravity, mirror}`. `.packed() -> UInt32`
    matches the dylib's `kSimCamFlag*` bit layout.
  - `SharedFrameLayout` — header offsets + canvas cap (1280×1280).
    Static `encodeHeader(...) -> [UInt8]` is little-endian and
    byte-for-byte tested.
  - `BGRAConverter` — pure factory that strips row-padding from a
    `CVPixelBuffer` base address into a tightly packed `CameraFrame`.
  - `CameraSession` — `@MainActor` orchestrator. Drives three
    collaborators (`CameraCapture`, `CameraFrameSink`,
    `SimulatorInjection`). State: `.idle | .streaming(deviceUID:)`.
  - `CameraMessage` — pure parser for the inbound WS envelope.
- `Infrastructure/Camera/`:
  - `AVCameras` — one-shot enumeration via
    `AVCaptureDevice.DiscoverySession`.
  - `AVCameraCapture` — `CameraCapture` orchestrator that converts
    raw BGRA frames into `CameraFrame`s with monotonic sequence
    numbers; depends on a `VideoCapture` collaborator. Unit-tested.
  - `HostVideoCapture` — thin (~80 LOC) `AVCaptureSession` wrapper.
    Integration-only.
  - `SharedMemoryFrameSink` — mmap-backed writer; rewrites the
    24-byte header + pixels and `msync(MS_SYNC)`s on every frame.
  - `SimctlSimulatorInjection` — runs `xcrun simctl spawn <udid>
    launchctl setenv DYLD_INSERT_LIBRARIES <dylibPath>`. Uses the
    existing `Subprocess` collaborator → 100% unit-tested.
  - `VirtualCameraInstaller` — resolves the bundled
    `VirtualCamera.dylib` from `Bundle.module`, sha256-keys it, and
    copies into `~/Library/Application Support/Baguette/builds/<sha12>/`.

### iOS-Simulator side (`VirtualCamera/`)

Vendored under `VirtualCamera/`. Internal symbols retain the SimCam
prefix to keep upstream re-syncs diff-friendly; see
`VirtualCamera/VENDORED_FROM.md`. The dylib:

- Hooks `-[AVCaptureVideoPreviewLayer setSession:]` and attaches a
  `CADisplayLink` driver that pushes the latest BGRA frame from
  `/tmp/SimCam.bgra` into the layer's `contents`.
- Hooks `-[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]`
  and synthesises a delegate sequence from the latest shared frame
  (still capture works without a real camera).
- Hooks `+[UIImagePickerController isSourceTypeAvailable:]` to
  report `.camera` as available; walks the picker's view tree on
  `viewDidAppear:` and intercepts the disabled-shutter delegate so
  the simulator's picker actually delivers a photo on tap.

## Dylib installation flow

1. `build.sh` runs `VirtualCamera/build.sh` first → produces
   `VirtualCamera/VirtualCamera.dylib` (fat: arm64 + x86_64,
   linker-signed adhoc, install-name `@rpath/VirtualCamera.dylib`).
2. The artifact is copied into
   `Sources/Baguette/Resources/VirtualCamera/VirtualCamera.dylib` so
   SPM bundles it as a `.copy` resource.
3. First time `camera_start` lands on the WS,
   `VirtualCameraInstaller.installIfNeeded()` reads the bundled
   bytes, computes `sha256(bytes).prefix(12)`, and copies into
   `~/Library/Application Support/Baguette/builds/<sha12>/VirtualCamera.dylib`.
   Idempotent — if the file already exists at that path we trust
   its contents (the path itself is sha-keyed).
4. `SimctlSimulatorInjection.arm(...)` runs
   `xcrun simctl spawn <udid> launchctl setenv DYLD_INSERT_LIBRARIES <path>`.
   The env var survives until the simulator reboots; apps launched
   after the arming load the dylib via dyld.
5. Frames pump through `/tmp/SimCam.bgra`; the dylib's display-link
   driver picks them up on the next tick.

## iOS-26 gotchas worth preserving

- **Per-hash install dir.** iOS 26's simulator dyld page-hash cache
  rejects a *replaced* dylib at the same path with
  `code:codesigning(3) invalid-page(2)`. Every release ships a
  different sha and lands at a different path, dodging the cache.
- **Linker adhoc sign only.** The `clang -Wl,-adhoc_codesign`
  flag in `VirtualCamera/build.sh` sets the `linker-signed` flag the
  simulator's dyld accepts. A post-build `codesign --force --sign -`
  strips that flag and the dylib stops loading.
- **`setSourceType: .camera` throws without the hook.** Without
  swizzling `+isSourceTypeAvailable:`,
  `UIImagePickerController().sourceType = .camera` raises
  `NSInvalidArgumentException('Source type 1 not available')` in the
  simulator. The hook lies and returns `YES` for `.camera`.
- **Apps launched *before* arming don't load the dylib.** dyld
  honours `DYLD_INSERT_LIBRARIES` only at exec time. After arming, a
  fresh launch (or terminate + relaunch) picks the dylib up.
  Baguette doesn't reopen apps for the user; the camera card surfaces
  this when the captured frame doesn't appear in the live preview.

## Adding a new camera source

There are three producers today — `AVCameraCapture` (webcam),
`ImageFileCapture`, `VideoFileCapture` — each a `CameraCapture` the
`CameraSession` selects by inspecting a `CameraSource`
(`.device / .image / .video`). To add a fourth (e.g. a browser
`getUserMedia` stream):

1. Add a case to `CameraSource` + a `wireKind`, and teach
   `CameraStartSource` / `CameraMessage.parse` the new `source` token
   (parser test first).
2. New `CameraCapture` implementation in `Infrastructure/Camera/`. Use
   a role-noun collaborator (like `VideoDecoder`) if the API is
   conversational; a one-shot decode (like `StillImage.load`) if not.
   Fit the frame into the canvas with `ScaleToFit` and hand it to
   `onFrame` as a `CameraFrame`.
3. Inject it into `CameraSession` and add its `case` to
   `capture(for:)`; resolve the source in `Server.handleCameraLine`.

`SharedMemoryFrameSink`, `SimulatorInjection`, and the dylib stay the
same — they don't care where the bytes came from.

## Virtual camera device (camera-less simulators)

The preview-layer painting above shows frames only in apps that already
got a working `AVCaptureSession` — which needs a real `AVCaptureDevice`.
A simulator on a Mac **without a camera** has none, so `AVCaptureDevice`
discovery returns nil and real camera apps (expo-camera, VisionCamera,
straight AVFoundation) never start — they show a permission/loading
state, and there's nothing for the preview hook to paint.

`SimCamVirtualCamera.m` fixes that by **mocking the entire capture graph**
at the public AVFoundation boundary (the approach
[swmansion/SimCam](https://simcam.swmansion.com/) uses; baguette feeds
from the shared buffer instead of a socket). It's app-free — the app
sees a normal camera:

- `+[AVCaptureDevice defaultDeviceWithMediaType:]` and
  `-[AVCaptureDeviceDiscoverySession devices]` → a fabricated
  `AVCaptureDevice` subclass.
- `-[AVCaptureDeviceInput initWithDevice:error:]` → a **dummy input**
  for the fake device, so the real initializer (which dereferences the
  device format's private `FigCaptureSource`) never runs.
- `-[AVCaptureSession canAddInput:/addInput:/canAddOutput:/addOutput:]`
  → accept the dummy graph without wiring real hardware.
- `-[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]` → capture
  the delegate; a 30 fps timer builds `CVPixelBuffer` → `CMSampleBuffer`
  from `/tmp/SimCam.bgra` and calls
  `captureOutput:didOutputSampleBuffer:fromConnection:` directly.
- The fake `AVCaptureDeviceFormat` shims the private accessors
  AVFoundation reads during setup (`figCaptureSourceVideoFormat` → NULL,
  `videoSupportedFrameRateRanges` → `@[]`) plus
  `+[AVCapturePhotoSettings photoSettings]`, so `AVCapturePhotoOutput`
  init doesn't crash on the fabricated format.

With this, an unmodified app gets a device, `AVCaptureSession` "runs",
`onCameraReady`-style callbacks fire, and the preview + data-output show
baguette's image/video — no app edits.

**Injection is automatic (all apps), and armed only while streaming.**
`camera_start` arms the sim's launchd domain
(`SimctlSimulatorInjection`: `launchctl setenv DYLD_INSERT_LIBRARIES`),
so **every app launched afterward** loads the dylib — SimCam-style, no
per-app configuration. `stop` (and the WS `defer`) **disarms**
(`launchctl unsetenv`), so the dylib does *not* stay injected into every
future launch until reboot (the bug SimCam is known for). `CameraSession`
owns this: it records the armed simulator on `start` and unsets it on
`stop` / failed-start.

The one ordering rule: **the app must be (re)launched *after*
`camera_start`.** The dylib is inserted at exec time, so:

1. In the browser camera card, pick a source and **Start** (arms + streams).
2. **Relaunch the target app** — tap its icon, `xcrun simctl launch <udid> <bundle-id>`,
   or `expo run:ios` (which launches via `simctl`). An app already running
   from *before* Start won't have the dylib; a Metro JS reload doesn't
   re-exec, so relaunch the native process.
3. Open the camera screen — the app sees the virtual camera.

To inject into a single app without arming the whole sim (e.g. a launch
that bypasses launchd, like some Xcode Run configs),
`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` passes the dylib to one launch:

```
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$HOME/Library/Application Support/Baguette/builds/<sha>/VirtualCamera.dylib" \
  xcrun simctl launch --terminate-running-process <udid> <bundle-id>
```

The dylib survives Metro/JS reloads; relaunch only when the native app
restarts.

## Known limits (v1)

- **One camera at a time per host.** All simulators write
  `/tmp/SimCam.bgra`; the dylib reads whichever bytes landed last.
  The Server's camera WS doesn't reject a second concurrent start
  in v1 — the second one just trashes the first one's frames. To
  scope per-sim we'd patch the dylib to accept a path override.
- **No CLI yet.** `baguette camera --udid … --device <UID>` would
  be a thin layer over the same WS handler; the wire path is
  already there for agents that need it.
- **Video rotation isn't applied.** `VideoFileCapture` streams frames
  in their *encoded* orientation — a clip recorded with a rotation
  transform (many phone videos) plays sideways. Fitting and looping
  work; rotation correction is deferred.
- **No audio.** A video's audio track is ignored — the camera path
  carries frames only.
- **Still images are re-emitted at ~30 fps.** A single write would be
  hidden after ~1 s (the dylib's reader gates on an advancing sequence
  and shows "No camera signal" once stale), so `ImageFileCapture`
  re-writes the same pixels under a fresh sequence on a timer.
- **No "apps needing reopen" diagnostic.** SimCamMac surfaces a list
  of running apps that started before the dylib was armed. Baguette
  defers that to a v2; users who don't see frames should
  terminate-and-relaunch the iOS app.
- **Mac-only producer.** A future browser `getUserMedia` source
  (sketched in the design phase) would let the page's webcam feed
  the iOS app without going through AVFoundation on the host.
- **Virtual-camera format shims are AVFoundation-version-specific.**
  The graph mock neutralises the specific private `AVCaptureDeviceFormat`
  accessors AVFoundation reads on iOS 26 during capture setup
  (`figCaptureSourceVideoFormat`, `videoSupportedFrameRateRanges`). A
  future iOS may read a different accessor and crash the target app
  until that one is shimmed too — the trade-off of mocking private
  internals. Verified on iOS 26 with expo-camera 57.
- **No metadata/barcode delivery from the virtual camera.** Frames reach
  `AVCaptureVideoDataOutput` and the preview, but `AVCaptureMetadataOutput`
  isn't fed synthesized barcode objects — an app that scans via metadata
  output sees the camera but won't detect a code. Feeding
  `AVCaptureMetadataOutput` (e.g. Vision QR detection over the frames)
  is a follow-up.
