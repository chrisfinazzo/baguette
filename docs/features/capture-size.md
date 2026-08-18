# Capture size

One vocabulary for "how big should this come out", shared by every
surface that produces an image or a video: the toolbar picker, the
HTTP routes, and the CLI. Saying `appstore-6.9` in the browser and
`--size appstore-6.9` on the command line means the same pixels.

Screenshots are covered in [`screenshot.md`](screenshot.md),
recordings in [`recording.md`](recording.md), and the 3D device
render in [`3d-rendering.md`](3d-rendering.md). This doc is scoped to
the size vocabulary itself.

## The presets

| spec | label | resolves to |
|---|---|---|
| `native` | Native | the source's own dimensions |
| `appstore-6.9` | App Store 6.9″ | 1290 × 2796 |
| `appstore-6.5` | App Store 6.5″ | 1242 × 2688 |
| `appstore-ipad-13` | App Store iPad 13″ | 2064 × 2752 |
| `square` | Square | 1 : 1 |
| `16:9` | Landscape 16:9 | 16 : 9 |
| `9:16` | Portrait 9:16 | 9 : 16 |
| `4:3` | Classic 4:3 | 4 : 3 |
| `4:5` | Social 4:5 | 4 : 5 |

Two ad-hoc forms parse as well:

- `1920x1080` — exact pixels.
- `3:2` — any ratio not in the table.

Anything else is rejected. Baguette never substitutes a nearby size.

## Why a ratio grows instead of cropping

A ratio preset resolves **against the source**, and it never
downscales — it grows the binding axis so the whole source still fits
at 1 : 1:

```
r = ratioWidth / ratioHeight
sw/sh > r   →   (sw,  round(sw / r))     the source is wider: width binds
otherwise   →   (round(sh * r),  sh)     the source is taller: height binds
```

So a 1290 × 2796 phone frame asked for `square` gets a **2796 × 2796**
canvas with the phone centred, not a 1290 × 1290 crop through the
middle of the screen. The marketing-screenshot case is the whole
point of asking for a square, and cropping the device out of it is
exactly what nobody wants.

The App Store presets are `fixed`, so they ignore the source size
entirely — 1290 × 2796 is 1290 × 2796 whatever you point it at.

## Fit and background

| fit | what it does |
|---|---|
| `contain` *(default)* | scale to fit, centre, letterbox the remainder |
| `cover` | scale to fill, let the overflow crop |
| `stretch` | distort to fill exactly |

`background` is `transparent` or `#RRGGBB` (default `#ffffff`). It
only ever shows through under `contain`, so at `native` size the
effective background is always `transparent` — a PNG of a transparent
3D render doesn't silently gain a white mat.

## Placement

Both implementations return the same placement value: the canvas
size, plus where the source lands inside it.

```
plan(source, fit) → { width, height, drawX, drawY, drawWidth, drawHeight }
```

Under `cover` the draw origin goes **negative** — that overflow is
the crop. `isIdentity(for:)` (Swift) reports the "nothing to do" case
so callers can keep the original bytes instead of resampling.

## Where it lives

```
Sources/Baguette/
├── Domain/Capture/
│   └── CaptureSize.swift            CaptureSize, CaptureFit, CapturePlacement
└── Resources/Web/capture/
    ├── capture-size.js              window.Baguette._CaptureSize
    ├── capture-settings.js          window.Baguette._CaptureSettings
    ├── capture-composer.js          window.Baguette._CaptureComposer
    └── capture-size-menu.js         window.CaptureSizeMenu  (the picker)
```

`CaptureSettings` bundles the four things a user picks — size, fit,
background, and whether to composite the device bezel — into one
immutable value with `plan()`, `toQuery()` (the `?size=&fit=&background=`
the routes accept), `slug()` for download filenames, and
`restore` / `persist` against `localStorage`.

`CaptureComposer` does the two canvas jobs: `paintComposite` layers
bezel → clipped screen → overlay at natural size, and `compose` maps a
source-coordinate paint into the target canvas with the background
filled. Both `CaptureGallery` and `BrowserRecorder` had their own copy
of that rounded-rect clip before this existed.

## Testing

`Tests/BaguetteTests/Capture/CaptureSizeTests.swift` and
`Tests/Web/capture-size.test.js` assert the **same** numbers on both
sides — the two catalogues have to agree, and the ratio arithmetic is
the part that quietly drifts. `capture-settings.test.js` and
`capture-composer.test.js` cover persistence and the paint geometry.

The picker (`capture-size-menu.js`) is DOM rendering, so it stays
integration-only — same bar as `sim-native.js` and `farm-focus.js`.

## Known limits

- **The two catalogues are kept in sync by hand.** There is no
  generated source of truth; the paired test suites are what catch a
  drift. Adding a preset means editing both files and both tests.
- **Ratios never downscale**, so asking a tall phone for `16:9`
  produces a very wide canvas (4971 × 2796 from a 1290 × 2796 source).
  That is deliberate — use an explicit `WIDTHxHEIGHT` when you want a
  bounded output.
