# Interface settings — appearance, contrast, text size

The three accessibility-display settings a simulator exposes: light /
dark **appearance**, **Increase Contrast**, and **content size**
(Dynamic Type). Available from the CLI, over HTTP, and — through the
bundled a11y plugin — as a picker in the browser.

```bash
baguette interface appearance --udid <UDID>            # read
baguette interface appearance --udid <UDID> dark       # set
baguette interface contrast   --udid <UDID> enabled
baguette interface text-size  --udid <UDID> accessibility-large
baguette interface text-size  --udid <UDID> increment  # one step up
```

They travel together because an accessibility pass uses them together:
flip to dark, turn contrast up, push text to an accessibility size, then
re-run `describe-ui` and see what broke. The five accessibility text
sizes are where layouts actually fail, which is the point of exposing
this at all.

## Reading is forgiving, writing is not

Backed by `xcrun simctl ui <udid> <option> [<value>]`. Each leaf both
reads and writes, mirroring simctl itself — pass a value to set it, omit
it to print the current one.

A read can answer two things that aren't values:

| Answer | Means |
|---|---|
| `unknown` | Nothing answered — usually the device isn't booted |
| `unsupported` | The runtime or platform has no such setting |

**Neither is an error.** simctl prints them and exits 0, and a caller
that asked before boot deserves "can't tell" rather than a failure or a
guessed `light`. So reads return them as states.

They are equally **not instructions**. There is no argv that means "make
it unknown", so trying to set one is refused before anything spawns:

```bash
$ baguette interface appearance --udid <UDID> unknown
Usage: baguette interface appearance --udid <udid> [<value>]
```

That asymmetry is the whole shape of the feature — `InterfaceAppearance`
and `InterfaceContrast` carry all four states with an `argument` that is
`nil` for the two read-only ones, and `ContentSizeChange` is a separate
type from `ContentSize` because setting also accepts `increment` /
`decrement`, which reading never answers.

## Values

**appearance** — `light`, `dark`

**contrast** — `enabled`, `disabled`

**text-size** — `increment`, `decrement`, or one of twelve categories,
smallest first:

```
extra-small  small  medium  large  extra-large
extra-extra-large  extra-extra-extra-large
accessibility-medium  accessibility-large  accessibility-extra-large
accessibility-extra-extra-large  accessibility-extra-extra-extra-large
```

The last five are the "Larger Accessibility Sizes" range.

## HTTP

```
GET  /simulators/:udid/interface.json     all three
POST /simulators/:udid/interface          set any subset
```

```bash
curl localhost:8421/simulators/$UDID/interface.json
# {"appearance":"light","contentSize":"large","increaseContrast":"disabled"}

curl -X POST localhost:8421/simulators/$UDID/interface \
     -H 'content-type: application/json' \
     -d '{"appearance":"dark","contentSize":"increment"}'
# {"appearance":"dark","contentSize":"extra-large","increaseContrast":"disabled"}
```

Every field is optional — change one setting without restating the
others. A `POST` answers with the **resulting** state, so a caller that
just changed something doesn't need a second round-trip and sees what
actually landed rather than what it asked for.

A body naming a value that can only be read (`unknown`, `unsupported`,
or a bad spelling) is refused whole with `400` rather than half-applied.

Plugins reach both routes under the **`interface`** capability. One
capability covers the family: a plugin that can darken the screen can
already restyle it, so splitting read from write would be a distinction
without a difference.

## Dispatch path

```
CLI / HTTP ──▶ Interface (@Mockable)
                    │
                    ▼
              SimctlInterface ──▶ Subprocess ──▶ HostSubprocess
              (argv + exit                        (the real
               handshake —                         xcrun spawn,
               unit-tested)                        integration-only)
```

The split follows `SimctlStatusBar` exactly: argv assembly and the exit
handshake are pure orchestration driven in tests through
`MockSubprocess`, and only the spawn itself is integration-only. Value
types live in `Domain/Interface/`; the adapter is
`Infrastructure/Interface/SimctlInterface.swift`.

Reads are three separate spawns — simctl has no combined query — so
`interface.json` costs three. Fine for a panel; don't put it in a frame
loop.

## In the browser

The bundled **a11y** plugin contributes a *Display & Text Size* panel
next to its audit. Every row is a `rowAction: "run"` row: clicking one
calls the plugin's own command with the row's `args`, which applies the
change and prints the fresh state, and the panel re-renders from that.
The selected option is marked and carries no action — re-applying what's
already set would spawn simctl to change nothing.

A device that isn't booted reads `unknown` for all three, and the panel
says "boot the device" rather than drawing a picker where nothing looks
selected.

See [`plugins.md`](plugins.md) for the `run` row action.

## Adding another `simctl ui` option

If Apple adds a fourth:

1. A value type in `Domain/Interface/` with an `init(output:)` parser
   and an `argument` projection — `nil` for anything read-only.
2. Two methods on the `Interface` protocol (read + set).
3. The `Option` case and the two methods in `SimctlInterface`.
4. A leaf on `InterfaceCommand` + an `ExpressibleByArgument`
   conformance, and a field on `InterfaceUpdate`.
5. Nothing in `PluginRoute` — the routes are already mapped to
   `interface`, and the new setting rides them.

## Known limits

- **Booted devices only.** Everything reads `unknown` on a shut-down
  simulator. simctl offers no way to pre-seed the setting.
- **No watch / TV coverage checked.** `unsupported` is handled, but the
  values above are verified against iOS 26 runtimes only.
- **Content size can't be read back as a step.** After `increment` the
  device reports a category; there's no "one larger than default" state
  to round-trip.
- **Three spawns per read.** See above.
