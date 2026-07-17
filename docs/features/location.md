# Location

Set the booted simulator's simulated GPS position — pin a single
latitude/longitude, run a moving route between waypoints, drive the
device around with a joystick, or clear back to the device's live
location. Three entry points share one path:

- `baguette location set --udid <UDID> <lat,lon>` /
  `baguette location start --udid <UDID> [tuning] <lat,lon>…` /
  `baguette location walk --udid <UDID> --bearing <deg> --speed <m/s> <lat,lon>` /
  `baguette location clear --udid <UDID>` — CLI.
- `POST /simulators/:udid/location` (JSON body) /
  `DELETE /simulators/:udid/location` — served by `baguette serve`.
- The focus-mode **Location** card (map-pin toolbar button) in the
  browser — a glass panel with a Leaflet map: click to drop a pin and
  "Set location"; switch to Route mode and drop two or more waypoints to
  "Start route"; or switch to **Walk** mode and drive the device with an
  on-screen joystick (or tank-control `W`/`A`/`S`/`D`), then **Replay**
  the path you walked.

Unlike taps / swipes, this is **not** a SimulatorHID path. It shells out
to `xcrun simctl location <udid> set | start | clear` — the same
mechanism Xcode's Simulator **Features ▸ Location** menu uses. It's a
one-shot subprocess; no booted-device HID plumbing is involved.

## Why

App flows that read CoreLocation — maps, weather, ride-hailing, geofenced
features — need a controllable position to test against, independent of
the host Mac's real location. `simctl location` provides this but has no
UI in a headless/browser workflow and its waypoint/tuning syntax is easy
to get wrong. baguette wraps it behind a validated value type, a CLI verb
trio, and a map picker that matches the focus-mode chrome.

## Surface

```
baguette location set --udid <UDID> <lat,lon>
    <lat,lon>                    position token, e.g. 37.3318,-122.0312

baguette location start --udid <UDID> [tuning] <lat,lon> <lat,lon> [<lat,lon>…]
    [--speed <m/s>]              interpolation speed (default: simctl's 20)
    [--distance <metres>]        emit an update every N metres travelled
    [--interval <seconds>]       emit an update every N seconds
    <lat,lon>…                   two or more waypoint tokens

baguette location walk --udid <UDID> --bearing <deg> --speed <m/s> <lat,lon>
    --bearing <deg>              compass degrees clockwise from north, normalised
    --speed <m/s>                1.4 ≈ walking, 25 ≈ driving
    <lat,lon>                    starting position token

baguette location clear --udid <UDID>
```

