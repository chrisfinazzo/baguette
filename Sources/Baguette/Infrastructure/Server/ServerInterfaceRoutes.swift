import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The interface-settings routes — appearance, Increase Contrast and
/// content size. Kept out of `Server.swift`'s main body for the same
/// reason the plugin routes are: that file's router-builder inference
/// grinds once too many closures share one function.
extension Server {

    /// `GET  /simulators/:udid/interface.json`   all three settings
    /// `POST /simulators/:udid/interface`        set any subset
    ///
    /// Both are browser-facing and ride the existing browser-trust
    /// check. Both are also plugin-reachable under the `interface`
    /// capability — `PluginGrantMiddleware` has already turned away a
    /// plugin that didn't declare it by the time these run.
    func registerInterfaceRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let simulators = self.simulators

        router.get("/simulators/:udid/interface.json") { r, _ in
            if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                return rejected
            }
            switch await Self.readInterface(udid: Self.udidParam(r), simulators: simulators) {
            case .ok(let json):
                return Self.jsonResponse(json)
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }

        router.post("/simulators/:udid/interface") { r, _ in
            if Self.presentsGrant(r) == false, let rejected = rejectUntrustedBrowser(r) {
                return rejected
            }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            guard let update = Self.parseInterfaceUpdate(json: body) else {
                return Self.pluginError(
                    "interface body must be a JSON object naming appearance, "
                        + "increaseContrast and/or contentSize with settable values",
                    status: .badRequest
                )
            }
            switch await Self.applyInterface(
                udid: Self.udidParam(r), update: update, simulators: simulators
            ) {
            case .ok:
                // Answer with the resulting state so a caller that just
                // changed something doesn't need a second round-trip to
                // re-render — and sees what actually landed, not what it
                // asked for.
                switch await Self.readInterface(udid: Self.udidParam(r), simulators: simulators) {
                case .ok(let json): return Self.jsonResponse(json)
                default: return Self.jsonResponse(#"{"ok":true}"#)
                }
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }
    }

    // MARK: - parse

    /// Parse a `POST /simulators/:udid/interface` body. Nil when the
    /// body isn't a JSON object, or when a field names a value that can
    /// only be read — so a bad request is refused whole rather than
    /// half-applied.
    static func parseInterfaceUpdate(json: String) -> InterfaceUpdate? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return InterfaceUpdate.from(json: object)
    }

    // MARK: - read

    enum InterfaceReadOutcome: Equatable {
        case ok(String)
        case unknownDevice
        case failed(String)
    }

    /// All three settings in one answer.
    ///
    /// A device that isn't booted reports `unknown` for each rather than
    /// failing the request — that's a state the caller needs to be able
    /// to render ("boot the device"), not an error.
    static func readInterface(
        udid: String, simulators: any Simulators
    ) async -> InterfaceReadOutcome {
        guard let sim = simulators.find(udid: udid) else { return .unknownDevice }
        let interface = sim.interface()
        do {
            let reading = InterfaceReading(
                appearance: try await interface.appearance(),
                increaseContrast: try await interface.increaseContrast(),
                contentSize: try await interface.contentSize()
            )
            return .ok(reading.json)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - apply

    enum InterfaceApplyOutcome: Equatable {
        case ok
        case unknownDevice
        case failed(String)
    }

    /// Dispatch only the settings the body named. Each is its own
    /// `simctl` spawn, so a partial body means fewer spawns rather than
    /// a read-modify-write of the two it didn't mention.
    static func applyInterface(
        udid: String, update: InterfaceUpdate, simulators: any Simulators
    ) async -> InterfaceApplyOutcome {
        guard let sim = simulators.find(udid: udid) else { return .unknownDevice }
        let interface = sim.interface()
        do {
            if let appearance = update.appearance {
                try await interface.setAppearance(appearance)
            }
            if let contrast = update.increaseContrast {
                try await interface.setIncreaseContrast(contrast)
            }
            if let contentSize = update.contentSize {
                try await interface.setContentSize(contentSize)
            }
            return .ok
        } catch {
            return .failed(String(describing: error))
        }
    }
}
