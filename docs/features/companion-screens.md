# Companion screens

A simulator can drive more than its own glass. Two of those extra
screens are worth looking at next to the phone:

- **CarPlay** — an external display the host attaches to the *same*
  device. It is a second framebuffer plane on the same udid, reached
  with `?display=carplay`.
- **Apple Watch** — not a plane at all. A paired watch is a device of
  its own, with its own udid, its own boot state and its own
  framebuffer, so it streams down the ordinary phone-display route
  against that udid.

In focus mode (`/simulators/<udid>`) both are offered from the
**screens rail** on the right edge, above the plugins rail.

## Why it is a rail and not a pane that's just there

The CarPlay pane used to mount on every page load. That was worse than
clutter: `?display=carplay` doesn't only *read* the CarPlay plane, it
asks the host to **attach one** (`ExternalDisplays.enableCarPlay()`,
which drives Simulator.app's I/O → External Displays menu). So opening
a device's tab to look at it changed the device.

Nothing is asked for now until you open a pane, and the rail only
offers a screen the host already reports as attached — so the enable
path is never reached by accident.

## What the rail shows

Every screen keeps a slot whether or not it is there. A rail that hid
what you don't have could never tell you it exists, and "how do I get
one of these?" is the question a new user actually has.

| State | Slot | Click |
| --- | --- | --- |
| attached / booted | lit | opens the pane |
| paired watch, not booted | dimmed | **Boot** button, then opens the pane |
| not there | dimmed | how to attach one, plus **Check again** |

The instructions are the real ones:

- **CarPlay** — Simulator.app → I/O → External Displays → CarPlay.
- **Apple Watch** — create a watch simulator in Xcode, then
  `xcrun simctl pair <watch-udid> <phone-udid>`.

Which panes you had open is remembered in `localStorage`
(`baguette.companionScreens`). A remembered pane whose screen has since
gone away is skipped rather than opened onto a dead socket.

## The route

```
GET /simulators/:udid/companion-screens.json
```

```json
{
  "carplay": { "available": true },
  "watch": {
    "available": true,
    "udid": "…",
    "name": "Apple Watch Series 11 (46mm)",
    "state": "Booted"
  }
}
```

Absence is an answer, not an error — a device with neither is the
common case, so only an unknown udid is a failure (404). Both probes
fail closed: `simctl io enumerate` refusing to run reads as "no CarPlay",
and an unreadable pairing table reads as "no watch", because a rail
that can't say what's attached should offer nothing rather than offer a
pane that can't open.

Browser-facing only. It reports what the host has attached to a device,
which is the sort of thing a plugin should have to declare a capability
for, and no capability covers it — so it rides the browser-trust check
alone and is not plugin-reachable.

### Where the pieces live

| Layer | Type | Job |
| --- | --- | --- |
| Domain | `CompanionScreens` | the answer, and its JSON projection |
| Domain | `PairedWatch` / `WatchPairing` | one phone's side of the pairing table |
| Domain | `SimctlPairs` | pure parser over `simctl list pairs -j` |
| Infrastructure | `SimctlWatchPairing` | the spawn, and nothing else |
| Infrastructure | `HostExternalDisplays` | the CarPlay probe (pre-existing) |
| Web | `screens/companion-screens.js` | availability + instructions as a value |
| Web | `sim-screens.js` | the rail, the card, the remembered choice |

`sim-screens.js` owns the buttons and the state card. It does **not**
own the streams — opening a pane calls back into `sim-native.js`, which
owns every `StreamSession` on the page.

## Layout

Both rails share one right-edge stack (`.right-rails`) so they can't
overlap. That container is deliberately centred with
`justify-content: center` on a full-height box rather than
`transform: translateY(-50%)`: a transformed element becomes the
containing block for `position: fixed` descendants, and the plugin
panel and its flyout are both fixed and mounted inside it.

How much of the window each pane gets is one set of variables on
`#simNativeView`, keyed off `data-companions` (a space-separated list
of the open panes) and the window width:

| | device | each companion |
| --- | --- | --- |
| nothing open | `96vw` | — |
| one pane | `46vw` | `42vw` |
| both panes | `34vw` | `32vw` |
| ≤ 960px (stacked) | `92vw` | `92vw` |

Below 960px the row becomes a column, so height becomes the contended
axis instead and the two share it 55 / 45 in the phone's favour.

## Driving the watch

A watch pane has no bezel chrome to hang overlay buttons off, so the two
hardware buttons sit in a pill under it. Both ride the ordinary `button`
envelope down the watch's own socket — `DeviceButton` already carried
`digital-crown` / `side-button` / `left-side-button` on HID page 12, so
nothing new was needed on the wire.

| You want | Do this |
| --- | --- |
| tap something | click it |
| scroll a list | **drag** on the face |
| back to the watch face / app grid | **Crown** (press again for the grid) |
| Control Centre | **Side** |
| Siri, Wallet, power menu | not reachable — those are hold and double-press |

Verified against a real paired Series 11: tap launches an app, Crown
walks face → grid, Side opens Control Centre, drag scrolls Settings.

## Known limits

- **The crown presses but doesn't turn.** Rotation is a separate HID
  axis that baguette doesn't drive, so the usual watchOS scroll gesture
  isn't available. Dragging on the face scrolls instead.
- **The scroll wheel does nothing over a watch pane.** `WheelGestureSource`
  emits a two-finger pan, which watchOS ignores in a list. Drag instead.
  Reaching for the wheel is the instinctive move, so this one surprises.
- Only a plain press is sent. The double-press (Wallet) and the holds
  (Siri on the crown, power menu on the side button) would need a
  `duration` and a repeat, which the buttons don't offer yet.
- CarPlay streams MJPEG regardless of the format picker. It is a mostly
  static screen and H.264 starves without an IDR cadence the guest
  doesn't produce; MJPEG paints the first seed and holds it.
- The rail probes once per page load, plus whenever you press **Check
  again**. Attaching a display in Simulator.app does not push anything
  to the browser.
