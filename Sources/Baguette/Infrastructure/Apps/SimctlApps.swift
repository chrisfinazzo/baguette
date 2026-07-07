import Foundation

/// `Apps` backed by `xcrun simctl install <udid> <path>` — plus, for a
/// zipped app, a `ditto -x -k` extraction in front of it.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `AppBundle.installArguments` / `AppArchive.extractArguments`), the
/// `Subprocess` exit handshake, and the pure
/// `AppArchive.installableApp` locator over the extracted entries. The
/// `Foundation.Process` plumbing lives in `HostSubprocess` (already
/// vendored for `LogStream`), so this file is unit-covered end-to-end
/// via `MockSubprocess` — only the real spawns are integration-only.
final class SimctlApps: Apps, @unchecked Sendable {
    private let udid: String
    private let subprocess: any Subprocess
    private let xcrun: URL
    private let ditto: URL

    init(
        udid: String,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        ditto: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) {
        self.udid = udid
        self.subprocess = subprocess
        self.xcrun = xcrun
        self.ditto = ditto
    }

    func install(_ app: AppBundle) async throws {
        let status = try await exitStatus(of: xcrun, arguments: app.installArguments(udid: udid))
        guard status == 0 else { throw AppsError.installFailed(status: status) }
    }

    func install(archive: AppArchive) async throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let status = try await exitStatus(of: ditto, arguments: archive.extractArguments(to: dest))
        guard status == 0 else { throw AppsError.extractFailed(status: status) }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        guard let appName = AppArchive.installableApp(amongExtracted: entries) else {
            throw AppsError.noAppInArchive
        }
        try await install(AppBundle(path: dest.appendingPathComponent(appName)))
    }

    /// Run a one-shot child to completion and hand back its exit
    /// status. Output is discarded — both verbs speak through their
    /// exit code alone.
    private func exitStatus(of executable: URL, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            do {
                try subprocess.run(
                    executable: executable,
                    arguments: arguments,
                    onBytes: { _ in },
                    onExit: { continuation.resume(returning: $0) }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
