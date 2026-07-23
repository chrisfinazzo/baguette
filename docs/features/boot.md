# Booting a device

Every baguette surface that shows a simulator can also start one. The
CLI has `baguette boot`, the list page and the device farm have boot
buttons, and — as of this feature — so does **focus mode**
(`/simulators/<udid>`), which is where a deep link lands you.

Focus mode used to assume a running guest. Opening a tab on a device
that wasn't booted mounted the bezel, opened a stream WebSocket that
would never carry a frame, and left you looking at a black rectangle
with no explanation and no way forward except navigating back to the
list. Now the device's own screen carries the boot control.

## Entry points

| Surface | Invocation |
|---------|------------|
| **CLI** | `baguette boot --udid <UDID>` |
| **HTTP** | `POST /simulators/<UDID>/boot` → `{"ok":true}`, or `{"ok":false,"error":"…"}` with a 404 (unknown udid) / 500 (boot refused) |
| **Focus mode** | Open `/simulators/<UDID>` on a shutdown device — the screen shows **Boot** |
| **List page** | `/simulators` — boot / shutdown buttons per row |
| **Device farm** | `/farm` — per-tile and bulk boot |

All of them land on the same `Simulator.boot()`, which tries
`bootWithOptions:error:` with `{"persist": true}` first (headless boot
that survives the client disconnecting) and falls back to
`bootWithError:`. See `Sources/Baguette/Infrastructure/Simulator/CoreSimulator.swift`.

## Focus-mode flow

`sim-native.js` already fetched `/simulators.json` on load to resolve
the device's name and runtime; it now reads `state` from the same
response. No new endpoint, no change to the definition payload.

```
GET /simulators/<udid>          ← deep link
      │
      ▼
GET /simulators.json            ← name · runtime · state
      │
      ├── state == "Booted" ────▶ startSession() + reset to portrait
      │
      └── anything else ───────▶ power card on the device's glass
                                    │
                     ┌──────────────┴───────────────┐
                     │ off       Boot button        │◀── polls every 4 s
                     │ booting   POST /boot, poll   │    for a boot
                     │ starting  stream open,       │    started elsewhere
                     │           awaiting frame 1   │
                     │ gone      no such device     │
                     └──────────────┬───────────────┘
                                    ▼
                     first frame paints → card clears,
                     toolbar re-enables
```

The card lives inside the SDK bezel's `screenArea`, so it inherits the
screen cutout's rounded clip and looks like a powered-off phone rather
than a modal over the page. It is black in both light and dark themes
for the same reason.

### The four phases

- **off** — the device is `Shutdown` / `ShuttingDown` / `Creating`. Shows
  the Boot button, and polls `/simulators.json` every 4 s so a boot
  started from anywhere else (`baguette boot`, another tab, Xcode,
  `simctl`) is picked up without a click.
- **booting** — `POST /boot` accepted, or the device was already
  `Booting` when the tab opened (in which case no second boot is sent).
  Polls once a second for up to 3 minutes.
- **starting** — CoreSimulator reports `Booted`. That's earlier than
  SpringBoard being on screen, so the stream opens but the card stays up
  until a frame actually paints. A 15 s fallback clears it regardless:
  `Screen` is pure pass-through and only emits when SimulatorKit
  composites, so a device sitting on a static screen may not produce a
  frame promptly.
- **gone** — `definition.json` 404s, i.e. the udid isn't in the device
  set at all. Nothing to boot; the card says so instead of leaving the
  tab blank.

### Toolbar gating

While the card is up, `#simNativeView` carries `data-power="<phase>"`,
which dims and disables `#nativeToolScroll` and `#nativeFormatPicker`.
Rotate, camera, status bar, location, logs, AX inspector, home,
screenshot and app switcher all need a live guest. The back link, theme
toggle and sidebar-view toggle stay active — those are how you leave a
device that won't boot.

The portrait reset that focus mode fires on load is gated the same way:
an unbooted device has no `PurpleWorkspacePort` to receive the GSEvent.

## Where the state string comes from

`/simulators.json` projects `SimulatorState.description` verbatim:
`"Creating"`, `"Shutdown"`, `"Booting"`, `"Booted"`, `"ShuttingDown"`
(`Sources/Baguette/Domain/Simulator/Simulator.swift`). The browser
compares against `"Booted"` and treats everything else as not-ready, so
a new state added on the Swift side degrades to "show the Boot button"
rather than to a broken page.

## Adding a lifecycle control to focus mode

1. The route probably exists — check `Server.registerRoutes`; `boot` and
   `shutdown` are both already there via `Server.lifecycle`.
2. Read whatever state you need from `fetchDeviceMeta` in
   `sim-native.js`; extend its return value rather than adding a fetch.
3. Render through `renderPowerCard(phase, detail)` — add a phase to the
   `copy` table and, if it needs a spinner, to the `SPIN_GLYPH` branch.
4. Style it in the `--- Power card ---` block of `sim-native.html`. The
   card is a container (`container-type: inline-size`), so type sizes
   use `cqw` and track the rendered bezel, not the viewport.
5. Keep the frontend a dumb sender: no state machine duplicated from
   Swift, no derived capability flags. It reads a state string and posts
   a verb.

## Limits

- Boot progress is binary. CoreSimulator reports `Booted` the moment the
  device's services are up, which is well before SpringBoard renders;
  there's no progress fraction to show, hence "Starting…" plus a
  first-frame wait.
- The 3-minute boot timeout is a guess at "something is wrong", not a
  CoreSimulator limit. A genuinely slow cold boot on a loaded Mac can
  exceed it; the card then re-offers Boot rather than failing hard.
- Shutdown has no focus-mode control. Closing the tab leaves the device
  running (the boot is `persist: true` deliberately) — use the list
  page, the farm, or `baguette shutdown`.
- The 4 s idle poll runs only while the Boot button is showing. Once the
  stream is live, focus mode doesn't watch for the device going away
  underneath it; the stream simply stops delivering frames.
