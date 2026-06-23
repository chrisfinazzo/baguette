# Location

Set the booted simulator's simulated GPS position — pin a single
latitude/longitude, run a moving route between waypoints, or clear back
to the device's live location. Three entry points share one path:

- `baguette location set --udid <UDID> <lat,lon>` /
  `baguette location start --udid <UDID> [tuning] <lat,lon>…` /
  `baguette location clear --udid <UDID>` — CLI.
- `POST /simulators/:udid/location` (JSON body) /
  `DELETE /simulators/:udid/location` — served by `baguette serve`.
- The focus-mode **Location** card (map-pin toolbar button) in the
  browser — a glass panel with a Leaflet map: click to drop a pin and
  "Set location", or switch to Route mode and drop two or more waypoints
  to "Start route".

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

baguette location clear --udid <UDID>
```

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

`POST /simulators/:udid/location` accepts either shape. A `waypoints`
array selects the route path; otherwise a bare `latitude`/`longitude`
pair is a single-point `set`.

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

`DELETE /simulators/:udid/location` clears the override (no body).

A malformed body, an out-of-range point (lat ∉ ±90 or lon ∉ ±180), or a
route with fewer than two valid waypoints returns `400` with
`{"ok":false,"error":…}` — the request is rejected loudly, never
silently dropped.

## Dispatch path

```
Coordinate / LocationRoute  →  Location.set / .start / .clear  →  SimctlLocation
   (Domain value + argv          (@Mockable, Domain)               (Infrastructure)
    projection)                                                        │
                                                                       ▼
                                                  xcrun simctl location <udid> set|start|clear
```

- `Coordinate.argument` → `"<lat>,<lon>"` (the `set` token and each
  route waypoint).
- `LocationRoute.startArguments` → the equals-form flags (`--speed=…`,
  `--distance=…`, `--interval=…`) in a stable order, then the waypoint
  tokens.
- `SimctlLocation` prepends `simctl location <udid> <verb>` and runs it
  through the shared `Subprocess` collaborator. A non-zero exit becomes
  `LocationError.simctlFailed(status:)`.

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

- **Set / start / clear only.** Named drive scenarios (`simctl location
  run`) aren't wired yet (see recipe above).
- **No device read-back.** `simctl location` can't report the active
  simulated position, so there's no `GET …/location`; the panel's
  "locate me" is the Mac's GPS, not the device's.
- **Tile imagery + search need network.** Leaflet is vendored, but OSM
  tiles and Nominatim geocoding are fetched at runtime.
- **`--` for negative-latitude tokens on the CLI.** A waypoint or
  position whose latitude starts with `-` must follow a `--` separator so
  ArgumentParser doesn't treat it as a flag.
