import Testing
import Foundation
@testable import Baguette

@Suite("PluginManifest")
struct PluginManifestTests {

    // MARK: - identity

    @Test func `parsing reads the plugin name`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureOneCommand)
        #expect(manifest.name == "a11y")
    }

    @Test func `parsing reads the plugin version`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureOneCommand)
        #expect(manifest.version == "1.0.0")
    }

    @Test func `parsing reads the declared apiVersion`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureOneCommand)
        #expect(manifest.apiVersion == 1)
    }

    @Test func `parsing reads the description`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureOneCommand)
        #expect(manifest.description == "Accessibility audit for the current screen")
    }

    @Test func `description is nil when the manifest omits it`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureMinimal)
        #expect(manifest.description == nil)
    }

    // MARK: - the plugin's own icon

    @Test func `parsing reads the icon that stands for the whole plugin`() throws {
        // A plugin with several panels collapses to one rail entry, so
        // it needs a glyph of its own rather than borrowing whichever
        // panel happens to be listed first.
        let manifest = try PluginManifest.parsing(json: Self.fixtureGroupIcon)
        #expect(manifest.icon == .wrench)
    }

    @Test func `a manifest that names no icon of its own has none`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureMinimal)
        #expect(manifest.icon == nil)
    }

    @Test func `a plugin icon outside the shipped set is rejected`() throws {
        // Same boundary as a panel icon: untrusted manifest text that
        // reaches the DOM is resolved against the host's fixed set or
        // refused — never escaped downstream.
        #expect(throws: PluginManifestError.unknownIcon(name: "<img src=x onerror=alert(1)>")) {
            try PluginManifest.parsing(json: Self.fixtureBadGroupIcon)
        }
    }

    // MARK: - commands

    @Test func `parsing reads one contributed command`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureOneCommand)
        #expect(manifest.commands == [
            PluginCommand(id: "audit", title: "Run audit", run: ["node", "bin/audit.js"])
        ])
    }

    @Test func `commands are empty when the manifest contributes none`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureMinimal)
        #expect(manifest.commands.isEmpty)
    }

    @Test func `a command with an empty run argv is rejected`() throws {
        // `run` is the executable + args. An empty array would spawn
        // nothing, so the manifest is malformed rather than a plugin
        // that silently does nothing on click.
        #expect(throws: PluginManifestError.self) {
            try PluginManifest.parsing(json: Self.fixtureEmptyRun)
        }
    }

    // MARK: - capabilities

    @Test func `parsing reads the declared capabilities`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixtureCapabilities)
        #expect(manifest.capabilities == [.describeUI, .screenshot])
    }

    @Test func `a manifest declaring no capabilities gets none`() throws {
        // Least privilege by default: a plugin that says nothing can
        // call nothing on the plugin API.
        let manifest = try PluginManifest.parsing(json: Self.fixtureMinimal)
        #expect(manifest.capabilities.isEmpty)
    }

    @Test func `an unknown capability is rejected`() throws {
        // A typo would otherwise silently grant nothing and fail at
        // runtime with a confusing 403 — catch it at validate time.
        #expect(throws: PluginManifestError.unknownCapability(name: "root")) {
            try PluginManifest.parsing(json: Data("""
            { "name": "x", "version": "1.0.0", "apiVersion": 1, "capabilities": ["root"] }
            """.utf8))
        }
    }

    // MARK: - panels

    @Test func `parsing reads a panel's identity and icon`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixturePanel)
        let panel = try #require(manifest.panels.first)
        #expect(panel.id == "audit")
        #expect(panel.title == "Accessibility")
        #expect(panel.icon == .accessibility)
    }

    @Test func `parsing reads a list body bound to a contributed command`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixturePanel)
        let panel = try #require(manifest.panels.first)
        #expect(panel.body == .list(source: "audit", rowAction: .highlight))
    }

    @Test func `a panel's rowAction is nil when the manifest omits it`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixturePanelNoRowAction)
        let panel = try #require(manifest.panels.first)
        #expect(panel.body == .list(source: "audit", rowAction: nil))
    }

    @Test func `parsing reads a panel's when condition`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixturePanel)
        #expect(manifest.panels.first?.when == .simulatorBooted)
    }

    @Test func `a panel with no when condition is always shown`() throws {
        let manifest = try PluginManifest.parsing(json: Self.fixturePanelNoRowAction)
        #expect(manifest.panels.first?.when == nil)
    }

    @Test func `an icon outside the shipped set is rejected`() throws {
        // Icons are names resolved against a fixed host set, never
        // markup. A manifest is untrusted input rendered into the very
        // origin `isTrustedBrowserRequest` exists to defend, so an
        // arbitrary icon string is an XSS vector — refuse it at the
        // parse boundary rather than escaping it downstream.
        #expect(throws: PluginManifestError.unknownIcon(name: "<svg onload=alert(1)>")) {
            try PluginManifest.parsing(json: Self.fixtureBadIcon)
        }
    }

    @Test func `a body kind this build doesn't render is rejected`() throws {
        // v2's sandboxed-iframe panels will arrive as `"kind":"webview"`
        // behind an apiVersion bump. A v1 build must refuse it outright
        // rather than render an empty card.
        #expect(throws: PluginManifestError.unknownPanelBody(kind: "webview")) {
            try PluginManifest.parsing(json: Self.fixtureWebviewBody)
        }
    }

    @Test func `a list body naming an undeclared command is rejected`() throws {
        // The panel's rows come from running `source`. If no such
        // command is contributed, the panel could never populate —
        // catch the typo at validate time, not on first click.
        #expect(throws: PluginManifestError.unknownCommandSource(id: "typo")) {
            try PluginManifest.parsing(json: Self.fixtureDanglingSource)
        }
    }

    // MARK: - apiVersion gating

    @Test func `a manifest declaring a newer apiVersion is rejected`() throws {
        // Forward compatibility runs one way: an old baguette must
        // refuse a manifest written against a contract it doesn't know,
        // rather than silently dropping the contributions it can't parse.
        #expect(throws: PluginManifestError.unsupportedAPIVersion(declared: 99, supported: 1)) {
            try PluginManifest.parsing(json: Self.fixtureFutureAPI)
        }
    }

    // MARK: - malformed input

    @Test func `parsing rejects non-JSON bytes`() throws {
        #expect(throws: PluginManifestError.malformedJSON) {
            try PluginManifest.parsing(json: Data("not json".utf8))
        }
    }

    @Test func `parsing rejects a manifest with no name`() throws {
        #expect(throws: PluginManifestError.missingName) {
            try PluginManifest.parsing(json: Self.fixtureNoName)
        }
    }

    @Test func `parsing rejects a manifest with no version`() throws {
        // A public ecosystem needs every plugin to state a version —
        // install / update / "which build is this" all rest on it.
        // Defaulting silently would let unversioned plugins into a
        // marketplace that can never upgrade them.
        #expect(throws: PluginManifestError.missingVersion) {
            try PluginManifest.parsing(json: Self.fixtureNoVersion)
        }
    }

    @Test func `parsing rejects a command with no id`() throws {
        // The id is the namespace half of `plugin:command`. An empty
        // one makes `qualifiedCommandIDs` carry a bare "a11y:", which
        // no lookup can ever resolve and every listing renders blank.
        #expect(throws: PluginManifestError.missingCommandID) {
            try PluginManifest.parsing(json: Self.fixtureNamelessCommand)
        }
    }

    // MARK: - fixtures

    static let fixtureNamelessCommand = Data("""
    {
      "name": "a11y",
      "version": "1.0.0",
      "apiVersion": 1,
      "contributes": {
        "commands": [
          { "id": "", "title": "Run audit", "run": ["node", "bin/audit.js"] }
        ]
      }
    }
    """.utf8)

    static let fixtureOneCommand = Data("""
    {
      "name": "a11y",
      "version": "1.0.0",
      "apiVersion": 1,
      "description": "Accessibility audit for the current screen",
      "contributes": {
        "commands": [
          { "id": "audit", "title": "Run audit", "run": ["node", "bin/audit.js"] }
        ]
      }
    }
    """.utf8)

    static let fixtureMinimal = Data("""
    { "name": "bare", "version": "0.1.0", "apiVersion": 1 }
    """.utf8)

    static let fixtureEmptyRun = Data("""
    {
      "name": "broken", "version": "1.0.0", "apiVersion": 1,
      "contributes": { "commands": [ { "id": "x", "title": "X", "run": [] } ] }
    }
    """.utf8)

    static let fixtureFutureAPI = Data("""
    { "name": "future", "version": "1.0.0", "apiVersion": 99 }
    """.utf8)

    static let fixtureNoName = Data("""
    { "version": "1.0.0", "apiVersion": 1 }
    """.utf8)

    static let fixtureCapabilities = Data("""
    {
      "name": "a11y", "version": "1.0.0", "apiVersion": 1,
      "capabilities": ["describe-ui", "screenshot"]
    }
    """.utf8)

    static let fixtureGroupIcon = Data("""
    {
      "name": "expo", "version": "0.2.0", "apiVersion": 1,
      "icon": "wrench"
    }
    """.utf8)

    static let fixtureBadGroupIcon = Data("""
    {
      "name": "evil", "version": "1.0.0", "apiVersion": 1,
      "icon": "<img src=x onerror=alert(1)>"
    }
    """.utf8)

    static let fixtureNoVersion = Data("""
    { "name": "unversioned", "apiVersion": 1 }
    """.utf8)

    /// The reference plugin's shape: one command, one panel that
    /// renders the command's rows and highlights the node on click.
    static let fixturePanel = Data("""
    {
      "name": "a11y", "version": "1.0.0", "apiVersion": 1,
      "contributes": {
        "commands": [
          { "id": "audit", "title": "Run audit", "run": ["node", "bin/audit.js"] }
        ],
        "panels": [
          { "id": "audit", "title": "Accessibility", "icon": "accessibility",
            "when": "simulator.booted",
            "body": { "kind": "list", "source": "audit", "rowAction": "highlight" } }
        ]
      }
    }
    """.utf8)

    static let fixturePanelNoRowAction = Data("""
    {
      "name": "a11y", "version": "1.0.0", "apiVersion": 1,
      "contributes": {
        "commands": [
          { "id": "audit", "title": "Run audit", "run": ["node", "bin/audit.js"] }
        ],
        "panels": [
          { "id": "audit", "title": "Accessibility", "icon": "accessibility",
            "body": { "kind": "list", "source": "audit" } }
        ]
      }
    }
    """.utf8)

    static let fixtureBadIcon = Data("""
    {
      "name": "evil", "version": "1.0.0", "apiVersion": 1,
      "contributes": {
        "commands": [ { "id": "go", "title": "Go", "run": ["true"] } ],
        "panels": [
          { "id": "p", "title": "P", "icon": "<svg onload=alert(1)>",
            "body": { "kind": "list", "source": "go" } }
        ]
      }
    }
    """.utf8)

    static let fixtureWebviewBody = Data("""
    {
      "name": "future-ui", "version": "1.0.0", "apiVersion": 1,
      "contributes": {
        "panels": [
          { "id": "p", "title": "P", "icon": "list",
            "body": { "kind": "webview", "entry": "ui/index.html" } }
        ]
      }
    }
    """.utf8)

    static let fixtureDanglingSource = Data("""
    {
      "name": "typo", "version": "1.0.0", "apiVersion": 1,
      "contributes": {
        "commands": [ { "id": "audit", "title": "Run audit", "run": ["true"] } ],
        "panels": [
          { "id": "p", "title": "P", "icon": "list",
            "body": { "kind": "list", "source": "typo" } }
        ]
      }
    }
    """.utf8)
}
