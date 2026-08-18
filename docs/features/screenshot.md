# Screenshot

One-shot image of the simulator's framebuffer, in JPEG or PNG, at
whatever size you asked for. Entry points that share one capture path:

- `GET /simulators/:udid/screenshot.jpg` — served by `baguette serve`,
  returns `image/jpeg` bytes.
- `GET /simulators/:udid/screenshot.png` — the same frame, in a
  lossless container.
- `GET /simulators/:udid/screenshot-bezel.png` — the frame composited
  inside the device's DeviceKit bezel.
- `baguette screenshot --udid <UDID>` — CLI; writes to `--output` or
  stdout.

Every one of them takes an output size from the shared vocabulary in
[`capture-size.md`](capture-size.md) — `--size appstore-6.9` on the
CLI, `?size=appstore-6.9` on the routes, the toolbar picker in the
browser, all the same pixels.

If you want the live recording-and-overlays story instead, read
[`recording.md`](recording.md). This doc is scoped to single-frame
capture — pipeline shape, the tunables, and the few non-obvious
trade-offs.

## Why

`baguette serve` already streams via WebSocket and accepts `snapshot`
as an inline verb on that channel, but two real workflows wanted a
plain HTTP fetch:

- **Browser cache-busting** — `<img src="…/screenshot.jpg?t=…">` with
  a rotating timestamp is the simplest possible "refresh on demand"
  affordance for review tools and dashboards. No WS plumbing needed
  in the embedding page.
- **CLI / CI** — `curl -o shot.jpg …` and `baguette screenshot --output
  shot.jpg` drop into shell pipelines, golden-image diffs, and bug
  reports without spinning up a stream session.

The endpoint name and content-type match what every browser already
expects from an `<img>` tag — no new client code path on the page.

Three later requests reshaped it:

- **A lossless container.** JPEG is the right default for a dashboard
  thumbnail and the wrong one for anything that gets composited,
  annotated, or re-saved: every round trip through it adds another
  layer of 8×8 block artefacts. PNG stops the *further* bleeding — see
  the known limit about the one JPEG hop still in the capture path.
- **A size that means something.** `--scale 2` answers "half of
  whatever the device is", which nobody's App Store submission asks
  for. `--size appstore-6.9` answers the question people actually
  have.
- **The bezel, without a browser.** The device-farm wall composites
  DeviceKit chrome around each tile, and that composite is what people
  want to paste into a PR. Getting it used to mean opening a page,
  taking a screenshot, and cropping it.

## Surface

```
GET /simulators/:udid/screenshot.jpg         ─┐
GET /simulators/:udid/screenshot.png          ├─ ?quality= &scale= &size=
GET /simulators/:udid/screenshot-bezel.png   ─┘   &fit= &background=
                        (…and ?buttons=)          │
                                                  ▼
   200 image/jpeg | image/png                  ScreenSnapshot.capture
   400 application/json   {"ok":false,"error":"Unknown size '…'. …"}
   404 application/json   {"ok":false,"error":"unknown udid: <udid>"}
   404 application/json   {"ok":false,"error":"no bezel for udid <udid>"}
   500 application/json   {"ok":false,"error":"<details>"}
```

All three routes take the same five parameters. `?buttons=` is the
bezel route's own — it matches `bezel.png`'s existing meaning, `false`
giving the bare device body without the button overshoot.

**`GET screenshot.jpg` with no new parameters returns exactly what it
returned before.** The size plan comes back as identity, nothing is
redrawn, and the bytes are not re-encoded. Every dashboard already
pointing an `<img>` at that URL is unaffected.

```
baguette screenshot --udid <UDID> [--output <path>] [--format png|jpg]
                    [--quality 0.85] [--scale 1]
                    [--size native] [--fit contain] [--background '#ffffff']
```

`--output` defaults to stdout, so it composes with redirection:

