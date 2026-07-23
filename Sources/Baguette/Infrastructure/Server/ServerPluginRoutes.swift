import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Plugin-facing route helpers, kept out of `Server.swift`'s main body
/// — that file's router-builder inference already grinds when too many
/// closures share one function, and these are independently testable
/// anyway.
extension Server {

    // MARK: - registration

    /// `GET  /plugins.json`                         installed manifests
    /// `POST /plugins/:id/commands/:cmd`            run a contribution
    /// `GET  /simulators/:udid/describe-ui.json`    AX tree over HTTP
    ///
    /// The first two are browser-facing and ride the existing
    /// browser-trust check. `describe-ui.json` is one plugins call, so
    /// it also accepts a **capability grant** — a plugin subprocess has
    /// no `Origin` header to be trusted by, and its token carries only
    /// what its manifest declared.
    func registerPluginRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let plugins = self.plugins
        let simulators = self.simulators
        let grants = self.grants
        let origin = "http://\(self.host):\(self.port)"

        router.get("/plugins.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let body = (try? plugins.listJSON) ?? #"{"plugins":[]}"#
            return Response(
                status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                body: .init(byteBuffer: ByteBuffer(string: body))
            )
        }

        router.post("/plugins/:id/commands/:cmd") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let qualified = Self.qualifiedCommandParam(r)
            let outcome = await Self.runPlugin(
                qualified: qualified,
                context: PluginDispatch.Context(
                    serverURL: origin,
                    udid: r.uri.queryParameters.get("udid").map { String($0) },
                    // Replaced by a per-invocation grant inside dispatch.
                    token: ""
                ),
                plugins: plugins,
                grants: grants
            )
            switch outcome {
            case .ok(let json):
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(string: json))
                )
            case .unknown(let message):
                return Self.pluginError(message, status: .notFound)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }

        // The gesture pipeline over HTTP, so a plugin can drive the
        // device without holding a WebSocket. `input` is the most
        // powerful capability — it can tap through anything — so it is
        // never implied and must be declared.
        router.post("/simulators/:udid/input") { r, _ in
            let presented = r.headers[HTTPField.Name("X-Baguette-Token")!]
            if !grants.allows(token: presented, capability: .input) {
                if presented != nil {
                    return Self.pluginError(
                        "this plugin did not declare the \"input\" capability", status: .forbidden
                    )
                }
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
            }
            let buffer = try? await r.body.collect(upTo: 64 * 1024)
            let body = buffer.map { String(buffer: $0) } ?? ""
            switch await Self.dispatchInput(
                udid: Self.udidParam(r), body: body, simulators: simulators
            ) {
            case .ok(let ack):
                return Self.jsonResponse(ack)
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(Self.udidParam(r))", status: .notFound)
            }
        }

        router.get("/simulators/:udid/describe-ui.json") { r, _ in
            // Either a trusted browser, or a plugin whose grant carries
            // `describe-ui`. A plugin that didn't declare it is refused
            // even though it holds a valid token for something else.
            let presented = r.headers[HTTPField.Name("X-Baguette-Token")!]
            if !grants.allows(token: presented, capability: .describeUI) {
                if presented != nil {
                    return Self.pluginError(
                        "this plugin did not declare the \"describe-ui\" capability",
                        status: .forbidden
                    )
                }
                if let rejected = rejectUntrustedBrowser(r) { return rejected }
            }
            let udid = Self.udidParam(r)
            let x = r.uri.queryParameters.get("x").flatMap { Double($0) }
            let y = r.uri.queryParameters.get("y").flatMap { Double($0) }
            let point = (x != nil && y != nil) ? Point(x: x!, y: y!) : nil

            switch Self.describeUI(udid: udid, point: point, simulators: simulators) {
            case .ok(let json):
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                    body: .init(byteBuffer: ByteBuffer(string: json))
                )
            case .unknownDevice:
                return Self.pluginError("unknown udid: \(udid)", status: .notFound)
            case .noData:
                return Self.pluginError("no accessibility data", status: .ok)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }
    }

    /// `/plugins/<id>/commands/<cmd>` → `"<id>:<cmd>"`. Parsed off the
    /// path rather than router parameters, matching `udidParam`.
    static func qualifiedCommandParam(_ request: Request) -> String {
        let parts = request.uri.path.split(separator: "/")
        guard parts.count >= 4 else { return "" }
        let id = String(parts[1]).removingPercentEncoding ?? ""
        let command = String(parts[3]).removingPercentEncoding ?? ""
        return "\(id):\(command)"
    }

    /// `{"ok":false,"error":…}` — the shape every plugin-facing route
    /// answers with, so a plugin has exactly one failure branch.
    static func pluginError(_ message: String, status: HTTPResponse.Status) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(
                string: #"{"ok":false,"error":"\#(GestureDispatcher.jsonEscape(message))"}"#
            ))
        )
    }

    // MARK: - describe-ui.json

    enum DescribeUIOutcome: Equatable {
        case ok(String)
        case unknownDevice
        /// Nothing is frontmost (SpringBoard idle, boot in progress).
        /// Not an error: the caller should say "nothing to inspect",
        /// not "inspection failed".
        case noData
        case failed(String)
    }

    /// The accessibility tree over plain HTTP.
    ///
    /// `describe_ui` existed only as a WebSocket message on the stream
    /// socket, which put the tree out of reach of any plugin that
    /// isn't a browser. Same logic, addressable by `curl`.
    static func describeUI(
        udid: String, point: Point?, simulators: any Simulators
    ) -> DescribeUIOutcome {
        guard let sim = simulators.find(udid: udid) else { return .unknownDevice }
        do {
            let node = try point.map { try sim.accessibility().describeAt(point: $0) }
                ?? sim.accessibility().describeAll()
            guard let node else { return .noData }
            return .ok(#"{"ok":true,"tree":\#(node.json)}"#)
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - input

    enum InputOutcome: Equatable {
        /// The dispatcher's own one-line ack — `{"ok":true}` or
        /// `{"ok":false,"error":…}` for a envelope it couldn't parse.
        case ok(String)
        case unknownDevice
    }

    /// Dispatch one gesture envelope, the same JSON the stream socket
    /// and `baguette input` accept.
    ///
    /// Hops to `MainActor` because `IndigoHIDMessageForMouseNSEvent`
    /// reads AppKit / NSEvent thread-local state — building it on a NIO
    /// event-loop thread yields messages the simulator silently drops.
    /// `Server.streamWS` does the same before dispatching.
    static func dispatchInput(
        udid: String, body: String, simulators: any Simulators
    ) async -> InputOutcome {
        guard let sim = simulators.find(udid: udid) else { return .unknownDevice }
        let input = sim.input()
        let ack = await MainActor.run {
            GestureDispatcher(input: input).dispatch(line: body)
        }
        return .ok(ack)
    }

    // MARK: - running a contributed command

    enum PluginRunOutcome: Equatable {
        case ok(String)
        case unknown(String)
        case failed(String)
    }

    static func runPlugin(
        qualified: String,
        context: PluginDispatch.Context,
        plugins: any Plugins,
        grants: PluginGrants? = nil,
        subprocess: @Sendable () -> any Subprocess = { HostSubprocess() }
    ) async -> PluginRunOutcome {
        let outcome = await PluginDispatch.run(
            qualifiedCommand: qualified,
            context: context,
            plugins: plugins,
            grants: grants,
            subprocess: subprocess
        )
        switch outcome {
        case .ok(let result):
            return .ok(result.json)
        case .unknownCommand:
            return .unknown(outcome.errorText ?? "unknown command")
        default:
            return .failed(outcome.errorText ?? "plugin failed")
        }
    }

}

extension PluginResult {
    /// Wire projection for the plugin routes and the CLI.
    var json: String {
        var dict: [String: Any] = ["ok": ok, "rows": rows.map(\.dictionary)]
        if let message { dict["message"] = message }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension ResultRow {
    var dictionary: [String: Any] {
        var out: [String: Any] = ["title": title, "severity": severity.rawValue]
        if let subtitle { out["subtitle"] = subtitle }
        if let copy { out["copy"] = copy }
        if let frame {
            out["frame"] = [
                "x": frame.origin.x, "y": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height,
            ]
        }
        return out
    }
}
