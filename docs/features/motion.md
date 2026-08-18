# Motion

Make a simulator's apps read motion — `CMMotionActivity` (walking,
running, cycling, automotive), `CMPedometer` counters (steps, distance,
pace, cadence), and `CMMotionManager` samples (accelerometer, gyro,
device motion). Three entry points share one path:

- `baguette motion start --udid <UDID> [--activity <kind>] [--speed <m/s>]` /
  `baguette motion set --udid <UDID> --activity <kind>` /
  `baguette motion stop --udid <UDID>` — CLI.
- `POST /simulators/:udid/motion` (JSON body) /
  `GET` (read back) / `DELETE` (stop) — served by `baguette serve`.
- The focus-mode **Location** card's **Drive motion sensors** toggle. Once
  it's on, the walk joystick and route speeds the card already posts
  classify the activity — no second control surface.

Unlike [`location`](location.md), **there is no `simctl` verb behind
this**. All three CoreMotion surfaces report unavailable in a stock
simulator, so baguette injects `VirtualMotion.dylib` into apps and answers
from an intent it publishes. That has one consequence worth putting first:

> **Only apps launched _after_ motion starts see anything.** dyld inserts
> libraries at exec time. Relaunch the target app, or
> `xcrun simctl launch --terminate-running-process <udid> <bundle-id>`.

## Why this needs a dylib at all

The platform refuses, at a level nothing on the host can reach. Measured
on iOS 26.5 and 27.0, from a real installed app with Motion permission
granted (`authorizationStatus == 3`):

| Call | Stock simulator |
| --- | --- |
| `CMMotionActivityManager.isActivityAvailable()` | `false` |
| `startActivityUpdates` | locationd: *"Cannot subscribe to motion activity updates, motion activity is not available"* |
| `queryActivityStartingFromDate:` | `CMErrorDomain 104`, no results |
| `CMPedometer.isStepCountingAvailable()` | `false` |
| `CMMotionManager.isAccelerometerAvailable` | `false` |

Both CoreMotion **and** locationd gate on bit 23 of a hardware-capability
word derived from the device's HW type, and a simulated device is an
"Unsupported HW type" — so every motion capability reads 0. The runtime
even ships a simulation hook for this
(`-[CMActivityManager simulateMotionState:withState:withHint:]` →
`kCLConnectionMessageMotionStateSim` → `CLMotionCoprocessor::setMotionStateSim`);
locationd accepts the message and it changes nothing, because the
availability gate sits upstream of it. The only override preference on
that path is `OverrideMotionCapEclipseService`, which controls the AOP
suppression service, not activity.

