# Plugins & bakeries

Baguette plugins let you add domain-specific affordances — an Expo
reload button, an accessibility audit, a deep-link bar — without
touching baguette's core. A plugin is a small directory of files and a
command baguette runs as a subprocess; it never loads code into
baguette's own process or into the served web page.

Two things worth stating up front, because they define the security
model:

- **A plugin's command runs as a real program with your permissions.**
  It's `node bin/foo.js` or `python3 bin/foo.py`, spawned by baguette.
  That's the same trust you extend to anything you `brew install`.
- **Installing a plugin never runs its code.** Install only clones and
  copies files. A plugin's command runs only when you *activate* it —
  click its button in the rail, or `baguette plugin run`. There are no
  postinstall hooks.

---

## Anatomy of a plugin

A plugin is a directory containing `baguette-plugin.json`:

```jsonc
{
  "name": "a11y",
  "version": "1.0.0",
  "apiVersion": 1,                    // baguette refuses a newer contract
  "description": "Accessibility audit for the current screen",
  "icon": "accessibility",            // optional — the plugin's rail glyph
  "capabilities": ["describe-ui"],    // enforced — see below
  "contributes": {
    "commands": [
      { "id": "audit", "title": "Run audit", "run": ["/usr/bin/python3", "bin/audit.py"] }
    ],
    "panels": [
      { "id": "audit", "title": "Accessibility", "icon": "accessibility",
        "when": "simulator.booted",
        "body": { "kind": "list", "source": "audit", "rowAction": "highlight" } }
    ]
  }
}
```

- **`run`** is an argv resolved against the plugin's own directory
  (its cwd when spawned). Prefer an absolute interpreter path or a bare
  one baguette finds via `PATH` (`["node", "bin/x.js"]`).
- **`icon`** names one baguette ships: `accessibility`, `reload`,
  `link`, `list`, `bell`, `wrench`, `lock`, `globe`, `camera`, `clock`,
  `document`, `play`, `puzzle`. Arbitrary markup never renders — a
  manifest is untrusted text destined for a protected page, so the name
  is resolved against this list and nothing else survives.

  A name baguette doesn't know **draws `puzzle` instead of failing the
  plugin**, so one written against a newer baguette still works on an
  older one. `baguette plugin validate` reports the substitution, since
  the likelier cause is a typo than a glyph from the future.
- **Top-level `icon`** is the glyph for the plugin *as a whole* — the one
  the rail shows when its tools are collapsed. Optional: omit it and the
  plugin wears the icon of the first panel it contributes.
- **`apiVersion`** is the contract the manifest was written against.
  baguette refuses a *newer* one outright rather than guessing at shapes
  it can't interpret. Omitting it means **1**, permanently — that's what
  manifests written before the field existed meant, and it stays true
  whatever this build happens to support.
- **`when`**: `simulator.booted`, or omit for "always".
- **`body.kind`** is `list` (the only widget today). `rowAction` says
  what clicking a row does:
  - `highlight` — box the row's `frame` on the live screen
  - `tap` — tap the centre of the row's `frame` on the device
  - `copy` — put the row's `copy` string on the clipboard
  - `run` — invoke the command named by the row's `run`, passing its
    `args`, and re-render the panel from the answer

  A row missing what the action needs isn't clickable: no `frame` for
  `highlight` / `tap`, no `copy` for `copy`, no `run` for `run`. An
  unknown `rowAction` is inert rather than resolved to the nearest match.

Contributions are namespaced by plugin: `a11y:audit`. Two plugins can
both ship a `reload`.

Validate a manifest before publishing:

```bash
baguette plugin validate path/to/plugin
```

## The command contract

When a panel opens, baguette runs its `source` command. The command
receives context in its **environment** (and the same as JSON on stdin):

| Env var | Meaning |
|---|---|
| `BAGUETTE_URL` | Origin of the running server — call it instead of re-spawning `baguette` |
| `BAGUETTE_UDID` | The focused device (absent when none) |
| `BAGUETTE_TOKEN` | Session token; send it as `X-Baguette-Token` on plugin-API calls |

The command prints **one JSON object** on stdout and exits:

```json
{
  "ok": true,
  "rows": [
    { "title": "Button has no label", "subtitle": "AXButton",
      "severity": "error",
      "frame": { "x": 24, "y": 380, "width": 44, "height": 44 } }
  ]
}
```

- `severity` is `info` | `warn` | `error` (default `info`).
- `frame` is **flat** — `x`/`y`/`width`/`height` in **device points**,
  the same space as gesture coordinates, so `rowAction: "tap"` aims at
  its centre with no conversion. Omit the frame and a `highlight` /
  `tap` row isn't clickable.
