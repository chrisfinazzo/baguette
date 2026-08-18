# Capture size

One vocabulary for "how big should this come out", shared by every
surface that produces an image or a video: the toolbar picker, the
HTTP routes, and the CLI. Saying `appstore-6.9` in the browser and
`--size appstore-6.9` on the command line means the same pixels.

Screenshots are covered in [`screenshot.md`](screenshot.md),
recordings in [`recording.md`](recording.md), and the 3D device
render in [`3d-rendering.md`](3d-rendering.md). This doc is scoped to
the size vocabulary itself.

## Why

Before this existed, every capture surface invented its own answer to
"how big?". `baguette screenshot` had `--scale`, an integer divisor.
`render-3d` had `--size WIDTHxHEIGHT`, literal pixels only. The
browser's screenshot gallery saved whatever the canvas happened to be,
and the recorder saved whatever the bezel viewport happened to be.
None of them could say "App Store 6.9-inch", which is the size people
actually need, and none of them agreed with each other.

Three things fall out of having one vocabulary:

- **A preset is a preset everywhere.** Pick `appstore-6.9` in the
  toolbar, then reproduce the exact same pixels in CI with
  `--size appstore-6.9`. No conversion table in the user's head.
- **One geometry implementation, twice.** Swift and JS both derive the
  canvas and the draw rect from the same rules, and the paired test
  suites assert the same numbers, so a browser capture and a CLI
  capture of the same frame land on the same bytes-worth of layout.
- **Sizes compose with the other capture choices.** Fit, background,
  and "with or without the device bezel" are the same three follow-up
  questions whatever produced the frame, so they travel together as
  one value rather than as four loose arguments per call site.

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

`background` is `transparent` (`none` is accepted too) or `#RRGGBB`
with the `#` optional. It only ever shows through under `contain`, so
at `native` size the effective background is always `transparent` — a
PNG of a transparent 3D render doesn't silently gain a white mat.

`#ffffff` is the default on every capture surface — the browser
picker, the HTTP routes, `baguette screenshot`, `baguette record`. A
capture with a letterbox is usually a finished artefact, and a
marketing shot on a checkerboard is not what anyone meant.
`baguette render-3d` is the one exception, defaulting to
`transparent`: its whole point is a device you can drop onto your own
background, and there is no screenshot behind it to protect.

Two traps behind that, both from the same root — **most image and
video formats carry no alpha**:

- **JPEG.** A `.jpg` cannot carry a transparent letterbox, so it mats
  *white* rather than honouring the request — an unmatted transparent
  canvas flattens to black on encode, and a black border is not what
  anyone meant by "transparent". Ask for PNG when you want the mat
  genuinely absent. Nothing warns you; format and background are
  independent flags.
- **MP4.** `baguette record --background transparent` is rejected at
  argument-parse time rather than silently flattened, so you learn
  about it before the ten-second take rather than after.

## Placement

Both implementations return the same placement value: the canvas
size, plus where the source lands inside it.

```
Swift   plan(source:fit:) → CapturePlacement
                            { width, height, drawX, drawY,
                              drawWidth, drawHeight }

JS      plan(sourceW, sourceH, fit)
                          → { width, height, drawX, drawY,
                              drawW, drawH,
                              sourceWidth, sourceHeight }
```

Same numbers, two spellings — the abbreviated `drawW` / `drawH` are
what canvas code reads, and the JS plan additionally carries the
source box it was computed from so a painter can recover the scale
without being handed the source size a second time (that is exactly
what `CaptureComposer.compose` does). Don't "unify" the field names
without changing both test suites; they assert the spellings.

Under `cover` the draw origin goes **negative** — that overflow is
the crop. `isIdentity(for:)` (Swift) reports the "nothing to do" case
so callers can keep the original bytes instead of resampling: a
native-size JPEG is passed through untouched rather than decoded,
redrawn, and re-encoded at a slightly different quality.

## Who speaks it