```bash
baguette screenshot --udid 5A1B… > shot.jpg
baguette screenshot --udid 5A1B… --output /tmp/shot.jpg
baguette screenshot --udid 5A1B… --quality 0.6 --scale 2 > thumb.jpg

# a submission-sized asset, letterboxed on white (the default)
baguette screenshot --udid 5A1B… --size appstore-6.9 --output hero.png

# the same, with no mat at all — PNG, because JPEG has no alpha
baguette screenshot --udid 5A1B… --size appstore-6.9 \
                    --background transparent --output hero-alpha.png

# a square social crop — cover fills the canvas and lets the edges go
baguette screenshot --udid 5A1B… --size square --fit cover -o square.jpg
```

An unknown `--size` / `?size=` is an error, never a near-miss
substitution — the whole point of naming a submission size is that it
is exact. The message names the whole catalogue:

```
Unknown size 'appstore6.9'. Expected WIDTHxHEIGHT, W:H, or one of:
native | appstore-6.9 | appstore-6.5 | appstore-ipad-13 | square |
16:9 | 9:16 | 4:3 | 4:5
```

### Picking the format

`--format` takes `png` or `jpg` (`jpeg` is accepted as an alias). It
is **inferred from `--output` when you don't say**: an output path
ending in `.png` writes PNG, everything else — including stdout —
writes JPEG. An explicit `--format` always wins. This exists so
`-o hero.png` can't quietly produce a file full of JPEG bytes under a
`.png` name, which is the kind of thing that surfaces three tools
later as "your PNG is corrupt".

Over HTTP the extension *is* the format: `screenshot.jpg` and
`screenshot.png` are two routes, not one route with a parameter, so
an `<img src>` and a `curl -O` both get the right thing for free.

## Pipeline

```
ScreenSnapshot.capture(screen, quality, scale, timeout)
   1. open SimulatorKit Screen (registers framebuffer callbacks)
   2. await first IOSurface delivered to the @Sendable callback
        ─ first-claim wins:           timer fires    → throw .timeout
                                      callback fires → encode + return
                                      start() throws → propagate error
   3. if scale ≥ 2: Scaler.downscale → CVPixelBuffer
      else:         use IOSurface zero-copy
   4. size ≠ native → CaptureCanvas
        placement = size.plan(source, fit)
        if placement.isIdentity(for: source) → skip, keep the bytes
        else CoreGraphics: fill background, draw at the plan's rect
   5. bezel route → composite DeviceKit chrome around it first
   6. JPEGEncoder / PNGEncoder → Data
   7. defer { screen.stop() }
```

The `SnapshotSession` actor-of-sorts (`@unchecked Sendable` holder)
owns the encoder, scaler, and a single-shot `claim()` flag. Three
producers race for the flag — the timeout timer, the frame callback,
and the `screen.start()` throw path — and only the first wins, so the
continuation can never resume twice.

The same helper drives both the HTTP routes and the CLI; quality /
scale / size / fit / background defaults match between them so tooling
that calls one sees the same bytes as tooling that calls the other.

`CaptureCanvas` is the CoreGraphics half of the size vocabulary: given
a `CapturePlacement` from `CaptureSize.plan`, it allocates the target
bitmap, fills the background, and draws the source at the planned
rect. Under `cover` the planned origin is negative, so the draw simply
overflows the context and the overflow is the crop — no separate crop
path. `contain` letterboxes onto the background colour, `stretch`
draws to the full canvas.

The identity check earns its keep: at `--size native` (the default)
the placement is a no-op, `CaptureCanvas` is skipped entirely, and the
encoded bytes are exactly what they were before any of this existed.
A frame is never decoded and re-encoded just to be told it was already
the right size.

`--scale` and `--size` compose in that order: scale reduces what came
off the framebuffer, then the size vocabulary resolves against the
*scaled* frame. `--scale 2 --size square` squares up the half-size
frame; it does not square up the device and then halve it.

## Why a separate path, not "stream + read one frame"?

Three reasons:

1. **No WS handshake.** The HTTP route is a single GET; embedding pages
   and curl scripts don't need to know how to speak the binary frame
   format or the JSON control verbs.
2. **No reconfig churn.** A streaming session would have to be opened,
   asked to emit a snapshot, then closed — which on a busy simulator
   means waiting for the next encoder seam. The one-shot path bypasses
   the encoder entirely; it just grabs the next IOSurface that
   SimulatorKit hands over.
