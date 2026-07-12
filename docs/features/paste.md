# Paste & clipboard

Move text and images between the host Mac and the booted simulator's
pasteboard. Pasting **into** the sim is the path around `type`'s
US-ASCII keystroke limit, so emoji, accents, and non-Latin scripts all
land intact; copying **out** of the sim ferries whatever it last
copied onto the host Mac's clipboard.

**Host → sim (paste):**

- `baguette paste --udid <UDID> --text "<text>" [--no-press]` —
  set the pasteboard, then press Cmd+V (`--no-press` stops after the
  set, for apps that read `UIPasteboard` directly).
- `baguette clipboard sync --udid <UDID>` — copy the host Mac's
  pasteboard onto the simulator **full-fidelity, images included**.
- Wire JSON `{ "type": "paste", "text": "…" }` on `baguette serve`'s
  stream WebSocket and `baguette input`'s stdin.
- Browser — Cmd+V (or Ctrl+V) while the device screen has focus
  pastes the host clipboard automatically.

**Sim → host (copy):**

- `baguette clipboard copy --udid <UDID>` — copy the simulator's
  current pasteboard onto the host Mac's clipboard **full-fidelity,
  images included** (the mirror of `clipboard sync`; a pure ferry, no
  keystroke).
- `baguette clipboard get --udid <UDID>` — print the sim's pasteboard
  text raw to stdout (pipes byte-faithfully, like `pbpaste`).
- Wire JSON `{ "type": "copy" }` on the stream WebSocket and
  `baguette input`'s stdin — presses Cmd+C sim-side (so the focused
  field copies its selection), then ferries; `"press": false` skips
  the keystroke for a pure ferry.
- Browser — Cmd+C (or Ctrl+C) while the device screen has focus
  copies the focused field's selection and ferries it onto the host
  Mac's clipboard.

## Why a pasteboard, not keystrokes

The browser used to forward Cmd+V as a raw HID chord — which iOS
dutifully received and pasted **its own, empty pasteboard**. Nothing
in the stream pipeline syncs the host clipboard the way Simulator.app
does, so the paste was a silent no-op. `paste` closes the loop
server-side: put the text on the sim's pasteboard first, then press
Cmd+V.

## Wire JSON

```json
{ "type": "paste", "text": "héllo 🥖 — any unicode" }
{ "type": "paste", "text": "clipboard only", "press": false }
{ "type": "copy" }
{ "type": "copy", "press": false }
```

- `paste.text` — required. Any unicode; UTF-8 on the wire.
- `paste.press` — optional bool, default `true`. When true, Cmd+V is
  pressed after the pasteboard is set (the set must succeed first —
  a failed `pbcopy` never fires the keystroke). `false` = set-only.
- `copy.press` — optional bool, default `true`. When true, Cmd+C is
  pressed sim-side (so the focused field copies its selection) before
  the pasteboard is ferried onto the host Mac (`pbsync <udid> host`).
  `false` = ferry-only (whatever the sim already holds, no keystroke).

Acks: on `baguette input`, the usual one-line `{"ok":true}` /
`{"ok":false,"error":"…"}`. On the stream WS, a typed reply frame
(like `describe_ui_result`) so the browser's text-frame router can
claim it:

```json
{ "type": "paste_result", "ok": true }
{ "type": "paste_result", "ok": false, "error": "xcrun simctl pasteboard command exited 1" }
{ "type": "copy_result", "ok": true }
{ "type": "copy_result", "ok": false, "error": "xcrun simctl pasteboard command exited 1" }
```

## Dispatch path

`paste` is **not** a `Gesture` and is not in `GestureRegistry`:
setting the pasteboard is an async host call, out of reach of the
sync, `Input`-only `Gesture.execute`. Both wire entry points
intercept `paste` lines ahead of the gesture pipeline (the
`describe_ui` shape) via one shared `App/PasteDispatch`:

```
{"type":"paste",…} ─► PasteDispatch ─► Paste.execute(pasteboard:input:)
                                          1. Pasteboard.setText(text)
                                             └► SimctlPasteboard ─► xcrun simctl pbcopy <udid>   (text over stdin)
                                          2. press? KeyV + [command]
                                             └► Input.key ─► IndigoHIDMessageForHIDArbitrary     (page 7, usage 0x19)

{"type":"copy",…}   ─► CopyDispatch  ─► Copy.execute(pasteboard:input:)
                                          1. press? KeyC + [command]
                                             └► Input.key ─► IndigoHIDMessageForHIDArbitrary     (page 7, usage 0x06)
                                          2. settle ~200ms, then Pasteboard.syncToHost()
                                             └► SimctlPasteboard ─► xcrun simctl pbsync <udid> host
```