`walk` heads off from a position and keeps going, driving
`CLLocation.course` from the travel (see [Walk mode](#walk-mode-the-joystick)
below). Stop it with `location set` (pins it) or `location clear` (drops
the override).

The position is a single `lat,lon` **token**, not two `--lat` / `--lon`
flags: a western/southern coordinate begins with `-`, and ArgumentParser
would read `-122.03` as an unknown option. The comma-joined token
sidesteps that and stays symmetric with the `start` waypoints. For a
coordinate whose **latitude** itself starts with `-`, pass `--` first so
ArgumentParser stops scanning for options:

```bash
baguette location set --udid "$U" -- -37.8136,144.9631     # Melbourne
```

## Wire JSON

`POST /simulators/:udid/location` accepts three shapes, discriminated in
this order: a `waypoints` array selects the route path; a `bearing`
selects the walk vector; otherwise a bare `latitude`/`longitude` pair is
a single-point `set`.

The order matters — a walk body carries `latitude`/`longitude` too, so
`bearing` has to be read **before** the bare-point branch, or every
joystick vector would silently parse as a stationary point and the device
would never move.

Single point:

```json
{ "latitude": 37.3318, "longitude": -122.0312 }
```

Route (two or more waypoints; `speed` / `distance` / `interval` optional):

```json
{
  "waypoints": [
    { "latitude": 37.629538, "longitude": -122.395733 },
    { "latitude": 40.628083, "longitude": -73.768254 }
  ],
  "speed": 260,
  "distance": 1000
}
```

Walk vector (`bearing` in compass degrees, `speed` in m/s — both
required):

```json
{ "latitude": 37.3349, "longitude": -122.0090, "bearing": 90, "speed": 1.4 }
```

`bearing` is normalised onto the circle, so `-90` and `270` are the same
heading. Releasing the joystick sends the plain **single point** shape at
the device's current position: that pins it and drops `course` back to
`-1`, which is exactly "no longer travelling".

`DELETE /simulators/:udid/location` clears the override (no body).

A malformed body, an out-of-range point (lat ∉ ±90 or lon ∉ ±180), a
route with fewer than two valid waypoints, or a walk with a missing /
non-positive speed returns `400` with `{"ok":false,"error":…}` — the
request is rejected loudly, never silently dropped.

## Dispatch path

```
LocationWalk ──.route(horizon:)──┐
 (Domain vector:                 │
  origin+bearing+speed)          ▼
Coordinate / LocationRoute  →  Location.set / .start / .clear  →  SimctlLocation
   (Domain value + argv          (@Mockable, Domain)               (Infrastructure)
    projection)                                                        │
                                                                       ▼
                                                  xcrun simctl location <udid> set|start|clear
```

Note there is **no walk-specific Infrastructure**: a walk *is* a route
once projected, so it reuses the `start` path end to end. The only new
code is the pure Domain projection.

- `Coordinate.argument` → `"<lat>,<lon>"` (the `set` token and each
  route waypoint).
- `Coordinate.projected(bearing:metres:)` → the great-circle destination
  point; total by construction (`asin` bounds the latitude, the longitude
  wraps across the antimeridian rather than overflowing).
- `LocationWalk.route(horizon:)` → `[origin, position(after: horizon)]`
  at the walk's speed. The far waypoint **is** `position(after:)`, so the
  browser's dead-reckoned pin and the device's interpolated track trace
  the same line and can't disagree.
- `LocationRoute.startArguments` → the equals-form flags (`--speed=…`,
  `--distance=…`, `--interval=…`) in a stable order, then the waypoint
  tokens.
- `SimctlLocation` prepends `simctl location <udid> <verb>` and runs it
  through the shared `Subprocess` collaborator. A non-zero exit becomes
  `LocationError.simctlFailed(status:)`.

## Walk mode (the joystick)

Walk mode drives the device around live, with two control schemes that
share one heading:

- **The thumbstick is absolute.** Drag it and the device points where you
  pushed — angle = heading, deflection = speed. It's a compass rose.
- **The keyboard is relative — tank controls.** `W`/`S` drive
  forward/reverse along the heading the device *already* has; `A`/`D`
  sweep that heading at 90°/s, including while standing still. Hold `W`
  and `D` together to drive an arc. Arrows mirror WASD; `Shift` boosts
  ×3. This is the videogame scheme: you steer one persistent heading
  rather than naming absolute bearings.

A speed preset picks the ceiling — Walk 1.4 · Run 3.5 · Cycle 6 · Drive
13.4 · Highway 29 m/s.

**Heading is persistent state, not a property of the current vector.**
The device still points somewhere when it's standing still: the compass
holds its bearing, `A`/`D` can pivot it on the spot, and `W` then drives
along it. (Deriving the needle from the live vector meant it swung back
to north the instant you released the stick — and slewed there, since the
needle animates. If the compass ever resets on stop again, that's the
regression.)

`S` reverses like backing a car: the heading — where the device *faces* —
is unchanged, but the direction of travel is 180° opposed, so
`CLLocation.course` reports the reverse. The readout marks it `⟲`.

### Replay

Walking records a trail, sampled every 4 m rather than every animation
frame (60 fps would be thousands of points — a bloated polyline and a
request body far past the server's 64 KB cap; past 500 points the trail
halves its own resolution rather than dropping its tail). Stop, and
**Replay** retraces it.

The recorded trail *is* a `{waypoints,speed}` route body — the exact
shape Route mode already posts — so replay reuses the existing
`simctl location start` path with **no new wire and no new Swift**.

Speed comes from the preset **at replay time**, not from what you
originally walked: `start` takes one speed for a whole route, so a
varying-speed walk can't be reproduced exactly anyway — and picking at
replay time means you can retrace a footpath at Highway speed, which
turns out to be the useful part. Grabbing the stick or hitting a key
cancels a replay.

### Why it sends a vector, not positions

The obvious joystick — POST a new point every animation frame — fails
twice over, and both failures are measured, not theoretical:

- **`set` is too slow.** Each `xcrun simctl location … set` spawn costs
  **~277 ms** (measured mean over consecutive calls), capping the tick
  rate near **3.6 Hz**. Visibly jerky, and a spawn storm besides.
- **`set` can't express direction.** A pinned point is *stationary*:
  locationd reports it with `course = -1` and `speed = -1`. No amount of
  re-pinning makes an app see a direction of travel.

A two-waypoint `start` route fixes both. It's **fire-and-forget** — the
spawn returns in ~430 ms while the *daemon* interpolates smoothly for as
long as the route lasts — and because the device genuinely travels the
leg, locationd **derives** course and speed from the motion. So the
joystick sends its **vector** (origin + bearing + speed) only when the
vector *changes*; `LocationWalk` projects that into a route whose far
waypoint sits `LocationWalk.defaultHorizon` (600 s of travel) ahead along
the bearing.

Measured behaviour that makes this work:

| Action | Result |
| --- | --- |
| `start` with a 220 s route | returns in ~430 ms; daemon runs it in the background |
| second `start` mid-route | retargets in **~200 ms**, no glitch (`course 90 → 0`) |
| `set` during a route | stops it; `speed,-1 course,-1` |
| `start -` (stdin waypoints) | **buffers to EOF** — cannot stream a joystick |

The browser dead-reckons its pin locally (mirroring
`Coordinate.projected` — same formula, same earth radius) so the map
animates at 60 fps while the wire stays near-silent: sends are throttled
to ≥250 ms apart, skipped when the bearing moved <2° or the speed <0.1
m/s, latest-wins if one is in flight, and re-sent every 30 s so a held
stick never runs out of road.

### The course gotcha worth preserving

**iOS 26's locationd derives `CLLocation.course` on a flat lat/lon grid.**
It computes `atan2(Δlongitude, Δlatitude)` on raw degrees, ignoring that
meridians converge toward the poles (the missing `cos(latitude)` factor).

Measured at Apple Park (lat 37.33): a geodesically-correct due-**NE**
route reports **`Course,51.52`** instead of 45°. The flat prediction is
51.54° — the observed value matches the bug, not the intent.

- Cardinal bearings (N/S/E/W) are **immune** — one delta is zero, so the
  missing factor cancels. `Course,90.00` for due east, exactly.
- The skew scales as `1/cos(latitude)`: **0° at the equator**, ~6.5° at
  lat 37, ~18° at lat 60.
- The device's **movement is on a true globe** — due-north and due-east
  routes at the same `--speed` cover identical real ground. Only the
  derived course is flat.

That last point is why this can't be fixed: correct positions
mathematically *force* a wrong course, because the platform derives
course *from* those positions with broken maths. You can have a truthful
track or a truthful course, never both.

**baguette keeps positions truthful.** `Coordinate.projected` stays a
proper great-circle projection, so you always move exactly where you
steer, and every app reading position gets the truth. The course skew is
Apple's bug, documented here rather than papered over by deliberately
walking the device off-course. Heading still *follows* the stick — it
just isn't exact on diagonals away from the equator.

### Course is not heading

`CLLocation.course` (direction of travel) is drivable. **`CLHeading`
(the compass) is not, by anything.** The simulator has no magnetometer:

```
CLLocationManager.headingAvailable() == false
```

An app calling `startUpdatingHeading` receives nothing in the simulator,
and no simctl verb or private API changes that. If you need a compass
reading in a simulator, it has to be shimmed inside the app under test
(e.g. swizzling `CLLocationManager` in a debug build) — that lives in the
app, not in baguette.

### The locale gotcha worth preserving

simctl mandates `.` as the decimal separator and `,` as the field
separator. `Coordinate.argument` is built from Swift's
**locale-independent** `Double` interpolation — it never routes through a
locale-aware formatter, which on a German/French locale would emit a
decimal comma and split `"48,8584,2,2945"` into garbage. There's a unit
test pinning the dot-decimal projection so this can't regress.

## Where the map comes from

The browser panel uses **Leaflet 1.9.4**, vendored under
`Resources/Web/vendor/leaflet/` (served at `/vendor/leaflet/…`) — no
bundler, no CDN, consistent with the rest of the web UI. The map
**tiles** are fetched from OpenStreetMap (`tile.openstreetmap.org`) at
runtime; that's the one piece that needs network. Offline, the card
still renders and the readout still works, but tile imagery won't load.
The pin is a CSS `divIcon`, so no Leaflet marker PNG assets are vendored.

## Search + locate (browser-side conveniences)

The card's top row has two helpers that never touch the backend — they
just move the map and (in Point mode) drop the pin, after which the
normal "Set location" POST does the work:

- **Search** — type a place name and the panel geocodes it via OSM
  **Nominatim** (`nominatim.openstreetmap.org/search`, free, no API key,
  CORS-enabled) and recentres on the first match. Same network-only
  posture as the tiles. It's low-volume dev use; respect Nominatim's
  1 req/sec usage policy.
- **Locate me** (crosshair button) — centres on the **host Mac's** real
  position via the browser geolocation API. `localhost` is a secure
  context, so the prompt works over plain HTTP.

### Why there's no "read the device's current location"

`simctl location` is write-only — `set` / `start` / `clear`, with no
"get". (`simctl location <udid> list` enumerates named *scenarios*, not
the active position.) So baguette deliberately exposes **no**
`GET …/location` and the `Location` protocol has no `read()`: there is
no supported way to query what the device is currently simulating.
"Locate me" reports the Mac's GPS, not the device's. This is the one
asymmetry with the status-bar surface, which *can* read back via
`simctl status_bar list`.

## Adding a new location capability

`simctl location` also has `run <scenario>` (named Apple drive scenarios
from `simctl location <udid> list`). To add it:

1. **Domain** — a `LocationScenario` value (or reuse a string) + a test
   for any argv projection.
2. **Domain** — a `func run(_:)` on the `Location` protocol with a doc
   comment.
3. **Infrastructure** — a `run` branch in `SimctlLocation`
   (`["simctl","location",udid,"run",scenario]`), tested via
   `MockSubprocess`.
4. **App** — a `LocationCommand.Run` subcommand.
5. **Server** — extend `parseLocationRequest` / `applyLocation` (e.g. a
   `{"scenario":"…"}` body), tested via `MockLocation`.

## Known limits

- **`CLHeading` (the compass) is impossible.** `headingAvailable()` is
  `false` in the simulator — no magnetometer. Only `CLLocation.course`
  (direction of travel) can be driven. See
  [Course is not heading](#course-is-not-heading).
- **`course` is skewed on diagonal bearings.** iOS 26 derives it on a
  flat lat/lon grid, so a due-NE walk reports ~51.5° instead of 45° at
  lat 37 (0° at the equator, ~18° at lat 60). Cardinal bearings are
  exact. Unfixable without lying about position — see
  [The course gotcha](#the-course-gotcha-worth-preserving).
- **Walk drift between sends.** Each vector change re-origins the device
  at the browser's reckoned position, so the device can lag by one spawn
  latency (~430 ms × speed) mid-leg. It's bounded, not cumulative, and
  releasing the stick snaps the device exactly onto the pin. Turning is
  where it shows most: the pin traces a smooth arc while the device
  walks straight legs between sends.
- **Replay uses one speed for the whole route.** `simctl location start`
  takes a single `--speed`, so a walk whose speed varied replays at a
  constant one (the preset selected at replay time).
- **Set / start / walk / clear only.** Named drive scenarios (`simctl
  location run`) aren't wired yet (see recipe above).
- **No device read-back.** `simctl location` can't report the active
  simulated position, so there's no `GET …/location`; the panel's
  "locate me" is the Mac's GPS, not the device's.
- **Tile imagery + search need network.** Leaflet is vendored, but OSM
  tiles and Nominatim geocoding are fetched at runtime.
- **`--` for negative-latitude tokens on the CLI.** A waypoint or
  position whose latitude starts with `-` must follow a `--` separator so
  ArgumentParser doesn't treat it as a flag.