3. **No live-stream interference.** A snapshot grabbed via the WS
   `snapshot` verb shares the live encoder pacing (`StreamConfig.fps`,
   `scale`). The HTTP screenshot ignores both — `?scale=`, `?quality=`,
   and `?size=` only affect the returned image, never the live stream.

`?quality` and `?scale` mirror the WS knobs deliberately so callers
can pick the same trade-off they're used to from the streaming path;
`?size` / `?fit` / `?background` mirror the CLI flags and the browser
picker instead, because a size is a property of the artefact you're
producing, not of the stream you're watching.

## Tunables

| Knob        | CLI flag       | URL param      | Default    | What it changes |
|-------------|----------------|----------------|------------|-----------------|
| Format      | `--format`     | the route path | inferred from `--output`, else `jpg` | `png` is lossless; over HTTP the extension *is* the format |
| Quality     | `--quality`    | `?quality=`    | `0.85` on `.jpg`, `1.0` on the PNG routes | JPEG lossy compression (0.0 – 1.0) — see below for PNG |
| Scale       | `--scale`      | `?scale=`      | `1`        | Integer downscale divisor (1 = native, 2 = half, …) |
| Size        | `--size`       | `?size=`       | `native`   | Output canvas — a preset, `WIDTHxHEIGHT`, or `W:H` |
| Fit         | `--fit`        | `?fit=`        | `contain`  | `contain` letterboxes, `cover` crops, `stretch` distorts |
| Background  | `--background` | `?background=` | `#ffffff`  | Letterbox colour, or `transparent` |
| Buttons     | —              | `?buttons=`    | `true`     | Bezel route only: `false` drops the button overshoot |
| Output path | `--output, -o` | —              | stdout     | CLI only |

Both `quality` and `scale` are clamped to sane minima — `scale` is
floored at `1`, `quality` is whatever `kCGImageDestinationLossyCompressionQuality`
clamps it to (effectively `[0, 1]`).

`--quality` has no effect on a PNG from the CLI. The HTTP PNG routes
do still accept `?quality=`, but it governs the **JPEG intermediate**
the capture pipeline produces, not the delivered PNG: `ScreenSnapshot`
encodes JPEG unconditionally, and the PNG routes decode that back to a
`CGImage` before re-encoding. It defaults to `1.0` there (against
`0.85` on `screenshot.jpg`), so a PNG is near-lossless out of the box
— but not bit-exact. Lowering `?quality=` on a `.png` request degrades
the image *inside* a lossless container, which is the sort of thing
worth knowing before you do it by accident.

The preset table lives in [`capture-size.md`](capture-size.md) and is
not duplicated here — there is one catalogue, and this is one of its
consumers.

`fit` and `background` are inert at `size=native`, because there is no
spare canvas for them to act on. That is not a special case in the
code — the placement simply comes back as identity — but it is worth
knowing before you file a bug about `--background` doing nothing.

`--background` takes `transparent` (or `none`), or a hex colour with
the `#` optional — `--background ffffff` and `--background '#ffffff'`
are the same thing, which saves one round of shell-quoting grief. The
value is trimmed and lowercased before validation, so `--fit CONTAIN`
and `--background ' TRANSPARENT '` are accepted too.

Over HTTP the `#` is optional for a different reason than on the CLI:
a literal `#` starts the URL fragment and never reaches the server at
all, so `?background=ffffff` is the spelling that actually works
unescaped. `%23ffffff` works too.

White is the default on every surface — the CLI flag, the routes, and
the browser picker — because a capture with a letterbox is usually a
finished artefact and a marketing shot on a checkerboard is not what
anyone meant. `transparent` is one word away when you want to
composite it yourself.

Then mind the format: **JPEG has no alpha channel**, so
`--background transparent --format jpg` composites the letterbox onto
**black**, not white. Ask for PNG whenever you ask for transparency.

## The bezel route

`screenshot-bezel.png` composites the DeviceKit chrome the farm wall
and the live view already draw:

```
DeviceChrome composite       ← underneath
   clip(innerCornerRadius)
     framebuffer, cover-fitted into the cutout
```

