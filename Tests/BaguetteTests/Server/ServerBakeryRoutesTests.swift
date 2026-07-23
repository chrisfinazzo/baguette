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
            given(checkout).clone(.any, into: .any).willProduce { _, into in
                try BakeryInstallTests.Env.writeBakery(into: into, withMenu: true)
                return CheckoutResult(directory: into, commit: "c0ffee")
            }
            given(checkout).pull(at: .any).willReturn("c0ffee")
            install = BakeryInstall(checkout: checkout, home: home)
        }
    }
}
