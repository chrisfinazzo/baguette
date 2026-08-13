import Foundation
import Mockable
import Testing

@testable import Baguette

/// `GET /simulators/:udid/companion-screens.json` — what the focus-mode
/// screens rail asks before it offers anything. A device with no CarPlay
/// and no paired watch is a perfectly good answer, so only an unknown
/// udid is an error.
@Suite("Companion screens route")
struct CompanionScreensRouteTests {

    @Test func `a device with both screens answers with both`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let pairing = MockWatchPairing()
        given(external).isCarPlayConnected.willReturn(true)
        given(pairing).watch.willReturn(
            PairedWatch(udid: "WATCH-1", name: "Apple Watch Ultra 3", state: .booted)
        )
        given(sim).externalDisplays().willReturn(external)
        given(sim).watchPairing().willReturn(pairing)

        let simulators = MockSimulators()
        given(simulators).find(udid: .value("PHONE-1")).willReturn(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", simulators: simulators)
                == .ok("""
                    {"carplay":{"available":true},"watch":{"available":true,\
                    "name":"Apple Watch Ultra 3","state":"Booted","udid":"WATCH-1"}}
                    """)
        )
    }

    @Test func `a plain device answers that it has neither`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let pairing = MockWatchPairing()
        given(external).isCarPlayConnected.willReturn(false)
        given(pairing).watch.willReturn(nil)
        given(sim).externalDisplays().willReturn(external)
        given(sim).watchPairing().willReturn(pairing)

        let simulators = MockSimulators()
        given(simulators).find(udid: .value("PHONE-1")).willReturn(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", simulators: simulators)
                == .ok(#"{"carplay":{"available":false},"watch":{"available":false}}"#)
        )
    }

    @Test func `an unknown udid is the only failure`() {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)

        #expect(
            Server.readCompanionScreens(udid: "nope", simulators: simulators) == .unknownDevice
        )
    }

    /// Probing CarPlay shells out to `simctl io enumerate`; a device
    /// that has just shut down makes that fail. The rail still needs an
    /// answer it can render, so a failed probe reads as "not connected"
    /// rather than taking the whole route down with it.
    @Test func `a CarPlay probe that can't run reads as not connected`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let pairing = MockWatchPairing()
        given(external).isCarPlayConnected.willReturn(false)
        given(pairing).watch.willReturn(nil)
        given(sim).externalDisplays().willReturn(external)
        given(sim).watchPairing().willReturn(pairing)

        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)

        #expect(
            Server.readCompanionScreens(udid: "PHONE-1", simulators: simulators)
                == .ok(#"{"carplay":{"available":false},"watch":{"available":false}}"#)
        )
    }
}
