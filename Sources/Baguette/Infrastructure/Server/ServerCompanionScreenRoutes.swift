import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The companion-screens route — what the focus-mode rail asks before
/// it offers anything. Kept out of `Server.swift`'s main body for the
/// same reason the interface and plugin routes are: that file's
/// router-builder inference grinds once too many closures share one
/// function.
extension Server {

    /// `GET /simulators/:udid/companion-screens.json`
    ///
    /// Browser-facing only. It reports what the host has attached to a
    /// device, which is the sort of thing a plugin should have to
    /// declare a capability for, and no capability covers it yet — so
    /// it rides the browser-trust check alone.
    func registerCompanionScreenRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let simulators = self.simulators

        router.get("/simulators/:udid/companion-screens.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch Self.readCompanionScreens(udid: Self.udidParam(r), simulators: simulators) {
            case .ok(let json):
                return Self.jsonResponse(json)
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
            }
        }
    }

    enum CompanionScreensOutcome: Equatable {
        case ok(String)
        case unknownDevice
    }

    /// What extra screens this device can show right now.
    ///
    /// Only an unknown udid fails. Both probes answer "no" rather than
    /// throwing — `isCarPlayConnected` swallows a `simctl` spawn that
    /// won't run, and an unreadable pairing table yields no watch — so
    /// a device that is merely shut down still gets a renderable answer
    /// instead of a 500 the rail would have to guess at.
    static func readCompanionScreens(
        udid: String, simulators: any Simulators
    ) -> CompanionScreensOutcome {
        guard let sim = simulators.find(udid: udid) else { return .unknownDevice }
        let screens = CompanionScreens(
            carPlayConnected: sim.externalDisplays().isCarPlayConnected,
            watch: sim.watchPairing().watch
        )
        return .ok(screens.json)
    }
}
