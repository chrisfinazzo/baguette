import Foundation

/// `StatusBar` backed by `xcrun simctl status_bar <udid> override | clear`.
///
/// The orchestration here is pure: argv assembly (delegated to
/// `StatusBarOverride.overrideArguments`) + the `Subprocess` exit
/// handshake. The `Foundation.Process` plumbing lives in
/// `HostSubprocess` (already vendored for `LogStream`), so this file is
/// unit-covered end-to-end via `MockSubprocess` — only the real spawn
/// is integration-only.
final class SimctlStatusBar: StatusBar, @unchecked Sendable {
    private let udid: String
    private let subprocess: any Subprocess
    private let xcrun: URL

    init(
        udid: String,
        subprocess: any Subprocess = HostSubprocess(),
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.udid = udid
        self.subprocess = subprocess
        self.xcrun = xcrun
    }

    func override(_ override: StatusBarOverride) async throws {
        guard !override.isEmpty else { throw StatusBarError.emptyOverride }
        try await spawn(["simctl", "status_bar", udid, "override"] + override.overrideArguments)
    }

    func clear() async throws {
        try await spawn(["simctl", "status_bar", udid, "clear"])
    }

    private func spawn(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try subprocess.run(
                    executable: xcrun,
                    arguments: arguments,
                    onBytes: { _ in },
                    onExit: { code in
                        if code == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: StatusBarError.simctlFailed(status: code))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
