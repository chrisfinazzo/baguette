import Testing
import Foundation
import Mockable
@testable import Baguette

/// Handler-level coverage for the bakery routes — the pure preview /
/// install helpers, not the Hummingbird `Response` wrappers. Git is
/// mocked; the registry + copy run against a throwaway home.
@Suite("Server bakery routes")
struct ServerBakeryRoutesTests {

    // MARK: - preview

    @Test func `preview returns the menu and does not trust the bakery`() async throws {
        let env = try Env()
        let outcome = await Server.previewBakery(reference: "acme/tools", install: env.install)
        guard case .ok(let json) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }

        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["commit"] as? String == "c0ffee")
        #expect(parsed?["alreadyTrusted"] as? Bool == false)
        let plugins = try #require(parsed?["plugins"] as? [[String: Any]])
        #expect(plugins.first?["name"] as? String == "hello")
        // Preview must not have recorded anything.
        #expect(try env.registry.bakeries().isEmpty)
    }

    @Test func `preview reports a malformed reference`() async throws {
        let env = try Env()
        let outcome = await Server.previewBakery(reference: "not a ref", install: env.install)
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }

    // MARK: - listing

    @Test func `listing answers the trusted bakeries`() async throws {
        let env = try Env()
        _ = await Server.installBakery(
            reference: "acme/tools", plugin: nil, accept: true, install: env.install
        )
        guard case .ok(let json) = Server.listBakeries(home: env.home) else {
            Issue.record("expected .ok"); return
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let bakeries = try #require(parsed?["bakeries"] as? [[String: Any]])
        #expect(bakeries.first?["commit"] as? String == "c0ffee")
    }

    @Test func `a registry that cannot be read is a failure, not an empty list`() throws {
        // A corrupt or unreadable `bakeries.json` used to render in the
        // UI as "no bakeries added" — indistinguishable from a fresh
        // install, and the next write would have made it true.
        let env = try Env()
        try FileManager.default.createDirectory(
            at: env.home.appendingPathComponent("bakeries.json"),
            withIntermediateDirectories: true
        )
        guard case .failed = Server.listBakeries(home: env.home) else {
            Issue.record("expected .failed"); return
        }
    }

    // MARK: - install

    @Test func `install without explicit consent is refused`() async throws {
        // The route is powerful — it clones and writes files — so it
        // will not run without the modal's deliberate accept.
        let env = try Env()
        let outcome = await Server.installBakery(
            reference: "acme/tools", plugin: "hello", accept: false, install: env.install
        )
        #expect(outcome == .rejected)
        #expect(try env.registry.installed().isEmpty)
    }

    @Test func `install with consent installs and returns the plugin`() async throws {
        let env = try Env()
        let outcome = await Server.installBakery(
            reference: "acme/tools", plugin: "hello", accept: true, install: env.install
        )
        guard case .ok(let json) = outcome else { Issue.record("expected .ok, got \(outcome)"); return }
        #expect(json.contains("hello"))
        #expect(try env.registry.installed().map(\.name) == ["hello"])
    }

    // MARK: - fixture (mirrors BakeryInstallTests.Env)

    struct Env {
        let home: URL
        let install: BakeryInstall
        let registry: FileSystemBakeries

        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-route-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            registry = FileSystemBakeries(home: home)

            let checkout = MockCheckout()
            given(checkout).clone(.any, into: .any, at: .any).willProduce { _, into, _ in
                try BakeryInstallTests.Env.writeBakery(into: into, withMenu: true)
                return CheckoutResult(directory: into, commit: "c0ffee")
            }
            given(checkout).pull(at: .any).willReturn("c0ffee")
            install = BakeryInstall(checkout: checkout, home: home)
        }
    }
}
