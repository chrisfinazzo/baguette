# Status bar

Override the booted simulator's status bar — fixed time, carrier name,
data-network type, Wi-Fi / cellular mode + signal bars, and battery
state + level — or clear everything back to live values. Three entry
points share one path:

- `baguette status-bar override --udid <UDID> [flags…]` /
  `baguette status-bar clear --udid <UDID>` — CLI.
- `POST /simulators/:udid/status-bar` (JSON body) /
  `DELETE /simulators/:udid/status-bar` — served by `baguette serve`.
- The focus-mode **Status Bar** card (signal-bars toolbar button) in
  the browser — a glass panel that live-applies as you change controls.

Unlike taps / swipes, this is **not** a SimulatorHID path. It shells out
to `xcrun simctl status_bar <udid> override | clear` — the same
mechanism Xcode's Simulator menu uses. That's why no booted-device HID
plumbing is involved; it's a one-shot subprocess.

## Why

Demos, screenshots, and App Store captures want a clean status bar —
9:41, full bars, 100% battery, a chosen carrier — regardless of the
host's real network. `simctl status_bar` does this but its flag surface
is fiddly to remember and has no UI in a headless/browser workflow.
baguette wraps it behind a typed value, a CLI verb pair, and a panel
that matches the focus-mode chrome.

## Surface

```
baguette status-bar override --udid <UDID>
    [--time <string>]            fixed clock, e.g. "9:41"; an ISO date also sets the date
    [--operator-name <string>]   carrier name ("" blanks it)
    [--data-network <type>]      wifi | 3g | 4g | lte | lte-a | lte+ | 5g | 5g+ | 5g-uwb | 5g-uc | hide
    [--wifi-mode <mode>]         active | searching | failed
    [--wifi-bars <0-3>]
    [--cellular-mode <mode>]     active | searching | failed | notSupported
    [--cellular-bars <0-4>]
    [--battery-state <state>]    charging | charged | discharging
    [--battery-level <0-100>]

baguette status-bar clear --udid <UDID>
```

```
GET    /simulators/:udid/status-bar     → current overrides as JSON ({} if none)
POST   /simulators/:udid/status-bar     body: {"batteryLevel":68,"dataNetwork":"5g",…}
DELETE /simulators/:udid/status-bar     clears all overrides

   200 application/json   {"ok":true}                          (POST/DELETE)
   200 application/json   {"dataNetwork":"wifi","wifiBars":2,…} (GET)
   400 application/json   {"ok":false,"error":"set at least one status-bar field"}
   404 application/json   {"ok":false,"error":"unknown udid: <udid>"}
   500 application/json   {"ok":false,"error":"status-bar override failed (simctl error)"}
```

`POST` accepts any subset of fields — send just the one you're changing
(e.g. `{"wifiBars":1}`); simctl merges it into the existing overrides, so
a single-field POST updates only that indicator. `GET` reads the device's
current overrides back (parsed from `simctl status_bar … list`) so a UI
can hydrate from reality instead of guessing.

The JSON body keys are the camelCase field names (`time`,
`operatorName`, `dataNetwork`, `wifiMode`, `wifiBars`, `cellularMode`,
`cellularBars`, `batteryState`, `batteryLevel`). Every field is
optional; at least one is required (an empty body is `400`). A present
enum field with an unrecognised value is `400` — the parser fails loud
rather than silently dropping it.

```bash
# Picture-perfect demo state.
baguette status-bar override --udid 5A1B… \
  --time 9:41 --operator-name Baguette \
  --data-network 5g --cellular-bars 4 --wifi-bars 3 \
  --battery-state charged --battery-level 100

baguette status-bar clear --udid 5A1B…
```

## Dispatch path

```
StatusBarOverride (Domain value)         simctl argv tail
   .overrideArguments  ───────────────▶  --batteryState charged --batteryLevel 68 …
        │                                       │
        ▼                                       ▼
   StatusBar.override(_:)  ──▶  SimctlStatusBar  ──▶  Subprocess.run(
   StatusBar.clear()                                   /usr/bin/xcrun,
                                                       ["simctl","status_bar",udid,"override", …])
```

