# Paste & clipboard

Put arbitrary text on the booted simulator's pasteboard and paste it
into the focused field — the path around `type`'s US-ASCII keystroke
limit, so emoji, accents, and non-Latin scripts all land intact.
Four entry points share one path:

- `baguette paste --udid <UDID> --text "<text>" [--no-press]` —
  set the pasteboard, then press Cmd+V (`--no-press` stops after the
  set, for apps that read `UIPasteboard` directly).
- `baguette clipboard get --udid <UDID>` — print the sim's pasteboard
  text raw to stdout (pipes byte-faithfully, like `pbpaste`).
- `baguette clipboard sync --udid <UDID>` — copy the host Mac's
  pasteboard onto the simulator **full-fidelity, images included**.
- Wire JSON `{ "type": "paste", "text": "…" }` on `baguette serve`'s
  stream WebSocket and `baguette input`'s stdin.
- Browser — Cmd+V (or Ctrl+V) while the device screen has focus
  pastes the host clipboard automatically.

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
```

- `text` — required. Any unicode; UTF-8 on the wire.
- `press` — optional bool, default `true`. When true, Cmd+V is
  pressed after the pasteboard is set (the set must succeed first —
  a failed `pbcopy` never fires the keystroke). `false` = set-only.

Acks: on `baguette input`, the usual one-line `{"ok":true}` /
`{"ok":false,"error":"…"}`. On the stream WS, a typed reply frame
(like `describe_ui_result`) so the browser's text-frame router can
claim it:

```json
{ "type": "paste_result", "ok": true }
{ "type": "paste_result", "ok": false, "error": "xcrun simctl pasteboard command exited 1" }
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
```

The pasteboard adapter is a `simctl` path, not SimulatorHID —
`pbcopy` / `pbpaste` / `pbsync host <udid>` run through the existing
`Subprocess` collaborator and are fully unit-covered via
`MockSubprocess`. One collaborator change was needed: `pbcopy` reads
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

`baguette/parts/keyboard.js` owns both halves:

- The keydown forwarder **carves out the paste chord**: Cmd+V /
  Ctrl+V is not forwarded and not `preventDefault`'d, so the
  browser fires its native `paste` event.
- A **document-level `paste` listener** (focus-gated on the screen
  element, like keydown) reads `event.clipboardData` text and sends
  the `paste` envelope. Document-level because Safari may target
  `<body>` rather than the focused non-editable div; the focus gate
  keeps sidebar pastes with the browser.

No permission prompts: `clipboardData` inside a user-initiated
paste event is readable without the async Clipboard API (which
needs a secure context + permission — unavailable over plain
LAN http).

## Adding to this surface

1. New pasteboard verb → `Pasteboard` protocol
   (`Domain/Pasteboard/Pasteboard.swift`) + `SimctlPasteboard`
   (argv + exit handshake; tests in `SimctlPasteboardTests`).
2. New wire field → `Paste.parse` (`Domain/Pasteboard/Paste.swift`)
   + `PasteTests`.
3. Ack shape changes → `PasteDispatch.Outcome` projections +
   `PasteDispatchTests`.
4. CLI → `PasteCommand` / `ClipboardCommand` + `CommandParsingTests`.

## Known limits

- **Wire verb is text-only.** For images, copy on the host Mac and
  run `baguette clipboard sync` — full-fidelity host→sim. Pasting
  image *bytes* from the browser's clipboard is a follow-up
  (needs an upload-then-sync path or a UI affordance that triggers
  clipboard-sync).
- **No sim→host sync.** `clipboard get` prints text; there's no
  reverse `pbsync` or browser copy-back yet.
- **`pbcopy` needs a booted device** — `simctl` exits non-zero on a
  shutdown sim and the error surfaces in the ack.
- **Safari paste-event caveat.** Chrome/Firefox fire `paste` with
  focus on the non-editable screen div; if a Safari version won't,
  the fallback is a hidden contenteditable focus proxy (not
  `navigator.clipboard.readText` — permission + secure-context
  problems).