Same z-order as everywhere else in baguette, for the same reason: the
composite artwork paints an opaque dark "off-glass" tint inside the
screen rect, authored to sit *under* live content. The framebuffer is
**cover**-fitted into the cutout, so a device whose capture aspect
doesn't quite match its chrome crops a hair rather than stretching —
a distorted screenshot inside a correct bezel looks broken in a way a
1-pixel crop does not.

It is PNG-only, and that is not an oversight: the device body has
transparent corners, and a JPEG of it would be a phone on a black
rectangle. `?size=` / `?fit=` / `?background=` then apply to the
composited image, so `?size=square&background=ffffff` gives you the
bezelled device centred on a white square — which is the actual
marketing shot, in one GET, without a browser.

**The composite is sized off the framebuffer, not off the chrome.**
DeviceKit geometry is in 1× points; the captured frame is in device
pixels. Sizing the canvas from the chrome would throw away most of the
capture, so it goes the other way — the canvas takes the capture's
resolution and the chrome is resampled up to meet it. An iPhone 17 Pro
Max asked for `screenshot-bezel.png` with no parameters comes back at
1483 × 2984, not the chrome's ~494 × 995. It never drops below 1×
either, so a heavy `?scale=` shrinks the screen content but not the
bezel around it.

A device with no DeviceKit artwork gets a `404`, not an invented grey
rectangle. See [`chrome-bezel.md`](chrome-bezel.md) for which devices
ship chrome.


## In the browser

Every capture surface in the web UI — the legacy stream sidebar, the
focus-mode toolbar, and the device-farm focus pane — mounts the same
size chip (`CaptureSizeMenu`) beside its Screenshot button, and each
remembers its own selection in `localStorage`. A capture then takes
one of two routes to a file:

- **`CaptureGallery`** fetches the screenshot over HTTP and forwards
  the picker's `?size=&fit=&background=` verbatim, so the server does
  the resize. Each thumbnail records the dimensions it actually came
  back at, and the download filename carries the size slug.
- **The composite path** paints locally through `CaptureComposer` when
  the bezel is wanted, because the bezel image is already decoded on
  the page and re-fetching it server-side would be slower and no more
  correct.

Both end up at the same pixels, because both plan through the same
`CaptureSize`. The picker's "Include bezel" checkbox is what chooses
between them; it is hidden on surfaces where a bezel is meaningless
(the 3D stage already contains a device).

## Timeouts and errors

`ScreenSnapshot.capture` takes a `timeout: TimeInterval = 2.0`. Two
real failure modes it guards against:

- **Idle simulator** — SimulatorKit only fires the framebuffer callback
  on a frame change. A simulator booted but quiescent (lock screen
  with no clock tick visible, headless test runner waiting on input)
  may not emit a frame for several seconds. The timeout converts that
  into a clean 500 / `Failure.timeout` instead of a hanging request.
- **Wedged GPU pipe** — pre-iOS-26 simulators occasionally lose their
  framebuffer descriptor mid-session. Without the timeout the await
  is unbounded.

The HTTP layer translates everything to `application/json` error
envelopes; the CLI exits non-zero with the underlying message logged.

A malformed `size` / `fit` / `background` is a **client** error, not a
capture failure — it's rejected before the framebuffer is touched, so
a typo costs a 400 rather than a two-second timeout, and each message
names the whole accepted set:

```
Unknown size 'nonsense'. Expected WIDTHxHEIGHT, W:H, or one of:
  native | appstore-6.9 | appstore-6.5 | appstore-ipad-13 | square |
  16:9 | 9:16 | 4:3 | 4:5
Unknown fit 'squish'. Expected one of: contain | cover | stretch
Unknown background 'chartreuse'. Expected 'transparent' or #RRGGBB
```

The CLI prints the same sentences and exits non-zero.

`screenshot-bezel.png` has one failure mode the flat routes don't: a
device with no DeviceKit chrome, which answers `404 no bezel for udid
<udid>`. Baguette does not invent a generic rectangle to wrap it in.

## Files

