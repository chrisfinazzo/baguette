# Example bakery — Expo / React Native tools

A complete, working **bakery**: two plugins that send the React Native
dev chords to the focused simulator.

| Plugin | Does | Declares |
|---|---|---|
| `expo-reload` | ⌘R — reload the JS bundle | `input` |
| `expo-devmenu` | ⌘D — open the RN dev menu | `input` |

It exists to show the shape. Copy it to the **root of your own git
repo** — a bakery is a repo, so `baguette.json` must sit at the top
level, not in a subdirectory:

```text
your-repo/
  baguette.json                       ← the menu (this file's sibling)
  plugins/
    expo-reload/
      baguette-plugin.json            ← the plugin's own manifest
      bin/go.py
```

Then, from anywhere:

```bash
baguette bakery add <you>/<your-repo>
baguette plugin install expo-reload
```

## What to notice

**Two files, two jobs.** `baguette.json` is the bakery's *menu* — which
plugins exist and where. Each plugin's `baguette-plugin.json` is its own
*manifest* — what it contributes and what it may do.

**`capabilities` is enforced, not decorative.** These plugins declare
`input`, which is why they may POST to `/simulators/:udid/input`. A
plugin that omits it gets a `403` on that route even though its token is
otherwise valid — a plugin can never exceed its manifest. Declare the
least you need.

**Talk to the running server, not the CLI.** Each command reads
`BAGUETTE_URL` / `BAGUETTE_UDID` / `BAGUETTE_TOKEN` from its environment
and calls the already-warm server. Re-spawning the `baguette` binary
costs ~1.2 s in framework resolution alone.

**Answer in one JSON object on stdout.** `{"ok":true,"rows":[…]}` — see
[`docs/features/plugins.md`](../../docs/features/plugins.md) for the row
shape. Printing anything else is an error, deliberately: a panel that
renders nothing would read as "all clear".

These are written in `python3` because it ships with macOS, so the
example runs with no toolchain to install. Node is equally fine — `run`
is just an argv.