| surface | how the size is said |
|---|---|
| `baguette screenshot` | `--size` / `--fit` / `--background` |
| `baguette record` | `--size` / `--fit` / `--background` (hex only) |
| `baguette render-3d` | `--size` / `--background` (`--fit` is a *different* axis — see below) |
| `GET …/screenshot.{jpg,png}` | `?size=&fit=&background=` |
| `GET …/screenshot-bezel.png` | `?size=&fit=&background=` |
| `POST …/render-3d.png` | `"size"` / `"background"` in the body (`"fit"` is the mesh axis) |
| `WS …/stream.3d.<fmt>` | `size=` (or explicit `width=&height=`) |
| toolbar picker | `CaptureSizeMenu`, persisted per surface |
| browser capture / record | `CaptureSettings` → `toQuery()` / `plan()` |

`CaptureSettings.toQuery()` produces exactly the `?size=&fit=&background=`
triple the routes take, and returns **nothing at all** for `native` —
a native capture asks for no query parameters, so an old server and a
new page still agree on the default case.

**One name, two axes: `fit` on `render-3d`.** Everywhere else, fit
says how a frame sits inside the output canvas. On the 3D render it
says how the *screenshot* sits on the device's screen surface — a UV
placement on the mesh. Hence its default is `cover` there and
`contain` here: an app screenshot letterboxed inside a phone display
would read as a bug. The three mode names mean the same thing in both
places (fill and crop / fit and pad / distort); what they act on
differs, so a UI must not forward its canvas fit into a 3D render
request. See [`3d-rendering.md`](3d-rendering.md).

## Filenames

A saved capture is named for what it is, so a folder of marketing
shots sorts and greps sensibly:

```
iPhone_17_Pro-2026-08-18T10-31-02-appstore-6.9-1290x2796.png
iPhone_17_Pro-2026-08-18T10-31-02-1206x2622.mp4       ← native
```

`CaptureSettings.slug(width, height)` is the fragment: the resolved
dimensions on their own at `native`, prefixed with the size spec
otherwise. It sanitises anything outside `[A-Za-z0-9._-]` to a hyphen,
so `16:9` lands as `16-9-4971x2796`.

That colon is worth a sentence, because it looks harmless. A colon is
perfectly legal in an HFS+ filename — the OS stores it — but the
Finder *renders* it as a slash, so `16:9-4971x2796.png` appears in
Downloads as `16/9-4971x2796.png` and reads like a path. Sanitising in
`slug()`, the single place both screenshots and recordings name their
files, is what keeps the two surfaces identical without each growing
its own private swap.

## Where it lives

```
Sources/Baguette/
├── Domain/Capture/
│   └── CaptureSize.swift            CaptureSize, CaptureFit, CapturePlacement
├── Infrastructure/Screen/
│   └── CaptureCanvas.swift          the CoreGraphics half — allocate, fill
│                                    the background, draw at the planned rect
└── Resources/Web/capture/
    ├── capture-size.js              window.Baguette._CaptureSize
    ├── capture-settings.js          window.Baguette._CaptureSettings
    ├── capture-composer.js          window.Baguette._CaptureComposer
    └── capture-size-menu.js         window.CaptureSizeMenu  (the picker)
```

`CaptureCanvas` and `CaptureComposer` are the same job in two
runtimes: take a `CapturePlacement`, allocate the target, fill the
background, draw the source where the plan says. Neither one decides
anything — all the decisions were made by `CaptureSize.plan`, which is
why the decisions are the part that's unit-tested.

`CaptureSettings` bundles the four things a user picks — size, fit,
background, and whether to composite the device bezel — into one
immutable value with `plan()`, `toQuery()` (the `?size=&fit=&background=`
the routes accept), `slug()` for download filenames, and
`restore` / `persist` against `localStorage`.

`CaptureComposer` does the canvas jobs: `paintComposite` layers
bezel → clipped screen → overlay at natural size, and `compose` maps a
source-coordinate paint into the target canvas with the background
filled. Both `CaptureGallery` and `BrowserRecorder` had their own copy
of that rounded-rect clip before this existed.