`copy` is the interactive mirror of `paste`, so it gets its own
`Domain/Pasteboard/Copy` value + `App/CopyDispatch`: press Cmd+C
(the focused field copies its selection into the sim's pasteboard),
let the guest settle, then `syncToHost`. The **order is reversed**
from paste — paste sets the pasteboard *before* the keystroke, copy
reads it *after* — so a short settle covers the guest's key-event →
`UIPasteboard` round-trip before the sync reads it back. `press:false`
skips the keystroke for a pure ferry of whatever the sim already holds
(what the CLI `clipboard copy` does).

The pasteboard adapter is a `simctl` path, not SimulatorHID —
`pbcopy` / `pbpaste` / `pbsync host <udid>` / `pbsync <udid> host` run
through the existing `Subprocess` collaborator and are fully
unit-covered via `MockSubprocess`. One collaborator change was needed: `pbcopy` reads
its payload from **stdin**, so `Subprocess` grew a second,
stdin-carrying `run` requirement. The no-stdin variant still wires
`standardInput = nullDevice` (the Ctrl-C/SIGINT detachment `baguette
logs` depends on); the stdin variant uses a write pipe — no
controlling tty, so the SIGINT concern doesn't apply — written and
closed off-thread so a >64 KB payload can't deadlock against a full
pipe buffer.

The Cmd+V half is the ordinary keyboard path (`KeyboardKey` +
`[.command]` → HID page 7) — see [`keyboard.md`](keyboard.md).

## Browser capture

`baguette/parts/keyboard.js` owns every half:

- The keydown forwarder **carves out the paste chord**: Cmd+V /
  Ctrl+V is not forwarded and not `preventDefault`'d, so the
  browser fires its native `paste` event.
- A **document-level `paste` listener** (focus-gated on the screen
  element, like keydown) reads `event.clipboardData` text and sends
  the `paste` envelope. Document-level because Safari may target
  `<body>` rather than the focused non-editable div; the focus gate
  keeps sidebar pastes with the browser.
- The keydown forwarder also **carves out the copy chord**: Cmd+C /
  Ctrl+C is `preventDefault`'d and sends a `{type:"copy"}` envelope
  instead of forwarding the raw chord. The server presses Cmd+C
  sim-side (the focused field copies its selection) and lands the
  result on the **host Mac's** clipboard (`pbsync <udid> host`) — no
  native `copy` event or Clipboard API involved. This is exactly the
  local-dev case where the browser shares the Mac that runs baguette;
  for a remote browser it lands on the server's Mac.

No permission prompts: `clipboardData` inside a user-initiated
paste event is readable without the async Clipboard API (which
needs a secure context + permission — unavailable over plain
LAN http). Copy sidesteps the Clipboard API entirely by syncing
host-side.

## Adding to this surface

1. New pasteboard verb → `Pasteboard` protocol
   (`Domain/Pasteboard/Pasteboard.swift`) + `SimctlPasteboard`
   (argv + exit handshake; tests in `SimctlPasteboardTests`).
2. New wire field → `Paste.parse` / `Copy.parse`
   (`Domain/Pasteboard/{Paste,Copy}.swift`) + `PasteTests` / `CopyTests`.
3. Ack shape changes → `PasteDispatch` / `CopyDispatch` `Outcome`
   projections + their dispatch tests.
4. CLI → `PasteCommand` / `ClipboardCommand` + `CommandParsingTests`.

## Known limits

- **Paste wire verb is text-only.** For images, copy on the host Mac
  and run `baguette clipboard sync` — full-fidelity host→sim. Pasting
  image *bytes* from the browser's clipboard is a follow-up
  (needs an upload-then-sync path or a UI affordance that triggers
  clipboard-sync).
- **Copy's settle is a fixed ~200 ms.** Cmd+C presses sim-side, then
  after a fixed beat the pasteboard is read back — long enough for the
  guest's key-event → `UIPasteboard` round-trip in practice, but it's
  a timing guess, not a handshake. A very sluggish guest could be read
  before it finishes copying (stale content); a poll-until-changed
  read would be the robust follow-up. The CLI `clipboard copy` and
  wire `press:false` sidestep this entirely (pure ferry, no keystroke).
- **Copy only helps views that honor hardware Cmd+C.** Editable text
  fields copy their selection; a non-editable / no-selection view
  makes Cmd+C a no-op, so `copy` just ferries whatever the pasteboard
  already holds. Full-fidelity (images included) via `pbsync <udid> host`.
- **Browser copy targets the server's Mac.** `pbsync <udid> host`
  syncs onto the clipboard of the machine running baguette. Local dev
  (browser on that same Mac) is the happy path; a remote browser's
  Cmd+C lands on the server, not the viewer's clipboard.
- **`pbcopy` / `pbsync` need a booted device** — `simctl` exits
  non-zero on a shutdown sim and the error surfaces in the ack.
- **Safari paste-event caveat.** Chrome/Firefox fire `paste` with
  focus on the non-editable screen div; if a Safari version won't,
  the fallback is a hidden contenteditable focus proxy (not
  `navigator.clipboard.readText` — permission + secure-context
  problems).
