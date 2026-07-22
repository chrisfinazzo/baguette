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
    /// browser-trust check. `describe-ui.json` is the one plugins call,
    /// so it additionally accepts the session token — a plugin
    /// subprocess has no `Origin` header to be trusted by.
    func registerPluginRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let plugins = self.plugins
        let simulators = self.simulators
        let token = self.sessionToken
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
                    token: token
                ),
                plugins: plugins
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

        router.get("/simulators/:udid/describe-ui.json") { r, _ in
            // Either a trusted browser, or a plugin presenting the
            // session token this `serve` minted.
            let presented = r.headers[HTTPField.Name("X-Baguette-Token")!]
            if !Self.isTrustedPluginRequest(token: presented, sessionToken: token),
               let rejected = rejectUntrustedBrowser(r) {
                return rejected
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
        subprocess: @Sendable () -> any Subprocess = { HostSubprocess() }
    ) async -> PluginRunOutcome {
        let outcome = await PluginDispatch.run(
            qualifiedCommand: qualified,
            context: context,
            plugins: plugins,
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

    // MARK: - the session token

    /// Plugin subprocesses call back in with no `Origin` header, and
    /// `isTrustedBrowserRequest` trusts those outright — correct for a
    /// CLI client on a loopback bind, wrong once the surface is
    /// advertised as a plugin API. A per-session token is what
    /// separates "a plugin baguette launched" from "any local process".
    ///
    /// Deliberately scoped to the plugin routes only: retro-fitting it
    /// onto the existing routes would break every script and host
    /// plugin already calling them.
    static func makeSessionToken() -> String {
        // 32 hex chars from the system CSPRNG.
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func isTrustedPluginRequest(token: String?, sessionToken: String) -> Bool {
        guard let token, !sessionToken.isEmpty else { return false }
        // Constant-time-ish: compare full length regardless of where
        // the first difference lands.
        guard token.utf8.count == sessionToken.utf8.count else { return false }
        return zip(token.utf8, sessionToken.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
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