`composite(frameImg, screen, sourceCanvas)` answers "how big is the
composite, really" — and the answer is **not** the bezel's own size.
DeviceKit authors its bezels in points: an iPhone 17 Pro Max frame is a
474 × 990 viewport around a 438 × 954 cutout, while the live canvas
carries the device's full 1320 × 2868 framebuffer. Compositing at the
viewport resamples the screen down by ~3× and throws the detail away
*before* the picked size gets a look at it, which defeats the point of
asking for an App Store size. So the composite grows until the cutout
is 1:1 with the frames and the bezel is scaled up to meet it — soft
chrome around a sharp screen beats a sharp frame around a thumbnail:

```js
const c = CaptureComposer.composite(frameImg, screen, canvas);
const plan = size.plan(c.width, c.height, fit);
CaptureComposer.compose(ctx, plan, background, (x) => {
  if (c.scale !== 1) x.scale(c.scale, c.scale);
  CaptureComposer.paintComposite(x, { frameImg, screen, sourceCanvas });
});
```

Growth is capped at 4× — a canvas the browser refuses to allocate
paints nothing at all — and the bezel-less path stays at 1:1, since
that canvas is already at capture scale.

## Hiding controls a surface can't honour

`CaptureSizeMenu` takes three flags, all defaulting to shown:

| flag | hidden when |
|---|---|
| `showFrameToggle` | the source already contains the device (the 3D stage) |
| `showFitToggle` | canvas fit isn't the caller's to set — see the `fit` note above |
| `showBackgroundToggle` | the render fills its own canvas, so a mat never shows |

The 3D view hides all three. All three are read at **render** time
rather than captured in the constructor, so a caller flips them on the
instance when the view switches 2D ↔ 3D and reopens the popover — no
rebuilding the menu, no losing the current selection.

Offering a control a surface will ignore is worse than not offering
it: a user who sets `fit: contain` for a 3D render and watches nothing
change has learned something false about the feature.

## Loading the browser half

The four `capture/*.js` files are plain IIFEs like the rest of
`Resources/Web/`, so any page that captures or records has to include
them **before** the module that uses them:

```html
<script src="/capture/capture-size.js"></script>
<script src="/capture/capture-settings.js"></script>
<script src="/capture/capture-composer.js"></script>
<script src="/capture/capture-size-menu.js"></script>
```

`recorder.js` and `capture-gallery.js` both depend on the first three
and fail loudly — not silently at native size — when they're missing.

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
- **The size is a canvas, not a resample budget.** A `contain` plan of
  a fixed preset larger than the source upscales the source to fit;
  nothing sharpens it. `appstore-6.9` off a 1206 × 2622 simulator is a
  genuine 1290 × 2796 file made of interpolated pixels. Capture at the
  device's native resolution if you need real detail.
- **A video canvas is rounded up to even dimensions.** H.264 4:2:0
  chroma subsampling requires it, so `baguette record` grows the
  planned canvas by up to one pixel per axis and re-centres the frame.
  A recording and a screenshot at the same preset can therefore differ
  by a pixel; the recording is never stretched to hide it.
- **A recording's size is locked when it starts.** `captureStream`
  binds to the compose canvas' backing store, so the canvas can't be
  resized mid-recording; if the live stream reconfigures its scale
  part-way through, later frames are re-planned into the box that was
  frozen at Record. Changing the picker takes effect on the next
  recording, not the current one.
- **The bezel toggle is only meaningful where a bezel exists.** It
  composites DeviceKit chrome around the screen; on a surface whose
  source is already a rendered device (the 3D stage) there is nothing
  to wrap, and the toggle is suppressed rather than silently ignored.
- **Presets are a snapshot of Apple's requirements.** `appstore-6.9`
  and friends are the submission sizes as of writing. When Apple
  changes them, the preset changes with them — pin an explicit
  `WIDTHxHEIGHT` if you need a size that never moves.
