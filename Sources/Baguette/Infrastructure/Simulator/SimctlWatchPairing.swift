import Foundation

/// `WatchPairing` backed by `xcrun simctl list pairs -j`.
///
/// The pairing table is host-wide and cheap to read, so there is no
/// caching here — the rail asks once per page load, and a pair created
/// while the tab is open should show up on the next ask rather than
/// after a restart. Everything except the spawn is
/// `SimctlPairs.watch(pairedWith:in:)`, which is unit-covered; a spawn
/// that fails yields no watch, same as a phone that has none.
final class SimctlWatchPairing: WatchPairing, @unchecked Sendable {
    private let udid: String
    private let listPairs: () throws -> String

    init(udid: String, listPairs: @escaping () throws -> String) {
        self.udid = udid
        self.listPairs = listPairs
    }

    convenience init(udid: String) {
        self.init(udid: udid, listPairs: { try SimctlPairsCapture.list() })
    }

    var watch: PairedWatch? {
        guard let json = try? listPairs() else { return nil }
        return SimctlPairs.watch(pairedWith: udid, in: json)
    }
}

/// Synchronous `xcrun simctl list pairs -j` capture.
enum SimctlPairsCapture {
    static func list(
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> String {
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["simctl", "list", "pairs", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
