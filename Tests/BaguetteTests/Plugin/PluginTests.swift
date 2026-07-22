import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("Plugin")
struct PluginTests {

    // MARK: - namespacing

    @Test func `a command's qualified id joins the plugin name and the command id`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.qualifiedCommandIDs == ["a11y:audit"])
    }

    @Test func `a command is found by its qualified id`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.command(qualified: "a11y:audit")?.id == "audit")
    }

    @Test func `a command is not found under another plugin's namespace`() throws {
        // Two plugins may both contribute `reload`; the namespace is
        // what keeps them apart, so a bare or foreign prefix must miss.
        let plugin = Self.make(name: "expo", commandIDs: ["reload"])
        #expect(plugin.command(qualified: "detox:reload") == nil)
        #expect(plugin.command(qualified: "reload") == nil)
    }

    @Test func `an unknown command id is not found`() throws {
        let plugin = Self.make(name: "a11y", commandIDs: ["audit"])
        #expect(plugin.command(qualified: "a11y:nope") == nil)
    }

    // MARK: - the collection

    @Test func `the collection finds a plugin by name`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Self.make(name: "a11y", commandIDs: ["audit"]),
            Self.make(name: "expo", commandIDs: ["reload"]),
        ])
        #expect(try plugins.plugin(named: "expo")?.id == "expo")
    }

    @Test func `the collection returns nil for a plugin that isn't installed`() throws {
        let plugins = MockPlugins()
        given(plugins).all().willReturn([])
        #expect(try plugins.plugin(named: "ghost") == nil)
    }

    @Test func `the collection projects installed plugins as JSON`() throws {
        // Shape consumed by `GET /plugins.json`. Panels carry the
        // rendering instructions; the executable behind each command
        // is deliberately absent — the browser never needs it, and
        // publishing local paths to the page is gratuitous.
        let plugins = MockPlugins()
        given(plugins).all().willReturn([Self.make(name: "a11y", commandIDs: ["audit"])])

        let json = try plugins.listJSON
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let list = try #require(parsed?["plugins"] as? [[String: Any]])

        #expect(list.count == 1)
        #expect(list[0]["name"] as? String == "a11y")
        #expect(list[0]["version"] as? String == "1.0.0")
        let commands = try #require(list[0]["commands"] as? [[String: Any]])
        #expect(commands[0]["id"] as? String == "a11y:audit")
        #expect(commands[0]["title"] as? String == "Run audit")
        #expect(commands[0]["run"] == nil)
    }

    // MARK: - helpers

    static func make(name: String, commandIDs: [String]) -> Plugin {
        Plugin(
            root: URL(fileURLWithPath: "/tmp/plugins/\(name)"),
            manifest: PluginManifest(
                name: name,
                version: "1.0.0",
                apiVersion: 1,
                commands: commandIDs.map {
                    PluginCommand(id: $0, title: "Run audit", run: ["node", "bin/\($0).js"])
                }
            )
        )
    }
}
