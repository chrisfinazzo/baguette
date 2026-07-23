import Foundation

/// The `~/.baguette` registry — the trusted-bakeries list
/// (`bakeries.json`) and the installed-plugin provenance
/// (`installed.json`). Two files, one type, because they're written
/// and read together during install / remove.
///
/// `home` is injectable so the suite writes into a throwaway temp
/// directory, exactly as `FileSystemChromeStore` and `FileSystemPlugins`
/// take their roots. A missing file reads as empty — a fresh install
/// has neither, and that's the normal first-run state, not an error.
struct FileSystemBakeries {
    let home: URL

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".baguette")) {
        self.home = home
    }

    private var bakeriesFile: URL { home.appendingPathComponent("bakeries.json") }
    private var installedFile: URL { home.appendingPathComponent("installed.json") }

    // MARK: - trusted sources

    func bakeries() throws -> [Bakery] {
        try load([Bakery].self, from: bakeriesFile)
    }

    /// Add or re-pin a bakery. Re-recording the same `id` updates it in
    /// place rather than stacking a duplicate, so an `update` re-pins
    /// cleanly.
    func record(_ bakery: Bakery) throws {
        var all = try bakeries().filter { $0.id != bakery.id }
        all.append(bakery)
        try save(all.sorted { $0.id < $1.id }, to: bakeriesFile)
    }

    func forget(bakeryID: String) throws {
        try save(try bakeries().filter { $0.id != bakeryID }, to: bakeriesFile)
    }

    // MARK: - installed-plugin provenance

    func installed() throws -> [InstalledPlugin] {
        try load([InstalledPlugin].self, from: installedFile)
    }

    func recordInstalled(_ plugin: InstalledPlugin) throws {
        var all = try installed().filter { $0.name != plugin.name }
        all.append(plugin)
        try save(all.sorted { $0.name < $1.name }, to: installedFile)
    }

    func forgetInstalled(name: String) throws {
        try save(try installed().filter { $0.name != name }, to: installedFile)
    }

    // MARK: - private

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T where T: RangeReplaceableCollection {
        guard let data = try? Data(contentsOf: url) else { return T() }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
