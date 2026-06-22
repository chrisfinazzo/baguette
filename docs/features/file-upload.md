# File upload (drag-and-drop to device)

Add a file to a booted simulator by handing it the file — drop an app to
install it, drop a photo or video to land it in Photos. Three entry
points, one rule: **the device decides where the file goes by its type.**

- `baguette install --udid <UDID> <path>` — install an `.ipa` / `.app`.
- `baguette add-media --udid <UDID> <path>` — add an image / video to Photos.
- `POST /simulators/:udid/files?name=<filename>` (raw body) — served by
  `baguette serve`; the browser's drag-and-drop target on the focus
  page posts here.

Like the status bar, this is **not** a SimulatorHID path. It shells out
to `xcrun simctl install` / `xcrun simctl addmedia` — the same mechanism
Xcode's Simulator window uses when you drop a file on it. Both are
one-shot subprocesses run through the existing `Subprocess` collaborator,
so the orchestration is fully unit-covered via `MockSubprocess`.

## Why

A simulator is useless for testing a flow that needs a real app build, or
a screen that renders the user's photos, until you can get those bytes
onto the device. `simctl install` / `addmedia` do it, but there's no
browser affordance in a headless workflow and no single "just add this"
verb. baguette wraps both behind two Domain collections the user already
believes in — *the apps on my phone* and *my camera roll* — and a drop
target that routes to the right one.

## The domain: two collections, not one classifier

The user's mental model isn't "a file to be classified." It's two plain
acts: **install an app** and **add a photo**. So the domain is the two
things that live on a phone, each a small collection you add to:

| Collection (`@Mockable`) | Value added | simctl verb | Lands on |
|---|---|---|---|
| `Apps`         | `AppBundle` (`.ipa`, `.app`)                              | `install`  | Home screen |
| `PhotoLibrary` | `MediaItem` (`png jpg jpeg gif heic heif mov mp4 m4v`)    | `addmedia` | Photos |

Both hang off `Simulator` next to `statusBar()` / `orientation()`:
`simulator.apps().install(app)` / `simulator.photos().add(media)`.

Classification lives **on the values themselves**, as pure, disk-free
static factories — `AppBundle.at(url)` answers "is this an app?",
`MediaItem.at(url)` answers "is this media?", both by extension only
(case-insensitive). There is no separate "content classifier" object:
each thing knows what it is. `installArguments(udid:)` /
`addMediaArguments(udid:)` project the simctl argv tail; the
Infrastructure adapters (`SimctlApps`, `SimctlPhotoLibrary`) just prepend
`xcrun` and run it.

## Wire / route

```
POST /simulators/:udid/files?name=<filename>
     body = raw file bytes (application/octet-stream)
```

`Server.addFile` is the thin "which collection?" router — the only place
the two collections meet:

```
classify the staged file by extension:
  AppBundle.at(path)?   → apps().install(app)    → {"ok":true,"kind":"app"}    (200)
  MediaItem.at(path)?   → photos().add(media)     → {"ok":true,"kind":"media"}  (200)
  else                  → refuse                  → 415 "no home for .<ext> …"
```

The route closure materialises the upload into a unique temp directory
(preserving the filename so the extension — and simctl's bundle
detection — survives), dispatches, then deletes the temp dir regardless
of outcome. The client-supplied `?name=` is reduced to its last path
component, so `?name=../../etc/x` can't escape the temp dir. An unknown
extension is rejected **before** the body is read, so a junk drop never
uploads megabytes.

Other responses: `404` unknown udid, `400` upload too large
(> 1 GiB) / unreadable, `500` simctl failure (device not booted, bad
bundle).

## Dispatch path

```
drop / CLI ──▶ AppBundle.at / MediaItem.at  (Domain, pure)
            ──▶ Apps.install / PhotoLibrary.add        (@Mockable)
            ──▶ SimctlApps / SimctlPhotoLibrary         (orchestrator: argv + Subprocess)
            ──▶ HostSubprocess → xcrun simctl install | addmedia  (integration-only)
```

## Browser

`Resources/Web/sim-file-drop.js` hangs `window.SimFileDrop` on the
global; `sim-native.js` calls `SimFileDrop.attach(simNativeView, {udid})`
on the focus page. It's a **dumb sender**: on drop it `POST`s each
file's bytes to `/files?name=<name>` and shows a toast with the result
(`Installed …` / `Added …` / the server's error). It carries no HID
codes and no notion of which simctl verb applies — the Swift side owns
all of that.

## Adding a new added-to-device thing (recipe)

1. **Domain value** — a `struct` in a new `Domain/<Thing>/` context with
   `static func at(_:) -> Self?` (extension classification, pure) and a
   `…Arguments(udid:)` argv projection. Test it first (red → green).
2. **`@Mockable` collection** — `protocol <Things>: Sendable { func add(_:) async throws }`
   named as the plural collection noun, plus a `<Things>Error` enum.
3. **Orchestrator** — `Simctl<Things>` mirroring `SimctlApps`: build argv
   from the value, run via `Subprocess`, map non-zero exit to the error.
   Unit-test through `MockSubprocess`.
4. **Factory** — add `func <things>() -> any <Things>` to `Simulator`
   and return `Simctl<Things>(udid:)` from `CoreSimulator`.
5. **Wire** — add a branch to `Server.addFile` (`<Thing>.at(path)? → …`)
   and, if it's CLI-worthy, a subcommand in `AddFileCommands.swift`.

## Known limits

- **Single files only.** A folder-form `.app` bundle is a directory;
  browser folder drag-and-drop (recursive `webkitGetAsEntry` + client
  re-zip) is deferred — drop a `.ipa`, or zip the `.app`. The CLI's
  `install` accepts a real `.app` directory path directly (simctl does).
- **Generic documents have no home.** `.pdf`, `.json`, etc. are refused
  with `415` rather than silently dropped — `simctl` offers no clean path
  to drop an arbitrary doc into the Files app.
- **Drop UI is focus-mode only.** The device-farm grid doesn't mount the
  drop target yet; the `/files` route and both CLI verbs work for any
  device regardless.
- **Uploads are buffered in memory** (≤ 1 GiB) before staging to a temp
  file. Fine for a localhost dev tool; not a public upload endpoint.