- **`StatusBarOverride`** (`Domain/StatusBar/StatusBarOverride.swift`) is
  the unit-testable core. `overrideArguments` projects the set fields to
  simctl's argv in a stable order, clamping `wifiBars` to 0…3,
  `cellularBars` to 0…4, and `batteryLevel` to 0…100 so a bad slider
  value can't make the spawn fail.
- **`StatusBar`** (`Domain/StatusBar/StatusBar.swift`) is the `@Mockable`
  surface; `Simulator.statusBar()` vends a fresh handle.
- **`SimctlStatusBar`** (`Infrastructure/StatusBar/SimctlStatusBar.swift`)
  is the adapter: argv assembly + the `Subprocess` exit handshake. The
  irreducible `xcrun` spawn lives in the already-vendored `HostSubprocess`
  (`LogStream`'s collaborator), so the adapter is unit-covered end-to-end
  via `MockSubprocess` — only the real spawn is integration-only.

## Where the flag spellings come from

The `--dataNetwork` / `--wifiMode` / `--cellularMode` / `--batteryState`
value sets and the `0-3` / `0-4` / `0-100` ranges are verified against
`xcrun simctl status_bar … override` help output (Xcode 26). The Domain
enums carry these as their raw `wireName`s, so the CLI
`ExpressibleByArgument` conformances, the HTTP body parser, and the
argv projection all share one spelling table — change a spelling in one
place (`StatusBarOverride.swift`) and every entry point follows.

## Browser panel

The focus page (`/simulators/<udid>`) gains a signal-bars toolbar button
that opens a floating glass **Status Bar** card (mirror of the camera
card). `Resources/Web/sim-status-bar.js` builds the controls and is a
**dumb sender**:

- **On open** it `GET`s the current overrides and populates the controls,
  so the card reflects the device.
- **On change** it debounces (250 ms) and `POST`s **only the field that
  changed** — changing Wi-Fi bars sends `{"wifiBars":N}` alone, so the
  data-network indicator can't flip to "5G" and the battery isn't
  re-applied. "Clear overrides" sends `DELETE`.

There is no client-side preview — the live device stream shows the
result. All domain logic (the `list` parse, argv, clamping, validation)
stays in Swift.

## Files

```
Sources/Baguette/
├── Domain/StatusBar/
│   ├── StatusBarOverride.swift        value type + enums + argv projection
│   └── StatusBar.swift                @Mockable surface + StatusBarError
├── Infrastructure/StatusBar/
│   └── SimctlStatusBar.swift          simctl adapter over Subprocess
├── Infrastructure/Simulator/
│   └── CoreSimulator.swift            statusBar() → SimctlStatusBar
├── Infrastructure/Server/
│   └── Server.swift                   POST/DELETE routes + parse/apply helpers
├── App/Commands/
│   └── StatusBarCommand.swift         baguette status-bar override|clear
├── App/RootCommand.swift              registers StatusBarCommand
└── Resources/Web/
    ├── sim-status-bar.js              StatusBarPanel (dumb sender)
    ├── sim-native.html                toolbar button + card chrome + CSS
    ├── sim-native.js                  lazy-mount + toggle wiring
    └── sim.html                       <script> tag
```

## Known limits

- **Write-only.** simctl exposes `status_bar … list`, but there's no
  reliable "what's currently overridden" probe we surface — the panel
  starts from sensible defaults and never reads back. Re-applying or
  clearing is always safe.
- **`hide` only on `dataNetwork`.** simctl can hide the data-network
  indicator but not individually hide the battery or Wi-Fi glyphs; use
  `clear` to drop all overrides at once.
- **Survives until reboot, scoped to the device.** Overrides persist
  across app launches but are cleared by a simulator erase/reboot.
- **No batched multi-device.** One UDID per invocation, like every
  other per-simulator verb.

## Extension points

- **`status-bar list`** — a read verb wrapping `simctl status_bar …
  list` would let the panel hydrate from the device's current overrides
  instead of static defaults.
- **Presets** — a `--preset demo` flag (9:41 / full bars / 100%) is a
  thin convenience over the existing override path.
