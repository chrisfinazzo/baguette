# Deep links

Open a URL on a booted simulator and watch it land in your app, plus the
inventory of what's openable there in the first place.

```bash
baguette openurl --udid <UDID> 'myapp://profile/42'
baguette schemes --udid <UDID>
```

The browser gets the same thing as a plugin panel — see
[the plugin](#the-plugin) below. It isn't in the toolbar, because it
isn't part of baguette's own surface: install it.

---

## The `https://` trap

This is the one thing baguette says that `simctl openurl`, `idb open`
and Maestro's `openLink` don't.

A custom scheme (`myapp://…`) is dispatched to the app that registered
it. An `https://` **universal link is not**. The simulator hands it to
Safari rather than resolving the associated domain to an installed app,
so the dispatch succeeds and your app never opens:

```console
$ baguette openurl --udid <UDID> 'https://example.com/profile/42'
[baguette] Warning: https:// lands in Safari on the simulator, not your app.
If an app claims the domain, iOS then shows an "Open in …?" dialog that needs a
tap, so this never completes unattended. For an automated check, use the app's
custom scheme — `baguette schemes` lists them.
[baguette] Opened https://example.com/profile/42 on iPhone 17 Pro
```

Every other tool performs that silently, which leaves you to guess
whether your entitlement, your `apple-app-site-association` file or the
simulator is at fault. `DeepLink.routing` names the case, so both the
CLI and the panel can say it out loud before anyone starts debugging the
wrong thing.

Nothing here *blocks* the https link — it's still the right thing to
open when you're testing what a person sees. It just isn't a check that
can run unattended, because the "Open in …?" dialog needs a tap.

## `baguette schemes`

```console
$ baguette schemes --udid <UDID>
myapp://                 My App
com.example.myapp://     My App
exp+myapp://             My App
calshow://               Calendar

$ baguette schemes --udid <UDID> --json
[ { "app": "My App", "bundleId": "com.example.MyApp",
    "scheme": "myapp", "url": "myapp://" } ]
```

Ordering is a specified behaviour, not dictionary iteration. One app
routinely registers three schemes — a readable one, a reverse-DNS alias,
and a dev-client scheme injected by tooling (`exp+…`) — and only the
first is what anyone means to type. So matches are ranked: schemes
*starting* with what was typed before ones merely containing it, then an
app's own scheme before its aliases, then alphabetically, so the list
never reshuffles between keystrokes.

### How the schemes are found

Two reads, no private API, because neither source has the whole picture:

1. `xcrun simctl listapps <udid>` — the authoritative roster: which apps
   are installed, what they're called, and each one's real `Path` on
   disk. It reports a curated metadata subset that **does not include
   `CFBundleURLTypes`** (verified against Xcode 26), so it cannot answer
   the question on its own.
2. `<Path>/Info.plist` — the schemes, from the key the app declared them
   under, unioned across every `CFBundleURLTypes` entry.

Taking the path from step 1 is what makes step 2 safe. Reading
`Info.plist` means touching CoreSimulator's container layout, whose
`…/Containers/Bundle/Application/<uuid>/` shape is undocumented and
whose UUID changes on every reinstall — but it never has to be
*guessed*, because `listapps` just reported it. An app whose bundle has
vanished keeps its roster entry and simply contributes no schemes.

Both parses are pure (`InstalledApp.all(fromListApps:)` /
`InstalledApp.schemes(inInfoPlist:)`); `SimctlApps` runs the child,
reads the file, and composes them.

## Routes

| Route | Answers |
|---|---|
| `POST /simulators/:udid/openurl?url=<encoded>` | `{"ok":true,"routing":"app"}`, or `"browser"` with a `warning` |
| `GET /simulators/:udid/schemes.json[?q=…]` | `{"schemes":[{"scheme","completion","app","bundleId"}]}` |

Ranking happens server-side so there is one ordering rule, tested once,
rather than a copy in every client that drifts. `?q=` narrows and ranks
against what's been typed; omit it for the whole inventory.

Both are reachable by a plugin holding the `open-url` capability, and by
a trusted browser. Failures answer `{"ok":false,"error":…}` — `400` for
something that isn't a URL, `404` for an unknown udid, `500` when simctl
itself failed.

## The plugin

The UI is a plugin, not part of focus mode's toolbar. baguette ships the
toolbar; a deep-link bar is a thing you choose to install:

```bash
baguette bakery add tddworks/baguette
baguette plugin install deeplink
```

It declares one capability, `open-url`, which `baguette plugin show
deeplink` prints before you install anything.

Its panel opens with every scheme on the device listed, so "what can I
even open here?" is answered before you type. The list is **completion,
not a launcher**: clicking `account://` puts it in the field with the
caret after it, ready for the path — a bare scheme with no path is
almost never what anyone means to open. Typing narrows the list, and a
suggestion you've typed past stays visible so it doesn't disappear
mid-URL. Enter (or **Open**) is what actually opens.

The field completes as you type: the rest of the best match is drawn
greyed after the caret, and `Tab` (or `→` at the end) accepts it. Links
you've opened before come first — having used `account://hello`, typing
`acc` offers that back rather than the bare scheme, and `↑` / `↓` walks
the last 25. That history lives in the browser: the plugin never sees
what you typed before, only what you submit. See
[`plugins.md`](plugins.md) for the manifest.

Being separate from `apps` is deliberate. That capability installs
software; this one only launches what is already there, and a plugin
that wants to fire a deep link shouldn't have to be trusted to put an
executable on the device.

## Limits

- **`https://` never reaches your app on the simulator.** See above.
  This is simulator behaviour, not something baguette can route around.
- **No live server-side completion in the panel.** A plugin command is a
  subprocess with a ten-second budget, so re-running it per keystroke is
  the wrong shape. The panel fetches the inventory once when it opens
  and filters those rows in the page as you type.
- **A scheme is not a guarantee.** `listapps` reports what an app
  *registered*; whether it does anything useful with a given path is the
  app's business.
