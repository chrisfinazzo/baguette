# Shake gesture

Deliver a motion shake to a booted simulator — the same signal as
Simulator.app's **Device → Shake** menu. iOS surfaces it to the
frontmost app's responder chain as `motionBegan(_:with:)` /
`motionEnded(_:with:)` with `UIEventSubtypeMotionShake` (the standard
"shake to undo" / shake-to-report trigger). Three entry points share one
dispatch:

- `baguette shake --udid <UDID>` — CLI.
- `POST /simulators/<UDID>/shake` on `baguette serve` — HTTP route.
- The **serve UI toolbar** — a shake button next to Home / App switcher
  (mirrors the rotate button; see [Browser](#browser) below).

There is **no** gesture-WebSocket / `baguette input` stdin verb: shake
is a device action (like `orientation`, `status-bar`, `location`), not a
pointer/HID gesture, so it doesn't ride the `GestureRegistry` →
`IndigoHIDInput` pipeline.

## Platform scope

baguette only drives **iOS** simulators. watchOS / tvOS have no shake
concept, and CarPlay is a display surface, not a motion target — so
shake is iOS-only by design. It fails cleanly (device-not-booted /
unknown-udid) rather than silently no-op'ing elsewhere.

## Dispatch — `simctl spawn notifyutil`

`Simulator.shake().shake()` runs:

```
xcrun simctl spawn <udid> notifyutil -p com.apple.UIKit.SimulatorShake
```

`com.apple.UIKit.SimulatorShake` is the private Darwin notification
UIKit's shake detection observes. A `notify_post` from the **host** Mac
lands in the host's `notifyd`, which the iOS guest never sees — so the
notification is posted by `notifyutil` spawned *inside* the simulator
runtime via `simctl spawn <udid>`, where its `notify_post` reaches the
**guest's** `notifyd` and UIKit fires the motion event on the frontmost
responder.

This mirrors the widely-used in-app UI-test trick
(`notify_post("com.apple.UIKit.SimulatorShake")`), but posts from a
guest-spawned helper so no code has to run inside the target app.

### Why not the GSEvent / PurpleWorkspacePort path?

Simulator.app itself synthesises shake via `-[SimDevice
gsEventsSendShake]` — a `kGSEventMotionBegin` (1020) GSEvent over
`PurpleWorkspacePort`, the same transport baguette's `orientation` uses.
That path is more "native", but unlike the orientation type-50 layout
(documented and unit-tested in `OrientationEvent`), the shake body bytes
(motion subtype / shake-state) aren't documented — reverse-engineering
them risks a `backboardd` crash on a wrong byte. The `simctl spawn`
notification path is documented, carries zero mach byte-layout risk, and
is unit-testable end-to-end. If a future need demands the GSEvent path
(e.g. a runtime without `notifyutil`), add a `PurpleEventShake`
alongside `PurpleEventOrientation` and swap it in `CoreSimulator.shake()`.

## Layering

| Layer | File | Responsibility |
|-------|------|----------------|
| Domain value | `Domain/Shake/MotionShake.swift` | Owns the notification name + `simctlArguments(udid:)`; `ShakeError` |
| Domain abstraction | `Domain/Shake/Shake.swift` | `@Mockable protocol Shake { func shake() async throws }` |
| Infrastructure | `Infrastructure/Shake/SimctlShake.swift` | argv assembly + `Subprocess` exit handshake |
| Factory | `Infrastructure/Simulator/CoreSimulator.swift` | `func shake() -> any Shake` |
| CLI | `App/Commands/ShakeCommand.swift` | `baguette shake --udid` |
| Serve route | `Infrastructure/Server/Server.swift` | `POST /…/shake` + pure `applyShake` |

The `Foundation.Process` plumbing is the already-vendored
`HostSubprocess` (shared with `LogStream` / `SimctlLocation`), so
`SimctlShake` is unit-covered end-to-end via `MockSubprocess`; only the
real spawn is integration-only.

## Wire

CLI (no options beyond the target):

```bash
baguette shake --udid <UDID>
```

HTTP:

```
POST /simulators/<UDID>/shake        → {"ok":true}
                                       404 unknown udid
                                       500 shake failed (simctl error)
```

## Browser

The `serve` native UI exposes shake as a momentary toolbar button
(`sim-native.html`) next to Home / App switcher, wired to
`window.__nativeShake` in `sim-native.js`. Exactly like the rotate
button, it's a **dumb sender**: a fire-and-forget
`POST /simulators/<udid>/shake`, no HID codes or domain logic on the
client. Unlike rotate there's no visual state to mirror — the motion
event lives entirely inside the guest — so the handler doesn't touch the
bezel. The button sits inside `#nativeToolScroll`, so it's automatically
dimmed/disabled until the guest is live (same gating as every other
toolbar control).

## Known limits

- **Single shake per call.** No intensity or repeat count — one
  `motionShake` per invocation. Loop client-side if you need a burst.
- **Depends on `notifyutil` in the runtime.** If a future iOS runtime
  drops the host `notifyutil` from the guest-spawn path, the spawn exits
  non-zero and the call reports `simctlFailed`; switch to the GSEvent
  path noted above.
- **Frontmost-responder only.** iOS delivers `motionShake` to the first
  responder chain; a backgrounded app won't see it.
