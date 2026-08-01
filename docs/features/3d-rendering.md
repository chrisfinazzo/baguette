# 3D device rendering

Live rendering of the simulator screen on a real Apple device model. The
primary surface is an interactive 3D stream in the focused simulator view;
one-shot PNG rendering remains available for automation and export:

- `WS /simulators/:udid/stream.3d.mjpeg` and `.avcc` load the matched model
  once and continuously map SimulatorKit frames onto its screen material.
- `baguette render-3d` captures a booted simulator, or accepts an existing
  screenshot, and writes a PNG.
- `POST /simulators/:udid/render-3d.png` captures the current simulator frame
  and returns a PNG using the same model/render-plan vocabulary.

The cube toolbar button switches the main device viewport between the existing
low-latency 2D stream and the live server-rendered 3D stream. It does not open
a duplicate preview card. The 3D socket remains bidirectional: gestures and
stream controls use the same JSON envelopes as the ordinary stream.

The rendering approach is based on
[`benmcdowell/3dsg`](https://github.com/benmcdowell/3dsg), but device support is
data-driven. Scene node names, screen geometry, device matching, and USD
variant selections live in model definitions rather than Swift enums.

## Color accuracy

Rendering uses **RealityKit** (`RealityRenderer`), the same engine Quick Look
uses for `device.usdz` previews, so authored finishes tone-map the way the
model's own preview does. SceneKit rendered the identical USDZ visibly wrong:
its lack of filmic tone mapping kept bright metal at the authored hue
(dark saturated orange) where Quick Look rolls it toward gold, and no
environment intensity could fix both glass and aluminum at once — measured
against Quick Look sample zones, SceneKit bottomed out at roughly twice the
color error RealityKit starts at.

Two details keep the pipeline honest:

- **The screen is exempt from scene lighting and tone mapping.** Simulator
  frames land on an `UnlitMaterial(applyPostProcessToneMap: false)`, so a
  96-gray simulator pixel leaves the composed frame as 96-gray. Body and
  screen are effectively separate passes: PBR with tone mapping for the
  device, exact passthrough for the app.
- **The unlit screen pass needs its own antialiasing.** RealityKit's 4× MSAA
  covers lit geometry but skips the tone-map-exempt screen pass, so the
  screen content edge stair-steps on tilted poses. Each frame therefore
  renders at 2× and is Lanczos-downscaled into the codec ring (capped at
  4096 px per side), restoring blended edge coverage everywhere — verified
  by an edge-coverage test that counts intermediate pixels across the
  bezel-to-content boundary.
- **Cover-glass reflections are opt-in.** `screenGlass` clones the display
  geometry into a black dielectric layer at zero opacity, lifted a hair along
  the display normal, so only fresnel-weighted reflections composite over the
  unlit screen. The glass carries its own HDR streak environment through a
  per-entity image-based light — body lighting and screen pixels stay exactly
  as calibrated, and the default (off) output is byte-identical to before the
  feature existed. Dragging the pose sweeps the streak band across the glass.
- **Exposure is calibrated, not eyeballed.** `DeviceStudioLighting` feeds one
  equirectangular studio image to RealityKit
  (`EnvironmentResource(equirectangular:)`) with `intensityExponent = 1.5`,
  the measured minimum of the per-zone color error against Quick Look's
  rendering of the same asset. The calibration is pinned by tests.

## CLI

Capture the current simulator frame and infer the model from its device type:

```bash
baguette render-3d \
  --udid 5A1B… \
  --variant finish=space-black \
  --rotation=-30,45,30 \
  --size 1200x1200 \
  --output device.png
```

Render an existing image by selecting a model explicitly:

```bash
baguette render-3d \
  --screen screenshot.png \
  --device iphone-17-pro \
  --variant finish=deep-blue \
  --output device.png
```

Exactly one of `--udid` and `--screen` is required. `--device` is required
with `--screen` and inferred from the simulator when `--udid` is used.
`--output` defaults to stdout, matching `baguette screenshot`.

| Flag | Default | Meaning |
|------|---------|---------|
| `--udid` | — | Capture this booted simulator |
| `--screen` | — | Use an existing PNG or JPEG |
| `--device` | inferred | Installed model definition ID |
| `--variant <set>=<choice>` | definition defaults | Repeatable model variant selection |
| `--rotation X,Y,Z` | `0,0,0` | Device rotation in degrees |
| `--size WIDTHxHEIGHT` | source dimensions | Output pixel size |
| `--fit cover\|contain\|stretch` | `cover` | Screenshot placement on the screen surface |
| `--background transparent\|#RRGGBB` | `transparent` | Output canvas |
| `--screen-glass` | off | Composite a reflective cover glass over the screen |
| `--output`, `-o` | stdout | PNG destination |

Unknown devices, model IDs, variant sets, and variant choices fail explicitly.
Baguette never substitutes a visually similar model.

## HTTP

```http
POST /simulators/:udid/render-3d.png
Content-Type: application/json
```

```json
{
  "rotation": {
    "x": -30,
    "y": 45,
    "z": 30
  },
  "variants": {
    "finish": "space-black"
  },
  "size": {
    "width": 1200,
    "height": 1200
  },
  "fit": "cover",
  "background": "transparent",
  "screenGlass": false
}
```

The response is `image/png`. Defaults are the same as the CLI. Error branches:

| Status | Meaning |
|--------|---------|
| `400` | Malformed render options or an unknown variant selection |
| `404` | Unknown simulator UDID or no installed definition matches it |
| `422` | The matched definition cannot render the requested configuration |
| `500` | Frame capture, model loading, asset download, or RealityKit rendering failed |

The model metadata used to build the browser inspector is exposed separately:

```http
GET /simulators/:udid/3d-model.json
```

It returns the resolved model ID, display name, and public variant-set metadata.
USD prim paths, raw scene-node names, and asset URLs are not accepted from the
browser.

## Live 3D WebSocket

```http
GET /simulators/:udid/stream.3d.<mjpeg|avcc>
Upgrade: websocket
```

Initial render configuration is supplied as public query parameters:

```text
?rotation=-8,18,0
&variant=finish:deep-blue
&width=1200
&height=1200
&fit=cover
&background=%23eef1f5
&screenGlass=true
```

`variant` is repeatable. The server validates model, variant, rotation, output
size, fit, and background before subscribing to the simulator screen.
`RenderedScreen` produces codec-ready BGRA IOSurfaces, then the selected
existing stream emits either raw JPEG messages or AVCC description/key/delta
messages. The first frame can take longer because the model and asset are
loaded; later frames reuse the same RealityKit stage, camera, materials,
screen texture, Metal targets, and renderer.

Client-to-server text frames reuse the ordinary stream channel:

```json
{"type":"tap","x":219,"y":478,"width":438,"height":954}
{"type":"set_fps","fps":20}
{"type":"set_scale","scale":1}
```

Variant changes reconnect the 3D socket with a new validated render
configuration. Camera changes update the retained scene and immediately
re-render the latest simulator surface without reconnecting. Gestures remain
in simulator device points and are dispatched through the existing
`GestureDispatcher` and `Input`; no new HID dialect is introduced.

## Model bundles

A model is a directory containing one versioned definition and either a local
USDZ asset or a verified download descriptor:

```text
iphone-17-pro/
├── definition.json
└── device.usdz
```

Definitions are resolved in precedence order:

1. `BAGUETTE_3D_MODEL_DIR`
2. `~/Library/Application Support/com.tddworks.baguette/3d-models`
3. bundled definitions under `Resources/Models3D`

An ID found in a higher-precedence directory replaces the same ID below it.
Two definitions at the same precedence that match one simulator are an error.

The asset block may contain `file`, or `downloadURL` plus a required SHA-256,
or both. A local file wins. Downloaded assets are staged to a temporary name,
verified, and atomically moved into the application-support cache.

Apple USDZ binaries should not be committed to this repository until their
redistribution terms have been verified. Bundled definitions may point at the
same Apple-hosted assets used by 3dsg.

## Definition schema

```json
{
  "schemaVersion": 1,
  "id": "macbook-pro-14-inch",
  "displayName": "MacBook Pro 14-inch",
  "matches": {
    "simulatorDeviceTypes": [],
    "deviceNames": ["MacBook Pro 14-inch"]
  },
  "asset": {
    "file": "macbook-pro-14-in-space-black-variant.usdz",
    "downloadURL": "https://example.invalid/model.usdz",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "scene": {
    "rootNode": "XCnTRSzLPcVVRyt",
    "screenNode": "Screen",
    "screenMaterial": "ScreenMaterial",
    "nativeOrientation": "landscape",
    "textureSize": {
      "width": 3024,
      "height": 1964
    },
    "usesScreenOverlay": false
  },
  "variantSets": [
    {
      "id": "finish",
      "displayName": "Device finish",
      "primPath": "/XCnTRSzLPcVVRyt",
      "usdName": "Color",
      "default": "space-black",
      "choices": [
        {
          "id": "space-black",
          "displayName": "Space Black",
          "usdValue": "Space_Black",
          "previewColor": "#2f3033"
        },
        {
          "id": "silver",
          "displayName": "Silver",
          "usdValue": "Silver",
          "previewColor": "#d3d4d5"
        }
      ]
    }
  ]
}
```

`id` and choice IDs are baguette's stable public vocabulary.
`usdName`, `usdValue`, and `primPath` are private model instructions. Render
requests select only declared public IDs, so callers cannot author arbitrary
USD paths.

A definition is rejected when:

- `schemaVersion` is unsupported;
- IDs are empty or duplicated;
- dimensions are not positive;
- a variant default does not name one of its choices;
- a downloaded asset has no valid SHA-256;
- neither a local file nor a download URL is present.

## Variants

Variants use one public set/choice vocabulary with two definition strategies:
`"kind": "usd"` (the default) authors a native USD variant selection, while
`"kind": "materials"` applies a declared map of authored material names to
hex colors, replacing the material's base texture so the declared finish is
exact rather than a tint multiplied into the original texture. The latter supports models such as Matte's iPhone 17 Pro, whose
Cosmic Orange, Deep Blue, and Silver appearances are material adjustments
rather than native USD variants. One model may expose independent finish,
keyboard, stand, Pencil, or other sets.

When a request omits a set, its declared default is applied. For a USD set, the
renderer creates a temporary USDA overlay that sublayers the USDZ and pins the
selection before RealityKit loads the scene. Material selections are applied to
the loaded entity tree. Changing a variant reloads that model; the UI renders on
control commit rather than on every pointer-move event.

Bundled local models currently cover iPhone 17, iPhone Air, iPhone 17 Pro,
iPhone 17 Pro Max, iPad Pro 11/13-inch M4, Apple Watch Series 11 42/46mm, and
Apple Watch Ultra 3. The MacBook Pro 14-inch definition demonstrates a
downloaded, SHA-256-verified model with a native USD finish variant.

## Pipeline

```text
SimulatorKit Screen
      │ IOSurface frames
      ▼
RenderedScreen (Screen decorator)
  1. resolve model + verified asset once
  2. author variant overlay and load the entity once (RealityKit)
  3. fit a 32° perspective camera to the complete model once
  4. build studio lighting, screen material and renderer once
  5. blit each IOSurface into one persistent LowLevelTexture
  6. render 2× supersampled (plus engine 4× MSAA on lit geometry)
  7. Lanczos-downscale into a bounded Metal target ring
  8. publish a codec-ready BGRA IOSurface
      │
      ▼
VideoFrameDimensions + VideoFrameScaler
      │
      ├──▶ MJPEGStream ─▶ JPEG messages ─┐
      └──▶ AVCCStream  ─▶ H.264 messages ├──▶ Focus-mode 3D viewport
                                         ┘

CLI / PNG export
      │
      ▼
RealityKitDeviceRenderer
  decodes the screen image and drives the same live stage for one frame
```

`DeviceRenderPlan`, `DeviceCameraFraming`, `VideoFrameDimensions`, live-stream
option parsing, definition parsing, device matching, defaults, and variant
validation live in Domain and are unit-covered. `DeviceCameraFraming` shares
the 32° perspective lens, 15% bounds padding, aspect fit, and distance-based
zoom between the live and one-shot renderers. This matches the camera model
used by the reference ThreeDSGCore renderer and avoids the severe
foreshortening produced by the former orthographic projection.
`LiveDeviceModels` implements the `DeviceModels` aggregate collection.
`RenderedScreen` owns the conversational frame/render lifecycle while the
existing `MJPEGStream` and `AVCCStream` retain codec responsibility. The
irreducible URL download, filesystem, USD, IOSurface, and RealityKit calls
remain in Infrastructure.

This feature does not change `Input`, `IndigoHIDInput`, SimulatorKit HID
symbols, or `GestureRegistry`. It reuses the existing bidirectional stream
control WebSocket behavior.

## Browser behavior

The focus-mode cube button changes the main viewport itself. In 3D mode the
live rendered device occupies the same central stage as the normal device,
while a compact right inspector carries camera presets, variants, advanced
rotation, and PNG export. On narrow windows the inspector becomes a bottom
sheet. Hiding the inspector does not close the socket or remove the model:
pose, zoom, variant, decoder, and stream remain live, and a stage button opens
the inspector again. The cube toolbar button is the explicit way to leave 3D
and return to the 2D stream.

The live 3D canvas uses the same full viewport rectangle as the 2D simulator,
without a separate card, border, radius, or stage shadow. MJPEG and H.264
frames are opaque, so the browser sends the current light or dark page color
as the render background and reconnects the 3D stream when the theme changes.

The 3D stage follows an explicit two-mode interaction model:

- **Pose** (default): drag rotates the persistent model, Option-drag or the
  wheel dollies the perspective camera, and double-click returns to Front at
  100%. Camera changes re-render the retained simulator frame on the existing
  WebSocket; they never reload the model or restart MJPEG/AVCC.
- **Interact**: the canvas binds the same `Screen` and `PointerInterpreter` as
  the 2D simulator. Normal drag, long press, edge gestures, Option-drag pinch,
  Option-Shift-drag two-finger pan, and wheel gestures therefore share one
  browser and wire implementation. Use Front for accurate input until
  screen-mesh ray casting is implemented.

Pose/Interact and Reset live on the stage so direct manipulation remains
available with the inspector hidden. Their controls sit outside the canvas
gesture target, so clicking a control is never captured as a pose or simulator
gesture. As on the 2D screen surface, explicit mouse and touch listeners with
document-level drag continuation keep drags active after leaving the model; the
implementation does not rely on Pointer Events or element capture in
Safari/WebKit. Exact Tilt/Turn/Roll controls are collapsed under Advanced
rotation.

Decoded 3D frames follow the same paint discipline as the stable 2D
`StreamSession`: decoding replaces one pending frame, and the browser
compositor loop paints the latest frame. The panel does not draw directly from
the decoder callback because Safari/WebKit can retain the previous canvas
backing image even while new frames are decoded.

The browser requests up to 2× CSS-pixel resolution (capped at 1600 pixels per
side) so Retina displays retain authored model and screen detail. Frames are
rendered 2× supersampled and Lanczos-downscaled before either codec sees
them; H.264 and MJPEG therefore receive identical geometry and antialiased
edges.

The implementation also shares that session directly: `Sim3DPanel` supplies
the `/stream.3d.<format>` URL and 3D control callbacks to `StreamSession`; it
does not own a second WebSocket, decoder, FPS counter, or paint loop. Thus 2D
and 3D have identical AVCC/MJPEG lifecycle and browser compatibility behavior.

The stream deduplicates frames by IOSurface identity and seed together. A 3D
render rotates through three persistent IOSurface-backed Metal targets. This
triple buffer bounds allocation while keeping the GPU producer and codec
consumer off the same target during normal real-time operation. Separate
targets can have the same seed, so identity and seed must both participate in
frame deduplication. After Metal finishes rendering, the scene publishes the
write through IOSurface before the shared JPEG or VideoToolbox encoder reads it.
Live output dimensions are rounded up to even values for the H.264 4:2:0
hardware path; MJPEG uses the same aligned dimensions so switching codecs does
not resize the stage. Reconfigured scale output is aligned again after division
so downscaling cannot produce an odd codec dimension. The scaler also publishes
its Core Image GPU copy before VideoToolbox retains the pixel buffer for
asynchronous encoding.

The socket accepts the same input envelopes as the normal stream, so toolbar,
keyboard, pasteboard, and programmatic controls do not require a second
connection. Variant choices may reconnect because native USD variant
selection happens when the model is loaded; ordinary posing never does.

The farm view is intentionally out of scope: rendering a separate 3D
image for every live farm tile is too expensive and adds no control value.

## Adding a model

1. Create a model directory with `definition.json`.
2. Add a local `device.usdz`, or declare `downloadURL` and `sha256`.
3. Run `baguette models validate <directory>`.
4. Copy it into the application-support model directory or point
   `BAGUETTE_3D_MODEL_DIR` at its parent.
5. Run `baguette models list` and render a known screenshot before adding
   simulator-name matching.

## Known limits

- Live 3D supports the existing MJPEG and H.264/AVCC stream formats. AVCC
  requires browser WebCodecs support, matching the normal focused stream.
- Interact mode does not yet ray-cast onto the model's screen mesh. Front view
  is the supported direct-input pose.
- Model definitions depend on opaque node/material names that Apple may change
  when replacing an asset at the same URL; SHA-256 verification prevents an
  unnoticed replacement.
- RealityKit rendering is macOS-only, main-actor bound (each frame hops to
  the main queue, like HID input), and remains an integration-tested boundary.
- Models without a declared and measurable screen surface cannot be used.
- USD variants are chosen before RealityKit loads the scene; changing them
  requires a model reload.
