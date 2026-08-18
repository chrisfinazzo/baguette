# Network conditioning

Make a simulator's apps see a worse network than your Mac has — added
latency, a capped downlink, a proportion of requests failing outright, or
no connection at all. Three entry points share one path:

- `baguette network set --udid <UDID> --profile 3g` /
  `baguette network set --udid <UDID> --latency 300 --bandwidth 400 --loss 5` /
  `baguette network set --udid <UDID> --offline` /
  `baguette network clear --udid <UDID>` /
  `baguette network status --udid <UDID>` — CLI.
- `POST /simulators/:udid/network` (JSON body) / `GET` (read back) /
  `DELETE` (stop) — served by `baguette serve`.
- The focus-mode **Network** card.

Like [`motion`](motion.md) and unlike [`location`](location.md), **there is
no `simctl` verb behind this**. baguette injects `VirtualNetwork.dylib` into
apps and conditions their requests from inside. That has two consequences
worth putting first:

> **Only apps launched _after_ `network set` are conditioned.** dyld inserts
> libraries at exec time. Relaunch the target app, or
> `xcrun simctl launch --terminate-running-process <udid> <bundle-id>`.
> **Changing the condition afterwards needs no relaunch** — a running app
> picks it up within about 100 ms.

> **This only sees URLSession-shaped traffic.** REST, GraphQL, image loading
> and `URLSessionWebSocketTask` are conditioned. `WKWebView` page loads and
> raw sockets are not. Read [Known limits](#known-limits) before trusting a
> result.

## Why this needs a dylib at all

Network Link Conditioner exists, and so do the `dnctl` / `pfctl` dummynet
rules underneath it. Both are **system-wide**. A simulator app uses the
host's network stack as the host user, so there is no interface, process or
route to scope a rule to: conditioning one simulator that way degrades your
whole Mac and every other simulator with it. NLC also needs `sudo` and a
separate prefpane install.

Per-app injection is the only way to condition **one simulator** while the
rest of the machine stays fast. That's the gap this fills — and it's why the
trade-offs below are worth accepting rather than designed around.

## Surface

```
baguette network set    --udid <UDID> --profile <name>
baguette network set    --udid <UDID> [--latency <ms>] [--bandwidth <kbps>] [--loss <percent>]
baguette network set    --udid <UDID> --offline
baguette network clear  --udid <UDID>
baguette network status --udid <UDID>          # also plain `baguette network`
```

`set` takes **exactly one** source: a preset, some numbers, or `--offline`.
Mixing them is an error rather than a merge — "3G but lossier" reads like it
ought to work, and once it does, whether the preset or the flag wins becomes
something you have to remember. A `set` naming nothing is also an error: it
costs an app relaunch and achieves nothing visible, which is far more likely
a forgotten flag than an intention.

`--latency` is the **whole round trip** in milliseconds — the figure you mean
when you say "300 ms of latency". `--bandwidth` is downlink kbps; omit it to
leave the link unmetered. `--loss` is the percentage of requests failed.

### Presets

Borrowed wholesale from Network Link Conditioner, vocabulary and figures
both, so `3g` means what every iOS developer already means by 3G and nobody
has to defend a number baguette invented. `NetworkProfileTests` pins each one.

| Preset | Downlink | Round-trip latency | Loss |
| --- | --- | --- | --- |
| `wifi` | 40 000 kbps | 2 ms | 0% |
| `dsl` | 2 000 kbps | 10 ms | 0% |
| `lte` | 50 000 kbps | 130 ms | 0% |
| `3g` | 780 kbps | 200 ms | 0% |
| `edge` | 240 kbps | 800 ms | 0% |
| `very-bad-network` | 1 000 kbps | 1 000 ms | 10% |
| `100-loss` | — | — | 100% |

Two deliberate translations from NLC:

- **NLC states a one-way delay**, paid outbound and again inbound. baguette's
  latency is the round trip, so each preset carries twice NLC's figure.
- **NLC conditions uplink and downlink separately.** baguette paces the
  response body only, so a preset carries NLC's *downlink* figure and uploads
  run at full speed.

## Wire JSON

`POST /simulators/:udid/network` accepts three spellings, exactly one per
request:

```json
{ "profile": "3g" }
{ "latencyMs": 300, "bandwidthKbps": 400, "lossPercent": 5 }
{ "offline": true }
```

The browser posts the preset's **name**, not its numbers — that's what keeps
NLC's figures in Swift instead of copied into JavaScript where the two would
drift. `"offline": false` is not counted as a source, because the card posts
its whole form and that key rides along with real numbers on every ordinary
request.

All three return the current state, which is also what `GET` answers:

```json
{ "ok": true, "active": true, "latencyMs": 200, "bandwidthKbps": 780,
  "lossPercent": 0, "offline": false, "summary": "200 ms latency, 780 kbps",
  "profiles": ["wifi", "dsl", "lte", "3g", "edge", "very-bad-network", "100-loss"] }
```

`profiles` rides along so the card can offer the presets without a second
copy of the list. A body naming no condition, or more than one, returns
`400`; an unknown udid `404`; a build with no bundled dylib `500`.

`DELETE /simulators/:udid/network` clears conditioning — including for apps
that are already running.

## Dispatch path

```
   Host (Swift, tested)                        iOS Simulator app
┌────────────────────────────┐              ┌────────────────────────┐
│ NetworkProfile.condition   │              │  app's own URLSession  │
│ NetworkCondition (valid)   │              │  ── fetch / images ──  │
│ NetworkSchedule(bandwidth) │              └───────────▲────────────┘
│ NetworkCondition.encoded() │                          │ URLProtocol
└───────────┬────────────────┘                          │
            │  /tmp/BaguetteNetwork-<udid>.json         │
            ▼  (shared /tmp, as the camera uses)        │
      ┌───────────┐      launchctl setenv        ┌──────┴───────────┐
      │  Network  │ ──── DYLD_INSERT_LIBRARIES ─▶│ VirtualNetwork   │
      │ @Mockable │                              │ .dylib           │
      └───────────┘                              └──────────────────┘
```

Every judgement call is resolved host-side and arrives pre-computed —
including the **pacing schedule**: how many bytes the dylib may release per
tick and how long a tick is. The dylib compares and subtracts, nothing more.
Same division of labour [motion](motion.md#why-an-intent-not-a-sample-stream)
has.

The obvious pacing shape — a fixed 50 ms tick with however many bytes that
works out to — is wrong at the slow end: a link whose tick is 6.25 bytes
rounds to 6 and quietly delivers 4% under. So the rounded byte count is taken
as given and the interval derived back from it, which makes the delivered
rate exact at every bandwidth.

## How the interception works, and what it took to find out

Two mechanisms, and which one matters was **measured before any of this was
written**, against a real React Native app making real traffic:

| Mechanism | Reaches |
| --- | --- |
| `+[NSURLProtocol registerClass:]` | `NSURLConnection` and `NSURLSession.shared` |
| Swizzling `+[NSURLSessionConfiguration defaultSessionConfiguration]` / `ephemeralSessionConfiguration` | everything else |

A 100-second run with registration alone, against a fully launched and online
app, intercepted **zero** app requests — the only thing it saw was React
Native's Metro dev-server ping. RN's `fetch` goes through
`RCTHTTPRequestHandler`, which builds its own session from
`defaultSessionConfiguration`; so do image loading, MapLibre's tile requests,
and REST clients generally. **The swizzle is why this feature works**; the
registration is kept for the minority that `registerClass` does reach. The
load banner says which took:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.network"'
# [VirtualNetwork] installed (registerClass=1 configSwizzle=1) — a condition is armed
# [VirtualNetwork] conditioning: 200 ms latency, 4875 bytes/50 ms, 0% loss
# [VirtualNetwork] conditioning GET https://api.example.com/v2/orders
```

That's also the fastest way to confirm injection is live: launch the app and
look for those lines. The dylib logs through `os_log`, never `NSLog` — it is
loaded into *every* process launched while conditioning is armed, including
the `launchctl` baguette spawns to read `DYLD_INSERT_LIBRARIES`, and a banner
on stderr can come back as part of the value being read.

Three more things the probe established, each of which shapes the code:

- **The re-issued request re-enters our own protocol.** The swizzle puts
  `VNProtocol` into the configuration the inner session is built from, so
  without a marker this is an infinite loop rather than a slow request. The
  guard is load-bearing, not defensive.
- **Bodies never arrive as `HTTPBody`, only as `HTTPBodyStream`** — and a
  stream reads exactly once. So **this never retries a request**: a second
  attempt would send an empty body and read as a server bug rather than a
  failed request. Conditioned `POST`s come back intact, verified against an
  HMAC-signed token request that would fail on a corrupted body.
- **Pacing streams rather than buffers.** Collecting the response and then
  replaying it in slices makes wall-clock the sum of both and holds a 23 MB
  bundle in memory. Bytes are released from a backlog on a timer instead,
  with the upstream task suspended above a high-water mark.

The inner session is **shared** and built from a *default* configuration.
One-per-request would add an unmeasured TLS handshake to every request in a
tool whose job is adding a measured delay, and an ephemeral configuration
would silently drop the cookies an app authenticates with.

### WebSockets

WebSockets are part of the URL Loading System but do **not** go through
`NSURLProtocol` — once the socket is open, messages bypass the protocol
machinery entirely. So `URLSessionWebSocketTask` gets its own pair of hooks,
on the two methods every client funnels through:

| | Outbound (`sendMessage:`) | Inbound (`receiveMessageWithCompletionHandler:`) |
| --- | --- | --- |
| latency | delayed before sending | delayed before delivery |
| loss | the send fails | the message is **dropped** and the receive re-issued |
| offline | fails `NSURLError -1009` | fails `-1009` after a short backoff |

Inbound loss swallows the message and listens again rather than completing
with an error, because those are different events: a client that gets an
error on its receive stops listening, which is a dropped *connection*, not a
dropped message. Apps react to the two very differently, and only one of them
is what `--loss` means.

The offline backoff exists because clients re-arm the receive as soon as one
completes; failing instantly turns an offline socket into a busy loop pinning
a core inside the app under test.

Note the socket itself is not torn down: the TCP connection stays up while
messages are refused. What the app observes is a dead channel with the right
error code, which is what matters for testing; it is not a substitute for
pulling the network out from under a connection.

#### This only reaches Apple's WebSocket API

`URLSessionWebSocketTask` arrived in iOS 13, and plenty of realtime SDKs
predate it or ship their own transport. **Ably's `ably-cocoa` vendors
SocketRocket** (`ARTSRWebSocket`), which is built on `CFStream` rather than
`URLSession` — measured against a driver app using it, the hooks installed
(`websockets=1`) and **not one of them fired**. Starscream is in the same
category.

So check what your realtime layer actually uses before trusting `--offline`
to reach it. The banner tells you the hooks are installed; only the
`conditioning websocket …` lines tell you they are being used:

```bash
xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.network"'
# [VirtualNetwork] conditioning websocket send (200 ms)
```

Nothing conditions an SDK that opens its own socket, and no amount of work at
this layer would — that would need a hook further down, at `CFStream` or the
BSD socket calls, which conditions the simulator's own daemons along with the
app.

### The load-time check

If neither mechanism installs, the dylib **unregisters itself and conditions
nothing**, saying so in the log. An app is better off with real networking
than with networking this dylib has half taken over, and a conditioning tool
that silently conditions nothing is worse than one that admits it — the whole
point is measuring against a network you believe in.

An unconditioned state is not "intercept and re-issue at full speed" either:
`canInitWithRequest:` declines outright, so a cleared condition costs a
running app nothing.

## Seeing it work

Arm something impossible to miss, relaunch the app under test, and watch the
dylib's own log:

```bash
baguette network set --udid <UDID> --latency 3000
xcrun simctl launch --terminate-running-process <UDID> <bundle-id>
xcrun simctl spawn <UDID> log stream --predicate 'subsystem == "com.baguette.network"'
```

```
[VirtualNetwork] installed (registerClass=1 configSwizzle=1) — a condition is armed
[VirtualNetwork] conditioning: 3000 ms latency, 0 bytes/0 ms, 0% loss
[VirtualNetwork] conditioning GET https://api.example.com/v2/orders
```

A request that normally returns in ~500 ms taking ~3.5 s is the whole
confirmation. If the banner says `configSwizzle=0`, nothing an app does on
its own sessions is being conditioned — see
[how the interception works](#how-the-interception-works-and-what-it-took-to-find-out).

## Forgetting this is on is the real hazard

A forgotten camera override is obvious — the picture is wrong. A forgotten
throttle is invisible: it reads as "the app is slow" or "the backend is
flaky", possibly days later, and nothing on screen says otherwise. The design
answers that in four places:

- **`baguette network` on its own reports the current condition**, so
  checking is one command.
- **The browser card shows an amber armed badge**, and the toolbar keeps an
  amber dot lit **whether or not the card has ever been opened** — the page
  polls the device's state from load. A throttle armed from the CLI in
  another terminal is exactly the one you forget, and the browser is where
  you'll be looking when things feel slow.
- **`network clear` un-conditions apps that are already running**, not just
  future launches. Disarming alone would leave a running app throttled for as
  long as it lives.
- **The dylib logs every conditioned request** (throttled to one line a
  second), so it's traceable after the fact.

`status` reports what **this simulator** is subject to, not merely what was
published. The condition file is per-simulator
(`/tmp/BaguetteNetwork-<udid>.json`, which the dylib derives from its own
`SIMULATOR_UDID`), but a device can still hold a stale one without the dylib
armed — after a simulator reboot clears `DYLD_INSERT_LIBRARIES`, say. So the
read checks arming as well as content. A badge that cries wolf stops being
read, and this one has to be believed.

## Known limits

- **URLSession-shaped traffic only.** `NWConnection` / Network.framework,
  raw sockets, and most gRPC stacks bypass the URL Loading System entirely
  and are **not conditioned**. This is structural, not an oversight. In
  practice `NWConnection` is rare in app code — Apple's own guidance is to
  use `URLSession` for HTTP and drop to Network.framework only for custom
  protocols — but a realtime SDK built on raw sockets rather than
  `URLSessionWebSocketTask` (Starscream, for instance) falls outside this.

- **`WKWebView` and Safari page loads are not conditioned.** WebKit fetches
  page resources in its own networking process, on a path `URLProtocol` does
  not sit on. Measured: with a 2 000 ms latency armed, launching Safari and
  opening a page conditioned Safari's *own* `URLSession` traffic
  (`configuration.apple.com`, the SafeBrowsing service) and **none** of the
  page load.

  This matters well beyond Safari — a hybrid app's native `fetch` calls are
  conditioned while the web content inside its `WKWebView` is not, so the
  same screen can be half-throttled.

- **WebSockets carry latency, loss and offline — but not bandwidth.**
  `URLSessionWebSocketTask` has its own hooks (see
  [WebSockets](#websockets)); a bandwidth cap is not among them, because an
  app cannot observe a partial message, so capping one could only mean
  delaying whole messages by size — which is latency wearing another name.
  A realtime SDK that opens its own socket rather than using
  `URLSessionWebSocketTask` is **not reached at all** — Ably's `ably-cocoa`
  (SocketRocket) and Starscream are both in that category, measured for the
  first. See [WebSockets](#websockets).
- **Request-level, not packet-level.** "20% loss" means 20% of requests fail:
  no partial transfers, no retransmits, no congestion-window behaviour. Loss
  fails a request **immediately** (`NSURLErrorNetworkConnectionLost`) rather
  than letting it hang to the client's timeout; if you want timeout
  behaviour specifically, reach for a large `--latency`. Right for "does my
  app degrade gracefully", wrong for transport tuning.
- **Downlink only.** Upload bodies are not paced. `--bandwidth` conditions
  the response.
- **Background sessions are not conditioned** — they run out of process in
  `nsurlsessiond`, where the swizzle does not apply.
- **The re-issued request runs on a default configuration.** Per-session
  cookie stores and custom TLS handling on the app's own session are not
  reproduced. `httpAdditionalHeaders` survive, because they are merged before
  the request reaches a `URLProtocol`.
- **Apps must be launched after arming** — the dyld rule. Changing the
  condition afterwards reaches a running app fine.
- **In a debug React Native build the JS bundle download is conditioned too**,
  because it is URLSession traffic from the app's process. On `edge` a 23 MB
  bundle takes minutes. Arm with something mild, let the app load, then
  change the condition live.
- **Injected, not simulated.** This conditions the app's own process. Nothing
  outside it sees any of it, and a device not running an injected app has a
  perfectly normal network.
