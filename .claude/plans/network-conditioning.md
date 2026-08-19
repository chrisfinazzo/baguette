# Plan — network conditioning for baguette

Branch: `feat/network-conditioning`, cut from `feat/motion-activity` (PR #61)
so the dylib-injection infrastructure is already there.

---

## 1. Goal

Per-simulator network conditioning: latency, bandwidth, packet/request loss,
and hard offline — driven from the CLI, the HTTP API, and a browser card.

## 2. Why this is worth building (and isn't a reimplementation)

Network Link Conditioner and `dnctl`/`pfctl` dummynet already exist, but:

- They are **system-wide**. Simulator apps use the host's network stack as the
  host user, so there is no interface or process to scope a rule to. You
  degrade your whole Mac — and every other simulator — to test one app.
- They need **sudo**, and NLC is a separate prefpane install.

Per-app injection is the only way to condition **one simulator** while the rest
of the machine stays fast. That's the gap.

## 3. What already exists and should be reused, not rebuilt

Everything below landed with motion (PR #61) and is deliberately generic:

| Piece | File | Reuse |
| --- | --- | --- |
| Dylib descriptor | `Domain/Simulator/InjectedDylibInstallPlan.swift` | add `InjectedDylib.network` |
| Sha-keyed install | `Infrastructure/Simulator/InjectedDylibInstaller.swift` | `installIfNeeded(.network)` — no change |
| Shared env var | `Domain/Simulator/InjectedDylibs.swift` | already merges N dylibs by filename |
| Arming | `Infrastructure/Simulator/SimctlSimulatorInjection.swift` | no change |
| Intent-file pattern | `Infrastructure/Motion/SharedFileMotion.swift` | copy the shape for `SharedFileNetwork` |
| Dylib build/stage | `VirtualMotion/build.sh`, root `build.sh`, `Package.swift` | mirror for `VirtualNetwork/` |
| Route + session shape | `Server.applyMotion` / `MotionSessions` | network is **stateless** — no ledger, so simpler |

Read `docs/features/motion.md` first. It documents the injection channel, the
relaunch rule, and the `os_log`-not-`NSLog` rule (that one is load-bearing:
`NSLog` from an injected dylib pollutes the stdout of every spawned process,
including the `launchctl` used to read `DYLD_INSERT_LIBRARIES`).

## 4. Spike FIRST — do not design past these

Motion cost a day of ABI archaeology that a 20-minute probe would have caught.
Same discipline here. Each of these is a small ObjC binary or app, run against
a booted sim, before any Swift is written.

1. **Does a `URLProtocol` registered from a dylib constructor intercept a
   React Native `fetch`?** This is the whole feature's premise. RN's networking
   goes through `NSURLSession`; the question is whether it uses a configuration
   our swizzle reaches. Test against `avas-driver` (already installed on the
   `iPhone 17 - Driver` sim) — it makes real HTTP traffic and logs responses.
2. **Is `URLProtocol.registerClass` enough, or is the
   `URLSessionConfiguration.default` / `.ephemeral` getter swizzle required?**
   Expect: registration alone misses sessions built from custom configs, so
   both are needed. Verify rather than assume.
3. **Recursion guard.** Our protocol re-issues the request with a plain
   session; without a marker (`URLProtocol.setProperty` or a header) it will
   intercept its own request forever. Prove the guard works.
4. **Chunked delivery.** Confirm feeding the body via repeated
   `client:didLoadData:` at a timed rate actually paces the app's download,
   rather than the app seeing it all at completion.
5. **What is NOT intercepted.** Confirm and write down: `URLSessionWebSocketTask`,
   `NWConnection`/Network.framework, raw sockets, and anything doing its own
   TLS. Also check whether `AVPlayer`/HLS traffic is visible.

If (1) fails, stop and reconsider — a proxy-based approach would be the
fallback, and it has its own costs (needs a CA cert in the sim for HTTPS).

## 5. Shape (subject to what the spike finds)

### Wire / CLI

```bash
baguette network set --udid <UDID> --profile 3g          # named preset
baguette network set --udid <UDID> --latency 300 --bandwidth 400 --loss 5
baguette network set --udid <UDID> --offline
baguette network clear --udid <UDID>
```

`--latency` ms, `--bandwidth` kbps, `--loss` percent. Presets should borrow
Network Link Conditioner's familiar vocabulary (`edge`, `3g`, `lte`, `dsl`,
`very-bad-network`, `100-loss`) so the numbers aren't invented.

```
POST|GET|DELETE /simulators/:udid/network
{ "profile": "3g" }
{ "latencyMs": 300, "bandwidthKbps": 400, "lossPercent": 5 }
{ "offline": true }
```

### Domain (all TDD, all pure)

- `NetworkCondition` — value type; validated (non-negative latency, 0…100 loss,
  positive bandwidth); `Equatable`, `Sendable`.
- `NetworkProfile` — the named presets, as a `NetworkCondition` factory. Tests
  pin each preset's numbers so they can't drift silently.
- `NetworkCondition.encoded()` — sorted-key JSON, byte-for-byte test, exactly
  like `MotionIntent.encoded()`.
- **Chunk schedule maths belongs in Swift**, not the dylib: given
  `bandwidthKbps`, produce bytes-per-tick and tick interval. Same "policy in
  Swift, arithmetic in ObjC" split motion uses.
- `Network` (`@Mockable`) — `apply(_:on:)` / `clear(on:)`. Domain noun, no
  `Manager`/`Service` suffix (project rule).

### Infrastructure

- `SharedFileNetwork` — writes `/tmp/BaguetteNetwork.json` atomically, arms via
  `SimulatorInjection`. Tests write to a temp dir and read the bytes back; the
  only mocked collaborator is injection. **Don't invent a mockable file sink.**
- `Simulator.network()` factory beside `motion()`.

### Dylib — `VirtualNetwork/`

Mirror `VirtualMotion/`: `VirtualNetworkIntent.{h,m}` (poll + parse the
condition file), `VirtualNetworkProtocol.m` (the `URLProtocol` subclass),
`VirtualNetworkHooks.m` (constructor + config swizzle + self-check).

Rules carried over from motion:
- `os_log` only, subsystem `com.baguette.network`.
- A **self-check at load** that refuses to install if it can't register — an
  app is better off with real networking than half-broken networking.
- Log each conditioned request (throttled), and log the arming banner. The
  motion work proved that "is it even reaching my app?" is the question you
  always end up asking.

### Browser

Its own card + toolbar button (it isn't location-related). Must show a
**prominent armed state** — see safety below.

## 6. Safety — this one is more dangerous than the camera

A forgotten camera toggle is obvious (the picture is wrong). A forgotten
throttle is invisible and will read as "the app is slow" or "the backend is
flaky", possibly days later. Design against that:

- Loud, persistent armed badge in the browser while conditioning is on.
- `baguette network` with no args should **report the current condition**, so
  it's one command to check.
- Consider a TTL (`--for 5m`) that auto-clears; at minimum, decide deliberately
  and document the choice.
- The dylib's request log makes it traceable after the fact.

## 7. TDD sequence

Each cycle red → green → commit, full suite green before moving on.

1. `NetworkCondition` validation + `NetworkProfile` presets.
2. `NetworkCondition.encoded()` byte-for-byte.
3. Chunk-schedule maths.
4. `Network` protocol + `SharedFileNetwork` (temp dir + `MockSimulatorInjection`).
5. `InjectedDylib.network` + installer wiring (extend the existing tests).
6. CLI `network set|clear` parse tests, then `RootCommand` registration (the
   "root lists every subcommand" test will catch the addition).
7. Server `parseNetworkRequest` / `applyNetwork` / `clearNetwork` + routes.
8. Dylib + `build.sh`/`Package.swift` staging.
9. Browser card.
10. Docs: `docs/features/network.md`, CHANGELOG, `skills/baguette/` refs.

## 8. Limits to state honestly in the docs

- **URLSession-shaped traffic only.** No `NWConnection`, raw sockets, most gRPC
  stacks, or `URLSessionWebSocketTask`. For REST/GraphQL/image loading —
  including RN's `fetch` — that's the traffic people mean; for a video player
  it may not be.
- **Request-level, not packet-level.** "20% loss" means 20% of requests fail:
  no partial transfers, no retransmits, no congestion-window behaviour. Right
  for "does my app degrade gracefully", wrong for transport tuning.
- **Only apps launched after arming** — the dyld rule, same as motion.
- **One condition per host** while the intent file is a single shared path
  (same limitation motion has today).

## 9. Definition of done

- Full Swift suite + `make test-web` green.
- Verified end-to-end against `avas-driver` on the Driver sim: a conditioned
  request visibly slower, a lossy profile producing real `NSURLError`s in the
  app's own logs.
- Feature doc, CHANGELOG, skill references.
- Release path (`./build.sh`) builds and stages the new dylib.
