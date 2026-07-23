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
- **`icon`** must name one baguette ships: `accessibility`, `reload`,
  `link`, `list`, `bell`, `wrench`, `lock`, `globe`, `camera`, `clock`,
  `document`, `play`. Arbitrary markup is rejected — a manifest is
  untrusted text rendered into a protected page.
- **`when`**: `simulator.booted`, or omit for "always".
- **`body.kind`** is `list` (the only widget today). `rowAction` is
  `highlight` (draw a box on the device), `tap`, or `copy`.

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
  the same space as gesture coordinates. With `rowAction: "highlight"`,
  clicking the row boxes that rect on the live screen. Omit the frame
  and the row isn't clickable.
- `{ "ok": false, "message": "…" }` reports the plugin's own failure;
  baguette shows the message. Printing non-JSON is an error, not an
  empty result — a panel that renders nothing reads as "all clear".

## Capabilities

A plugin may only do what its manifest declared. `capabilities` is a
closed set, and it is **enforced**, not documentation:

| Capability | Grants |
|---|---|
| `describe-ui` | `GET /simulators/:udid/describe-ui.json` |
| `input` | `POST /simulators/:udid/input` — gestures, keys, buttons |
| `screenshot` | `GET /simulators/:udid/screenshot.jpg` |
| `logs`, `status-bar`, `location`, `files`, `simulators` | the matching routes |

**Least privilege by default**: a manifest that declares nothing gets
nothing. An unknown capability is a parse error, so typos surface at
`baguette plugin validate` rather than as a confusing runtime `403`.

How it's enforced: each command invocation is handed its **own** token
carrying exactly that plugin's declared set, revoked the moment the
command exits. A plugin that didn't declare `input` gets

```json
{"ok":false,"error":"this plugin did not declare the \"input\" capability"}
```

with HTTP `403` — even though its token is otherwise valid. A shared
session secret couldn't do this: every plugin would present the same
credential, so the server could never tell who was calling.

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
its plugins run as programs with your permissions. Everything is pinned
to a commit; `update` is an explicit re-pull. Fetches are shallow,
non-interactive (a bad URL fails fast), and pull no submodules.

```
~/.baguette/                          # or $BAGUETTE_HOME
  bakeries.json                       # trusted sources
  installed.json                      # which plugin came from which bakery@commit
  bakeries/<host>/<owner>/<repo>/     # clone cache
  plugins/<name>/                     # installed plugins (also the scan root)
```
