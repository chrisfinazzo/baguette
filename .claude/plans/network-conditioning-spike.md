# Spike results — network conditioning

Run 2026-08-18 against `app.avas.driver` (a React Native dev build, Expo
Router + Hermes) on **iPhone 17 - Driver** `FDF48F28-12D6-4772-84D5-489516D81A37`,
iOS 26.5. Probe source: `scratchpad/spike/Sources/SpikeNet.m` — a throwaway
dylib armed through the same `DYLD_INSERT_LIBRARIES` channel motion uses,
logging via `os_log` subsystem `com.baguette.network`.

The probe is switchable at load through `/tmp/SpikeNet.mode`
(`register` | `swizzle` | `both`) so the two interception mechanisms could be
measured separately rather than assumed.

---

## 1. Does a `URLProtocol` registered from a dylib constructor intercept RN's `fetch`? — **YES**

In `both` mode the app's real traffic was intercepted, conditioned and
delivered, with the app continuing to work:

| Traffic | Example | Intercepted |
| --- | --- | --- |
| RN `fetch` / REST API | `GET https://megatron.avas.dev/v2/api/driver/bites/orders/active` | yes |
| RN `fetch` POST | `POST https://megatron.avas.dev/v2/api/geo/v3/locate` | yes |
| RN image loading | `GET https://d3u74tt9fb4uap.cloudfront.net/app-icons/…png` | yes |
| MapLibre vector tiles (native) | `GET https://tiles.avasapp.com/data/v3/16/46153/32000.pbf` | yes |
| MapLibre style | `GET https://demotiles.maplibre.org/style.json` | yes |
| Ably **REST** token request | `POST https://main.realtime.ably.net/keys/…/requestToken` | yes |
| Metro dev server | `GET http://192.168.0.15:8101/…index.ts.bundle` | yes |

TLS is unaffected — the protocol re-issues through `URLSession`, which does
its own handshake, so HTTPS hosts need no certificate work.

## 2. Is `+registerClass:` enough? — **NO. The configuration-getter swizzle is required.**

Measured, not assumed. A 100-second `register`-only run with the app fully
launched and online intercepted **zero** app-domain requests. The only thing
it saw was the Metro dev-server `HEAD`/`GET`, which RN issues through
`NSURLSession.shared`.

- `+[NSURLProtocol registerClass:]` reaches `NSURLConnection` and
  `NSURLSession.shared` only.
- Everything else — RN's `fetch` (`RCTHTTPRequestHandler` builds its own
  session from `defaultSessionConfiguration`), MapLibre, image loading, Ably's
  REST client — needs `+[NSURLSessionConfiguration defaultSessionConfiguration]`
  and `ephemeralSessionConfiguration` swizzled to insert the protocol class
  into `protocolClasses`.

**Both are needed.** Keep `registerClass` for the shared-session and
`NSURLConnection` users; the swizzle is what makes the feature actually work.

## 3. Recursion guard — **holds, and is genuinely load-bearing**

With the swizzle installed, the inner request built from
`ephemeralSessionConfiguration` *does* re-enter our own protocol. The marker
(`+[NSURLProtocol setProperty:forKey:inRequest:]`, checked in
`+canInitWithRequest:`) declined every one of them:

```
[SpikeNet] guard: declining our own re-issued https://megatron.avas.dev/v2/api/traffic
```

Without it this is an infinite loop, not a slow request. In `register`-only
mode it never fired, which is why the guard has to be proven under the
swizzle, not under registration.

## 4. Chunked delivery — **works, including on a 23 MB body**

Feeding the body through repeated `-URLProtocol:didLoadData:` paces the app's
download rather than arriving as one blob at completion:

```
finished …/index.ts.bundle — 23042023 bytes in 8 chunks over 5.31s
finished https://megatron.avas.dev/v2/api/app/v2/driver-location-config — 298 bytes in 8 chunks over 4.41s
```

The app loaded and ran normally throughout.

**Design note for the real implementation:** the probe buffers the whole
response and *then* replays it in slices, so wall-clock is
`upstream time + paced time` and a 23 MB body sits in memory. The shipped
version should pace as bytes arrive (hold a byte budget, release on a timer
from `didReceiveData:`) rather than buffer-then-replay.

## 5. The POST-body trap — **real, and survived**

`NSURLProtocol` never hands over `HTTPBody`; every body arrived as
`HTTPBodyStream`:

```
body for POST https://megatron.avas.dev/v2/api/geo/v3/locate: HTTPBody=0 bytes, HTTPBodyStream=present
```

Passing the stream through on the `mutableCopy` preserves it — every
conditioned POST came back `200`/`201`, including Ably's HMAC-signed
`requestToken` (`201`) and `geo/v3/locate` (`200`), both of which would fail
on a corrupted or empty body.

**The constraint this creates: a body stream can be read exactly once, so the
conditioner must never retry a request.** A retry-on-failure design would
silently send an empty body and look like a server bug.

## 6. Live re-configuration without relaunch — **works**

The probe re-reads its condition file on an mtime-keyed 100 ms stat, the same
shape as `VMIntentCurrent`. Changing the file mid-flight changed the applied
condition with no app relaunch. Only the **initial arm** needs the relaunch —
the same rule motion documents.

Flipping `offline` mid-flight produced real `NSURLError`s inside the app
within milliseconds of the file changing:

```
knobs reloaded — latency=300ms loss=0% offline=1
failing https://megatron.avas.dev/v2/api/driver/ride/v2/ongoing as offline (NSURLError -1009)
failing https://megatron.avas.dev/v2/api/driver/v2/current-bid-orders as offline (NSURLError -1009)
failing https://megatron.avas.dev/v2/api/driver/pending-jobs as offline (NSURLError -1009)
```

## 7. What is NOT intercepted

- **`URLSessionWebSocketTask` and any Network.framework (`NWConnection`)
  traffic.** Structural, not incidental: `URLProtocol` is part of the URL
  Loading System, and these bypass it entirely. Confirmed in practice — Ably's
  REST token request appears in the log, its realtime WebSocket never does.
- **Raw sockets, and stacks doing their own TLS** (most gRPC).
- **`background` session configurations** — those run out of process in
  `nsurlsessiond`, where our swizzle does not apply.
- Anything in a process launched *before* arming, per the dyld rule.

### And this gap is not theoretical

With `offline` on and every REST call failing with `-1009`, the driver app's
UI **did not change at all** — still "Online", still "Finding ride requests",
map still drawn from cache. Its connectivity state is driven by an Ably
WebSocket that `URLProtocol` cannot see.

So for an app with a WebSocket realtime layer, "offline" degrades the request
traffic without the app ever noticing it went offline. That's the honest
shape of this feature, and it has to be said plainly in the docs rather than
discovered by a user who concludes the throttle isn't working.



---

## Verdict

The premise holds. Proceed with the `URLProtocol` approach, with these
corrections to the plan:

1. Ship **both** mechanisms (`registerClass` + config-getter swizzle), and
   describe the swizzle as the load-bearing one.
2. Pace bytes as they arrive; do not buffer-then-replay.
3. Never retry a conditioned request — the body stream is single-read.
4. Document the WebSocket / `NWConnection` gap as a first-class limit; for an
   app whose realtime layer is a WebSocket, "offline" will not feel offline.
