import Testing
import Foundation
@testable import Baguette

/// Where baguette keeps installed plugins, trusted bakeries and the
/// clone cache. One resolver so the CLI, the server and the plugin
/// scanner can't disagree about which directory they mean — a
/// disagreement would show up as "I installed it and the rail is empty".
///
/// `.serialized` because `setenv` is process-global.
@Suite("BaguetteHome", .serialized)
struct BaguetteHomeTests {

    @Test func `the override wins so tests and sandboxes never touch the real home`() {
        setenv("BAGUETTE_HOME", "/tmp/baguette-home-test", 1)
        defer { unsetenv("BAGUETTE_HOME") }

        #expect(BaguetteHome.url.path == "/tmp/baguette-home-test")
    }

    @Test func `an empty override is ignored rather than resolving to nothing`() {
        // `BAGUETTE_HOME=` in a shell profile shouldn't silently point
        // the whole install at the filesystem root.
        setenv("BAGUETTE_HOME", "", 1)
        defer { unsetenv("BAGUETTE_HOME") }

        #expect(BaguetteHome.url.path == NSHomeDirectory() + "/.baguette")
    }

    @Test func `the default is a dotfile directory in the user's home`() {
        unsetenv("BAGUETTE_HOME")
        #expect(BaguetteHome.url.path == NSHomeDirectory() + "/.baguette")
    }

    @Test func `installed plugins live under the home, wherever it points`() {
        // The scanner root and the install target are the same path by
        // construction, not by two places agreeing on a string.
        setenv("BAGUETTE_HOME", "/tmp/baguette-home-test", 1)
        defer { unsetenv("BAGUETTE_HOME") }

        #expect(BaguetteHome.pluginsRoot.path == "/tmp/baguette-home-test/plugins")
        #expect(BaguetteHome.pluginsRoot.deletingLastPathComponent().path == BaguetteHome.url.path)
    }
}