```
Sources/Baguette/
├── Domain/
│   └── Capture/
│       └── CaptureSize.swift             size vocabulary + placement
├── Infrastructure/
│   ├── Screen/
│   │   ├── ScreenSnapshot.swift          capture helper (this doc)
│   │   └── CaptureCanvas.swift           CoreGraphics letterbox / crop
│   └── Server/
│       └── Server.swift                  screenshot.{jpg,png} +
│                                         screenshot-bezel.png routes
└── App/
    ├── Commands/
    │   └── ScreenshotCommand.swift       baguette screenshot
    └── RootCommand.swift                 registers ScreenshotCommand
```

The split follows the usual rule: the *what* — which canvas, where the
source lands, whether there is anything to do at all — is pure Domain
and unit-covered in `Tests/BaguetteTests/Capture/CaptureSizeTests.swift`.
Only the CoreGraphics and `CGImageDestination` calls are
integration-only.

## Known limits

- **A size is a canvas, not a resampler.** `--size appstore-6.9` off a
  1206 × 2622 device produces a genuine 1290 × 2796 file of upscaled
  pixels. Nothing sharpens it. If you need real detail at a submission
  size, capture from a device whose native resolution is at least that
  large.
- **Ratios grow, they never crop.** `--size square` on a phone gives a
  tall square with the phone centred, not a square cut out of the
  middle of the screen. That is the whole point (see
  [`capture-size.md`](capture-size.md)), but it does mean `--size 16:9`
  on a portrait device produces a very wide image. Use an explicit
  `WIDTHxHEIGHT` when you want a bounded output, or `--fit cover` when
  you genuinely do want the crop.
- **PNG is not bit-exact.** `ScreenSnapshot` encodes JPEG
  unconditionally, so the PNG routes decode that intermediate and
  re-encode it losslessly. At the default `?quality=1.0` the loss is
  negligible, but a golden-image diff of two captures of the *same*
  unchanged frame is not guaranteed byte-identical. Removing the round
  trip means teaching the capture helper to hand back a `CGImage`
  rather than `Data`; it hasn't landed.
- **`transparent` is a PNG-only answer.** JPEG has no alpha; a
  transparent background composites onto black there. Nothing warns
  you — the flags are independent.
- **No bezel on the JPEG routes, and no bezel on the CLI.**
  `screenshot-bezel` is PNG only — DeviceKit chrome has rounded
  corners and therefore alpha, and a JPEG of it would be a phone on a
  black rectangle. And there is no `--bezel` flag: the composite is an
  HTTP route, so a shell script wanting one reaches for `curl`.
- **Bezel composite needs chrome for the device.** Devices with no
  DeviceKit artwork can't be composited; the route 404s rather than
  falling back to a plain rectangle.
- **The bezel cutout cover-fits.** A capture whose aspect doesn't match
  the chrome's screen rect loses a sliver at two edges rather than
  distorting. Normally invisible; worth knowing if you are diffing
  bezelled captures pixel-for-pixel.
- **Synchronous on the request thread.** A request that has to wait
  the full 2 s for the timeout pins one Hummingbird request task. Not
  a problem at human-scale request rates; would matter under heavy
  scripted polling.

## Extension points

- **Region capture.** A `?rect=x,y,w,h` query param + a one-line
  `CGImage.cropping(to:)` would let dashboards grab just the status
  bar or a known UI region without a server-side composite step. Note
  this is a genuinely different axis from `?size=`: one selects part
  of the source, the other shapes the destination.
- **A bezelled JPEG, on an opaque background.** The bezel route is PNG
  because chrome has alpha — but a solid `?background=` already
  flattens it. Honouring the bezel composite on `screenshot.jpg` when
  a solid background is given would give thumbnail-heavy pages a
  cheaper bezelled image than PNG.
- **A bezel on the CLI.** `baguette screenshot --bezel` would want the
  same composite the route does; the reason it doesn't exist yet is
  that the chrome rasterization currently lives on the server side of
  the split, not that it's hard.
- **A JPEG-free PNG path.** `ScreenSnapshot` returns encoded `Data`,
  which forces the JPEG hop above. Returning a `CGImage` and letting
  each caller choose its encoder would make `screenshot.png` genuinely
  bit-exact and would save the bezel route a decode as well.
- **WebP / AVIF.** The `CGImageDestination` switch is a one-line
  format string; smaller payloads at the same visual quality matter
  for thumbnail-heavy pages like `/farm`.