So the honest options were "document it as impossible" (as
[`CLHeading`](location.md#course-is-not-heading) is) or lie convincingly
*inside the app's own process*. baguette already injects
[`VirtualCamera.dylib`](camera.md) for the same reason, so the channel
existed.

## Surface

```
baguette motion start --udid <UDID> [--activity <kind>] [--speed <m/s>] [--confidence low|medium|high]
baguette motion set   --udid <UDID> [--activity <kind>] [--speed <m/s>]
baguette motion stop  --udid <UDID>
```

`<kind>` is `stationary | walking | running | cycling | automotive`. An
unknown one is a parse error, never a silent `unknown` — that would look
like the feature was working.

`--speed` is optional: each kind has a representative pace (the same
presets the browser's Walk mode offers), so `--activity running` alone
means a plausible run rather than a run at 0 m/s. Plain `motion start`
means walking.

`start` and `set` do the same publish; they're separate verbs because
"change what it's doing" reads differently from "turn this on", and only
`start` mentions the relaunch.

## Wire JSON

`POST /simulators/:udid/motion` accepts two spellings:

```json
{ "activity": "running", "speed": 3.6, "confidence": "high" }
{ "speed": 6 }
```

The first names the kind outright, as the CLI does. The second names only
how fast the device is moving and **the kind is classified server-side** —
that's what keeps `MotionKind`'s thresholds out of the frontend. The
browser uses the second, exactly as it already posts walk vectors.

Both return the current state, which is also what `GET` answers:

```json
{ "ok": true, "active": true, "activity": "walking",
  "steps": 24, "metres": 18.0, "speed": 1.40 }
```

`DELETE /simulators/:udid/motion` parks the device as stationary and
disarms. A body naming no activity and carrying no speed returns `400`; an
unknown udid `404`; a build with no bundled dylib `500`.

Unlike location — which has no `GET`, because `simctl` can't report the
active position — motion **can** be read back: the state is baguette's own.

## Dispatch path

```
   Host (Swift, tested)                          iOS Simulator app
┌──────────────────────────┐                  ┌────────────────────────┐
│ MotionKind.from(speed:)  │                  │ CMMotionActivityManager│
│ MotionProfile(kind:speed:)│                 │ CMPedometer            │
│ MotionLedger.banking()   │                  │ CMMotionManager        │
│ MotionIntent.encoded()   │                  └───────────▲────────────┘
└───────────┬──────────────┘                              │ swizzled
            │  /tmp/BaguetteMotion-<udid>.json            │
            ▼  (shared /tmp, as the camera uses)          │
      ┌───────────┐        launchctl setenv        ┌──────┴───────────┐
      │  Motion   │  ───── DYLD_INSERT_LIBRARIES ─▶│ VirtualMotion    │
      │ @Mockable │                                │ .dylib           │
      └───────────┘                                │ (integrates the  │
            ▲                                      │  intent locally) │
  location walk/route ── drives when armed ──┘     └──────────────────┘
```

The intent file is **scoped per simulator** (`/tmp/BaguetteMotion-<udid>.json`).
Every simulator sees the host's `/tmp`, so one shared file would mean a
publish for one device replacing what an injected app on another is still
reading. The dylib derives the same path from its own `SIMULATOR_UDID`, which
the simulator sets in every process it launches; with no UDID it reports no
motion rather than guessing at another device's file.

### Why an intent, not a sample stream

A pedometer accumulates monotonically and `CMMotionManager` delivers at up
to 100 Hz. Neither can be fed sample-by-sample across a file boundary, so
the host publishes a **description** — *running at 3.6 m/s since T, with N
steps already accrued* — and the dylib integrates from it.

Every judgement call is resolved host-side and arrives pre-computed:
stride length, cadence, gait amplitude (`MotionProfile`), the raw
`CLMotionActivity.type` and confidence values (`MotionKind`), and the
running totals (`MotionLedger`). The dylib does arithmetic only. Same
division of labour the browser has with the Swift side.

`stepsBefore` / `distanceBefore` are what make the pedometer cumulative
across a walk → stop → walk sequence instead of resetting every time the
joystick moves.

## Driving it from a walk

Motion is **opt-in**. Arming rewrites a simulator-wide
`DYLD_INSERT_LIBRARIES` that only takes effect on the next app launch, so
it never happens as a side effect of moving the device. Once it *is* on,
the location routes drive it:

| Location request | Motion becomes |
| --- | --- |
| walk vector at 1.4 m/s | `walking` |
| walk vector at 6 m/s | `cycling` |
| route with `speed: 20` (or untuned — simctl's default) | `automotive` |
| bare `{latitude,longitude}` point | `stationary` |
| `DELETE …/location` | `stationary` |

Pinning a point parks it because that's exactly the moment the device
stops travelling — locationd drops `course` to `-1` — so an app shouldn't
keep reading a walk. The totals already walked survive.

Thresholds are pinned to the browser's own speed presets (`Walk 1.4 ·
Run 3.5 · Cycle 6 · Drive 13.4 · Highway 29`), so the preset a user picked
is the activity their app observes. A republish is skipped when the kind
is unchanged and the speed moved less than 0.1 m/s — the same epsilon
`sim-location.js` throttles its own sends with — but a kind change always
republishes, however small the speed step.

## What the dylib fabricates, and the ABI notes worth preserving

CoreMotion's data classes have no public initialisers, so each is built
through its private designated initialiser. **Every detail below was
measured against booted iOS 26.5 / 27.0 runtimes, not read from a header**
— the failure mode for guessing is a crash or silent zeros. They live in
`Injected/VirtualMotion/Sources/VirtualMotionFactory.m`.

- **`CMAccelerometerData` / `CMGyroData` / `CMMagnetometerData` take their
  `{fff}` struct BY VALUE.** It's 12 bytes, so arm64 passes it in
  registers; handing over a pointer reads zeros *and* displaces the
  trailing `double` timestamp.
- **`CMGyroData`'s initialiser takes degrees per second**, while the public
  `rotationRate` property returns radians — feed it 0.25 and it reads back
  0.004. `CMDeviceMotion`'s `rotationRate` is *already* radians. Two
  conventions in one framework.
- **`CMDeviceMotion`'s quaternion is stored `w,x,y,z`** while the public
  `CMQuaternion` is `x,y,z,w`. Its `userAcceleration` triple is at `+32`
  and `rotationRate` at `+44`.
- **`gravity` is derived from attitude and cannot be set.** An identity
  attitude yields `(0,0,-1)`; a 90° rotation about x yields `(0,-1,0)`. A
  level attitude is what makes gravity look like an upright phone.
- **`CMDeviceMotion` ignores its own `timestamp:` argument.** The value
  lives in `CMLogItemInternal.fTimestamp`, reachable through `CMLogItem`'s
  `_internalLogItem` ivar.
- **`CMMotionActivity` must go through `-initWithMotionActivity:`.** Poking
  ivars after a bare `+alloc` *looks* fine — the boolean getters read back
  correctly — then crashes in `-description`, `-copy`, `-timestamp` and
  `NSKeyedArchiver`, because `CMLogItem`'s own state is never initialised.
  Any app doing `NSLog(@"%@", activity)` would take the app down.
  Its `CLMotionActivity` field offsets: type `+0`, confidence `+4`,
  timestamp `+40`, startTime `+80` (seconds since the 2001 reference date);
  the struct's size is derived at runtime from the `fState`/`fEndTime` ivar
  gap rather than hardcoded.
- **`CLMotionActivity.type` values are measured, and the enum is not
  dense:** `0` unknown, `1` stationary, `4` walking, `5` automotive,
  `6` cycling, `8` running. `2` also reads as stationary and `3`/`7`/`9`
  read as no flags at all, so only those six are trusted.
- **`CMPedometerData` is a plain `NSObject`** with object-typed ivars, so
  KVC on them is enough — no superclass to trip over.

### The self-check

`VMFactorySelfCheck` builds one of each object at load and verifies the
values through the public API. **A surface that fails verification is not
hooked**, so a future iOS layout change leaves apps seeing the platform's
honest "unavailable" rather than fabricated garbage. The result is logged:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.motion"'
# [VirtualMotion] activity hooks installed
# [VirtualMotion] pedometer hooks installed
# [VirtualMotion] motion-manager hooks installed (accelerometer=1 deviceMotion=1)
```

That's also the fastest way to confirm injection is live: launch anything,
even Settings, and look for those lines.

The dylib logs through `os_log`, never `NSLog`. It is loaded into *every*
process launched while motion is armed — including the `launchctl` baguette
spawns to read `DYLD_INSERT_LIBRARIES` — and a banner on stderr can come
back as part of the value being read.

## Sharing `DYLD_INSERT_LIBRARIES`

That variable is one string for the whole simulator, and baguette now
injects two dylibs (this and the [virtual camera](camera.md#sharing-dyld_insert_libraries)).
Arming is a read-modify-write through the pure `InjectedDylibs`, matching
entries by **dylib filename** because every release installs under a fresh
sha-keyed directory. Starting motion while the camera is armed keeps both;
stopping either leaves the other alone.

`InjectedDylibs.parsing` keeps only absolute `.dylib` paths, and that
filtering is load-bearing: a simulator's stdout channel carries leftover
output from previously spawned processes, so the read can come back as log
noise with the real value appended.

## Two capabilities refused on purpose

- **Floor counting** (`isFloorCountingAvailable`) — needs barometric
  altitude, which no published intent carries. Reporting a fabricated
  storey count would be worse than saying no.
- **The magnetometer** (`isMagnetometerAvailable`) — a magnetic-field
  vector implies a compass heading, and `CLHeading` is
  [documented as impossible](location.md#course-is-not-heading) in the
  simulator. Gait acceleration follows from walking; a bearing doesn't.

## Adding a new motion surface

`CMAltimeter` (relative altitude / pressure) is the obvious next one:

1. **Probe first.** Dump the data class's ivars and initialisers inside a
   booted sim and verify a fabricated instance reads back through the
   public API — including `-description`. Guessing an ABI here crashes the
   app under test.
2. **Domain** — extend `MotionProfile` with whatever constants the surface
   needs, resolved host-side, plus a test.
3. **Intent** — add the fields to `MotionIntent.encoded()` (its
   byte-for-byte test pins the shape).
4. **Dylib** — a factory function in `VirtualMotionFactory.m` with its
   measured ABI notes, a `VMFactoryHealth` flag, and hooks installed only
   when that flag verified.
5. **Docs** — record what you measured here, and be explicit about anything
   you refuse to fabricate.

## Known limits

- **Apps must be launched after arming.** dyld inserts at exec time; a
  running app sees nothing until it's relaunched. `motion set` reaches an
  already-running app fine — only the initial arm needs the relaunch.
- **Injected, not simulated.** This lies to the app's own process. Nothing
  outside it (SpringBoard's own step tracking, Health) sees any of it, and
  a device that isn't running an injected app has no motion at all.
- **No floors, no magnetometer** — see above.
- **Gait is plausible, not physical.** A sine at the profile's cadence with
  a level attitude: enough for "is the device moving, how fast, in what
  mode". It won't satisfy an app doing real dead-reckoning or step
  detection from raw accelerometer peaks.
- **`CMMotionActivityManager`'s lite/periodic variants aren't hooked** —
  `startActivityLiteUpdates` and `startPeriodicActivityUpdates` still
  report unavailable.
- **Private-layout dependency.** The fabrication relies on measured ivar
  layouts. The self-check turns a future iOS change into "unavailable"
  rather than a crash, but that *is* the trade-off of mocking private
  internals — the same one the [virtual camera](camera.md) makes.