- `copy` is the string a `rowAction: "copy"` row puts on the clipboard.
- `run` names one of *this plugin's* command ids, and `args` is an
  object handed to it — see below. `args` without `run` is an error, not
  a silently-inert row.
- `{ "ok": false, "message": "…" }` reports the plugin's own failure;
  baguette shows the message. Printing non-JSON is an error, not an
  empty result — a panel that renders nothing reads as "all clear".

**A command has ten seconds.** A button that never returns is
indistinguishable from a hung UI, so the host bounds it rather than
trusting authors to. At the deadline the command gets `SIGTERM`, and two
seconds later `SIGKILL` — trapping the first only buys that grace period,
it doesn't buy forever. Write cleanup handlers to be quick, and don't
hold work open across the deadline expecting to finish it.

The capability token is revoked the moment the command ends, however it
ended. A child that outlived its parent's request has no credentials.

## Panels you can operate — `rowAction: "run"`

The other three row actions are things the *host* does with a row's
data. `run` hands control back to the plugin, which is what turns a
panel from a report into a control surface:

```jsonc
// manifest
{ "id": "display", "title": "Display & Text Size", "icon": "wrench",
  "body": { "kind": "list", "source": "display", "rowAction": "run" } }
```

```json
// what the command prints
{ "ok": true, "rows": [
  { "title": "● Light" },
  { "title": "○ Dark", "run": "display", "args": { "appearance": "dark" } }
] }
```

Clicking *Dark* calls `display` again with those `args`. The command
applies the change and prints the new state; the panel re-renders from
that answer — so what you see is what the device reports, not what the
click assumed. The already-selected row carries no `run`, so re-applying
a setting doesn't cost a subprocess.

`args` arrive in the **stdin context**, not the environment (env values
are strings, so a nested object would have to be flattened and parsed
back):

```json
{ "command": "a11y:display", "url": "…", "token": "…", "udid": "…",
  "args": { "appearance": "dark" } }
```

The field is **absent** when no row invoked the command, so a command
written before `run` existed sees exactly the context it always did.

A row can only name a command in its own plugin — the plugin id comes
from the panel's own `source`, never from the row — and this is still an
HTTP call to the same command endpoint the panel opens with. No plugin
code runs in the page.

## The rail

Plugins live in their own strip on the right edge of focus mode, apart
from the device toolbar — baguette ships the toolbar, plugins are code
you installed, and the split is a trust signal.

**One plugin is one slot, however many tools it ships.** A plugin
contributing a single panel opens it on click. A plugin contributing
several collapses to one entry marked with a caret; hovering it (or
clicking, or tabbing to it) expands a flyout listing each tool by icon
**and** name. `Esc` closes it.

So a plugin with eight panels costs one slot, not eight, and the rail's
length tells you how much you installed rather than how much those
things happen to contribute.

## Capabilities

A plugin may only do what its manifest declared. `capabilities` is a
closed set, and it is **enforced**, not documentation:

| Capability | Grants |
|---|---|
| `describe-ui` | `GET /simulators/:udid/describe-ui.json` |
| `input` | `POST /simulators/:udid/input` — gestures, keys, buttons |
| `screenshot` | `GET /simulators/:udid/screenshot.jpg` |
| `logs` | `WS /simulators/:udid/logs` |
| `interface` | `GET /simulators/:udid/interface.json`, `POST /simulators/:udid/interface` — appearance, contrast, text size |
| `status-bar` | `GET`/`POST`/`DELETE /simulators/:udid/status-bar` |
| `location` | `POST`/`DELETE /simulators/:udid/location` |
| `apps` | `POST /simulators/:udid/apps` — install an app |
| `media` | `POST /simulators/:udid/media` — add photos / videos |
| `simulators` | `GET /simulators.json` |

`apps` and `media` are deliberately separate: one puts a picture in the
photo library, the other puts an executable on the device. A plugin that
seeds test images shouldn't have to be trusted to install software.

The browser's drag-and-drop endpoint, `POST /simulators/:udid/files`,
takes either and works out which from the file — convenient for a person
who picked the file, useless as a boundary. It is reachable by **no**
capability, so plugins use the two routes above and say which power they
mean.

**Least privilege by default**: a manifest that declares nothing gets
nothing. An unknown capability is a parse error, so typos surface at
`baguette plugin validate` rather than as a confusing runtime `403`.

That table is the *whole* plugin surface. Routes it doesn't name —
booting a device, orientation, the camera source, the drag-and-drop
upload, installing another plugin — are reachable by no capability at
all, so no manifest can ask for them. A route added to baguette later is closed to plugins until
someone puts it in the table: the drift direction is always toward less
authority, never more.

