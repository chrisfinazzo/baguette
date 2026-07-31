# 3D device rendering

Live rendering of the simulator screen on a real Apple device model. The
primary surface is an interactive 3D stream in the focused simulator view;
one-shot PNG rendering remains available for automation and export:

- `WS /simulators/:udid/stream.3d.mjpeg` loads the matched model once and
  continuously maps SimulatorKit frames onto its screen material.
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
  "background": "transparent"
}
```

The response is `image/png`. Defaults are the same as the CLI. Error branches:

| Status | Meaning |
|--------|---------|
| `400` | Malformed render options or an unknown variant selection |
| `404` | Unknown simulator UDID or no installed definition matches it |
| `422` | The matched definition cannot render the requested configuration |
| `500` | Frame capture, model loading, asset download, or SceneKit rendering failed |

The model metadata used to build the browser inspector is exposed separately:

```http
GET /simulators/:udid/3d-model.json
```

It returns the resolved model ID, display name, and public variant-set metadata.
USD prim paths, raw scene-node names, and asset URLs are not accepted from the
browser.

## Live 3D WebSocket

```http
GET /simulators/:udid/stream.3d.mjpeg
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
```

`variant` is repeatable. The server validates model, variant, rotation, output
size, fit, and background before subscribing to the simulator screen. It emits
one raw JPEG per binary WebSocket message, matching the existing MJPEG decoder.
The first frame can take longer because the model and asset are loaded; later
frames reuse the same SceneKit scene, camera, materials, and renderer.

Client-to-server text frames reuse the ordinary stream channel:

```json
{"type":"tap","x":219,"y":478,"width":438,"height":954}
{"type":"set_fps","fps":20}
{"type":"set_scale","scale":1}
```

Camera or variant changes reconnect the 3D socket with a new validated render
configuration. Gestures remain in simulator device points and are dispatched
through the existing `GestureDispatcher` and `Input`; no new HID dialect is
introduced.

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
`"kind": "materials"` applies a declared map of SceneKit material names to
hex colors. The latter supports models such as Matte's iPhone 17 Pro, whose
Cosmic Orange, Deep Blue, and Silver appearances are material adjustments
rather than native USD variants. One model may expose independent finish,
keyboard, stand, Pencil, or other sets.

When a request omits a set, its declared default is applied. For a USD set, the
renderer creates a temporary USDA overlay that sublayers the USDZ and pins the
selection before SceneKit loads the scene. Material selections are applied to
the loaded node tree. Changing a variant reloads that model; the UI renders on
control commit rather than on every pointer-move event.

Bundled local models currently cover iPhone 17, iPhone Air, iPhone 17 Pro,
iPhone 17 Pro Max, iPad Pro 11/13-inch M4, Apple Watch Series 11 42/46mm, and
Apple Watch Ultra 3. The MacBook Pro 14-inch definition demonstrates a
downloaded, SHA-256-verified model with a native USD finish variant.

## Pipeline

```text
SimulatorKit Screen                    Focus-mode 3D viewport
      │ IOSurface frames                         ▲
      ▼                                          │ raw JPEG messages
SceneKit3DStream ────────────────────────────────┘
  1. resolve model + verified asset once
  2. author variant overlay and load scene once
  3. build camera, light, material and renderer once
  4. update screen material for each IOSurface
  5. render and JPEG-encode the configured output

CLI / PNG export
      │
      ▼
SceneKitDeviceRenderer
  uses the same definition, variant and camera vocabulary for one frame
```

`DeviceRenderPlan`, live-stream option parsing, definition parsing, device
matching, defaults, and variant validation live in Domain and are unit-covered.
`LiveDeviceModels` implements the `DeviceModels` aggregate collection.
The persistent SceneKit stream owns the conversational frame/render lifecycle;
the irreducible URL download, filesystem, USD, IOSurface, and SceneKit calls
remain in Infrastructure.

This feature does not change `Input`, `IndigoHIDInput`, SimulatorKit HID
symbols, or `GestureRegistry`. It reuses the existing bidirectional stream
control WebSocket behavior.

## Browser behavior

The focus-mode cube button changes the main viewport itself. In 3D mode the
live rendered device occupies the same central stage as the normal device,
while a compact inspector carries camera presets, rotation, variants, and PNG
export. Closing 3D returns immediately to the already-mounted 2D stream.

The socket accepts the same input envelopes as the normal stream, so toolbar,
keyboard, pasteboard, and programmatic controls do not require a second
connection. Direct pointer gestures are currently an approximation over the
rendered canvas; exact ray-to-screen-plane projection is follow-up work.

The farm view is intentionally out of scope: rendering a separate SceneKit
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

- The first live format is MJPEG. H.264 encoding of SceneKit output is a
  separate optimization.
- Direct pointer input does not yet ray-cast onto the model's screen mesh, so
  clicks near the device edges can be inaccurate at rotated camera angles.
- Model definitions depend on opaque node/material names that Apple may change
  when replacing an asset at the same URL; SHA-256 verification prevents an
  unnoticed replacement.
- SceneKit rendering is macOS-only and remains an integration-tested boundary.
- Models without a declared and measurable screen surface cannot be used.
- USD variants are chosen before SceneKit loads the scene; changing them
  requires a model reload.
