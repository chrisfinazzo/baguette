import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the plugin routes, matching the
/// house style: the pure parse + dispatch helpers are tested, not the
/// Hummingbird `Response` wrappers.
@Suite("Server plugin routes")
struct PluginRoutesTests {

    // MARK: - describe-ui.json

    @Test func `describeUI projects the tree for a plugin that has no WebSocket`() throws {
        // `describe_ui` was WS-only, which put the AX tree out of reach
        // of a subprocess plugin entirely. This route is what makes the
        // reference a11y plugin possible.
        let outcome = Server.describeUI(udid: "U", point: nil, simulators: Self.simulators())
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == true)
        let tree = try #require(parsed?["tree"] as? [String: Any])
        #expect(tree["role"] as? String == "AXApplication")
    }

    @Test func `describeUI hit-tests a point when one is given`() throws {
        let ax = MockAccessibility()
        given(ax).describeAt(point: .value(Point(x: 10, y: 20)))
            .willReturn(AXNode(role: "AXButton", frame: Self.frame))
        let outcome = Server.describeUI(
            udid: "U", point: Point(x: 10, y: 20), simulators: Self.simulators(ax: ax)
        )
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(json.contains("AXButton"))
    }

    @Test func `describeUI reports an unknown device`() throws {
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(nil)
        #expect(Server.describeUI(udid: "nope", point: nil, simulators: simulators) == .unknownDevice)
    }

    @Test func `describeUI reports no data when nothing is frontmost`() throws {
        // SpringBoard idle or a boot in progress. Not an error — the
        // plugin should say "nothing to audit", not "audit failed".
        let ax = MockAccessibility()
        given(ax).describeAll().willReturn(nil)
        #expect(Server.describeUI(udid: "U", point: nil, simulators: Self.simulators(ax: ax)) == .noData)
    }

    // MARK: - running a command

    @Test func `runPlugin returns the plugin's rows as JSON`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:audit",
            context: Self.context,
            plugins: Self.plugins(),
            subprocess: { Self.subprocess(stdout: #"{"ok":true,"rows":[{"title":"No label"}]}"#) }
        )
        guard case .ok(let json) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["ok"] as? Bool == true)
        let rows = try #require(parsed?["rows"] as? [[String: Any]])
        #expect(rows.first?["title"] as? String == "No label")
    }

    @Test func `runPlugin reports an unknown command as not-found`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:nope", context: Self.context, plugins: Self.plugins(),
            subprocess: { Self.subprocess() }
        )
        #expect(outcome == .unknown(#"no installed plugin contributes "a11y:nope""#))
    }

    @Test func `runPlugin surfaces a plugin that failed to run`() async throws {
        let outcome = await Server.runPlugin(
            qualified: "a11y:audit", context: Self.context, plugins: Self.plugins(),
            subprocess: { Self.subprocess(stdout: "boom", exitCode: 3) }
        )
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(message.contains("exited 3"))
    }

    // MARK: - the session token

    @Test func `a plugin API call without the session token is rejected`() throws {
        // Plugin subprocesses reach the server with no Origin header,
        // which `isTrustedBrowserRequest` trusts outright. That's fine
        // while the API is internal and not fine once it's advertised,
        // so the plugin-facing routes check a per-session token.
        #expect(!Server.isTrustedPluginRequest(token: nil, sessionToken: "secret"))
        #expect(!Server.isTrustedPluginRequest(token: "guess", sessionToken: "secret"))
        #expect(Server.isTrustedPluginRequest(token: "secret", sessionToken: "secret"))
    }

    @Test func `each serve session mints a fresh token`() throws {
        #expect(Server.makeSessionToken() != Server.makeSessionToken())
        #expect(Server.makeSessionToken().count >= 32)
    }

    // MARK: - helpers

    static let frame = Rect(origin: Point(x: 0, y: 0), size: Size(width: 100, height: 100))
    static let context = PluginDispatch.Context(
        serverURL: "http://127.0.0.1:8421", udid: "U", token: "tok"
    )

    static func simulators(ax: MockAccessibility? = nil) -> MockSimulators {
        let accessibility = ax ?? {
            let mock = MockAccessibility()
            given(mock).describeAll().willReturn(AXNode(role: "AXApplication", frame: frame))
            return mock
        }()
        let sim = MockSimulator()
        given(sim).accessibility().willReturn(accessibility)
        let simulators = MockSimulators()
        given(simulators).find(udid: .any).willReturn(sim)
        return simulators
    }

    static func plugins() -> MockPlugins {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.0.0", apiVersion: 1,
                    commands: [PluginCommand(id: "audit", title: "Audit", run: ["true"])]
                )
            )
        ])
        return plugins
    }

    static func subprocess(stdout: String = #"{"ok":true}"#, exitCode: Int32 = 0) -> MockSubprocess {
        let sub = MockSubprocess()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, _, _, _, _, onBytes, onExit in
            onBytes(Data(stdout.utf8))
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return sub
    }
}