How it's enforced: each command invocation is handed its **own** token
carrying exactly that plugin's declared set, revoked the moment the
command exits. The check runs in front of every route, not inside the
handful that remember to ask. A plugin that didn't declare `input` gets

```json
{"ok":false,"error":"this plugin did not declare the \"input\" capability"}
```

with HTTP `403` — even though its token is otherwise valid, and even
though it could read the accessibility tree a moment earlier. Presenting
a stale or invented token is refused too, rather than being treated as
"no token". A shared session secret couldn't do any of this: every
plugin would present the same credential, so the server could never tell
who was calling.

`logs` is the one WebSocket route, so its refusal is a failed upgrade
(`400`) rather than a `403` carrying that JSON — there's no body to put
it in once the handshake is turned down.

### What capabilities are not

They govern **the plugin API** — what a plugin can ask *baguette* to do
in its name. They are not a sandbox around the plugin's process.

A plugin's command is a real program running as you (see the top of this
page). Nothing stops it from running `curl` against the same server, or
`baguette tap` directly, or reading your files — exactly as any program
you install can. Baguette's HTTP API is deliberately reachable by local
non-browser callers, and a plugin is a local non-browser caller.

So read the capability list as **a declaration of intent, enforced at
the API boundary**: it tells you what the plugin means to do, `baguette
plugin show` puts that in front of you before you install, and the
server holds the plugin to it on every call it makes through the
documented contract. The consent that actually protects you is the one
you give when you trust the bakery.

`baguette plugin show <name>` prints the capabilities before you install.

### Sending input

`POST /simulators/:udid/input` takes the same gesture envelope the
stream socket and `baguette input` accept — so ⌘R to reload a React
Native bundle is:

```json
{"type":"key","code":"KeyR","modifiers":["command"]}
```

See [`examples/expo-bakery/`](../../examples/expo-bakery/) for a complete
working bakery built on this.

## Local authoring

Point baguette at a directory of plugins without installing anything:

```bash
baguette serve --plugin-dir ./my-plugins       # rail picks them up
baguette plugin run a11y:audit --udid <UDID> --plugin-dir ./my-plugins
```

---

## Distribution — bakeries

A **bakery** is any git repo that supplies plugins. You trust a bakery
once, then install any plugin it offers. A repo becomes a bakery by
adding a `baguette.json` at its root — its *menu*:

```jsonc
{
  "name": "tddworks/baguette-plugins",           // optional display name
  "description": "Official baguette plugins",
  "plugins": [
    { "name": "a11y", "path": "plugins/a11y" },   // path → dir with baguette-plugin.json
    { "name": "expo", "path": "tools/expo" }
  ]
}
```

`path` is repo-relative and must stay inside the repo. The rest of the
repo can be anything — a bakery doesn't have to be a dedicated project.

### Installing (CLI)

```bash
# trust a source (prompts unless --yes), then install from it
baguette bakery add tddworks/baguette-plugins
baguette plugin install a11y

# or do both at once, directly:
baguette plugin install tddworks/baguette-plugins/a11y

baguette bakery list                 # trusted sources + pinned commits
baguette plugin list                 # installed plugins + provenance
baguette plugin update               # re-pull + re-install at latest
baguette plugin remove a11y
baguette bakery remove tddworks/baguette-plugins
```

References: `owner/repo` (GitHub), `owner/repo/plugin`, a full
`https://…` / `git@…` URL (any host), or `file://…` (a local checkout).

### Installing (browser)

In focus mode, the plugins rail on the right has a **+** at the bottom.
Paste `owner/repo`, click **Preview** to see the source, its pinned
commit, and the plugins it offers, then **Install**. The rail updates
without a reload. Preview is safe; Install is the consented act.

### Trust & storage

Trust is **per bakery, once** — accepting a source means accepting that
its plugins run as programs with your permissions. Fetches are shallow,
non-interactive (a bad URL fails fast), and pull no submodules.

**The pin is a demand, not a note.** Adding a bakery records the commit
you saw; every install from it afterwards fetches *that commit by name*
rather than whatever the default branch points at today. Otherwise a
source accepted months ago would quietly deliver its current contents,
and the recorded sha would only ever describe what you happened to get.

If the bakery no longer serves the pinned commit — rewritten history, a
force-push — the install **fails** rather than falling back to HEAD.
Re-add the bakery to look at what it holds now and trust that instead.
Moving the pin forward deliberately is what `update` is for.

```text
~/.baguette/                          # or $BAGUETTE_HOME
  bakeries.json                       # trusted sources
  installed.json                      # which plugin came from which bakery@commit
  bakeries/<host>/<owner>/<repo>/     # clone cache
  plugins/<name>/                     # installed plugins (also the scan root)
```
