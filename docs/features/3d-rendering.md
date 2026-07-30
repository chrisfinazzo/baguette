# 3D device rendering

One-shot PNG rendering of a simulator screenshot on a real Apple device
model. The first release has two entry points backed by the same rendering
pipeline:

- `baguette render-3d` captures a booted simulator, or accepts an existing
  screenshot, and writes a PNG.
- `POST /simulators/:udid/render-3d.png` captures the current simulator frame
  and returns a PNG for the focus-mode 3D preview.

The 3D preview is a presentation surface, not a second live simulator stream.
Input continues through the existing 2D simulator view. A continuously
interactive 3D stream would require a separate WebGL or SceneKit streaming
design and is not part of this feature.

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
CLI render-3d                     Focus-mode 3D card
      │                                  │
      │                    POST /simulators/:udid/render-3d.png
      └──────────────────┬───────────────┘
                         ▼
                 DeviceRender options
                         │
             DeviceModels resolves definition
                         │
              ScreenSnapshot captures frame
                         │
                         ▼
              SceneKitDeviceRenderer
                1. resolve/cache USDZ
                2. write temporary screen image
                3. author variant overlay
                4. load and select scene nodes
                5. replace/overlay screen texture
                6. orient, light, frame, render
                7. return PNG and clean temporary files
```

`DeviceRender`, definition parsing, device matching, defaults, and variant
validation live in Domain and are unit-covered. `LiveDeviceModels` implements
the `DeviceModels` aggregate collection. The irreducible URL download,
filesystem, USD, and SceneKit calls remain in Infrastructure.

This feature does not touch `Input`, `IndigoHIDInput`, SimulatorKit HID
symbols, `GestureRegistry`, or the stream-control WebSocket.

## Browser behavior

The focus-mode toolbar gains a 3D cube toggle using the same glass toolbar and
floating-card language as the status-bar, location, camera, and network
controls.

Opening the card resolves model metadata and requests a Hero preview. Camera
drag updates local control values; a new PNG is requested on pointer release.
Variant changes request a new preview after the control commits. “Render PNG”
requests the selected output size and downloads the response.

The existing live 2D simulator remains mounted. Switching back to Live makes
it visible immediately and restores normal input. The first version does not
project taps through a static 3D render.

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

- Rendering is one-shot, not a live 3D stream.
- The initial UI preview cannot receive simulator taps.
- Model definitions depend on opaque node/material names that Apple may change
  when replacing an asset at the same URL; SHA-256 verification prevents an
  unnoticed replacement.
- SceneKit rendering is macOS-only and remains an integration-tested boundary.
- Models without a declared and measurable screen surface cannot be used.
- USD variants are chosen before SceneKit loads the scene; changing them
  requires a model reload.
