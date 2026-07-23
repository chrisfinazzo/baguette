import Testing
import Foundation
@testable import Baguette

/// Round-trip coverage for the `~/.baguette` registry. Roots are
/// injectable so the suite writes into a throwaway temp home, mirroring
/// `FileSystemChromeStore` / `FileSystemPlugins`.
@Suite("FileSystemBakeries")
struct FileSystemBakeriesTests {

    // MARK: - trusted sources

    @Test func `a recorded bakery survives a reload`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "abc123"))

        let reread = FileSystemBakeries(home: home.url)
        let all = try reread.bakeries()
        #expect(all.map(\.id) == ["github.com/acme/tools"])
        #expect(all.first?.commit == "abc123")
    }

    @Test func `recording the same bakery again updates it in place`() throws {
        // Re-adding after an update re-pins the commit rather than
        // stacking a duplicate.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "old"))
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "new"))

        let all = try registry.bakeries()
        #expect(all.count == 1)
        #expect(all.first?.commit == "new")
    }

    @Test func `forgetting a bakery leaves the others`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "a"))
        try registry.record(Self.bakery(id: "github.com/other/pack", commit: "b"))

        try registry.forget(bakeryID: "github.com/acme/tools")
        #expect(try registry.bakeries().map(\.id) == ["github.com/other/pack"])
    }

    @Test func `an absent registry reads as empty, not an error`() throws {
        // A fresh install has no bakeries.json. That's the normal
        // first-run state, not a failure.
        let home = try TempHome()
        #expect(try FileSystemBakeries(home: home.url).bakeries().isEmpty)
    }

    // MARK: - installed-plugin provenance

    @Test func `an installed plugin remembers its source and commit`() throws {
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.recordInstalled(
            InstalledPlugin(name: "a11y", bakery: "github.com/acme/tools", commit: "abc123")
        )

        let reread = try FileSystemBakeries(home: home.url).installed()
        #expect(reread.first?.name == "a11y")
        #expect(reread.first?.bakery == "github.com/acme/tools")
        #expect(reread.first?.commit == "abc123")
    }

    @Test func `provenance and the sources list are independent files`() throws {
        // Removing a plugin shouldn't forget the bakery it came from,
        // and vice versa — they answer different questions.
        let home = try TempHome()
        let registry = FileSystemBakeries(home: home.url)
        try registry.record(Self.bakery(id: "github.com/acme/tools", commit: "a"))
        try registry.recordInstalled(
            InstalledPlugin(name: "a11y", bakery: "github.com/acme/tools", commit: "a")
        )

        try registry.forgetInstalled(name: "a11y")
        #expect(try registry.installed().isEmpty)
        #expect(try registry.bakeries().count == 1)
    }

    // MARK: - helpers

    static func bakery(id: String, commit: String) -> Bakery {
        Bakery(
            id: id, url: "https://\(id).git", commit: commit,
            plugins: ["a11y"], addedAt: "2026-07-23T00:00:00Z"
        )
    }

    final class TempHome {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("baguette-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }
}
