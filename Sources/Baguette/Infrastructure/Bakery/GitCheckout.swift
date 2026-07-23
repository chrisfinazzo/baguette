import Foundation

/// `Checkout` backed by `/usr/bin/git`. The only bakery code that talks
/// to the network. Integration-only for the real spawn; the argv
/// assembly + the clone-then-rev-parse handshake are unit-covered
/// through `MockSubprocess`, exactly as `SimctlLocation` covers its
/// `xcrun` calls.
///
/// Safety flags are not optional here:
///   - `--depth 1` — a bakery is a working tree, not history.
///   - **no** `--recurse-submodules` — a malicious repo must not be
///     able to drag in arbitrary submodule URLs.
///   - `GIT_TERMINAL_PROMPT=0` — a private or missing repo fails fast
///     instead of hanging on a credential prompt.
final class GitCheckout: Checkout, @unchecked Sendable {
    private let git: URL
    private let subprocess: @Sendable () -> any Subprocess

    init(
        git: URL = URL(fileURLWithPath: "/usr/bin/git"),
        subprocess: @escaping @Sendable () -> any Subprocess = { HostSubprocess() }
    ) {
        self.git = git
        self.subprocess = subprocess
    }

    func clone(_ ref: BakeryRef, into directory: URL) async throws -> CheckoutResult {
        // Fresh clone: remove any stale cache dir so `git clone` doesn't
        // refuse a non-empty target.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await run(["clone", "--depth", "1", ref.cloneURL, directory.path])
        let commit = try await revParse(at: directory)
        return CheckoutResult(directory: directory, commit: commit)
    }

    func pull(at directory: URL) async throws -> String {
        try await run(["-C", directory.path, "pull", "--depth", "1", "--ff-only"])
        return try await revParse(at: directory)
    }

    // MARK: - private

    private func revParse(at directory: URL) async throws -> String {
        let out = try await run(["-C", directory.path, "rev-parse", "HEAD"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run one git invocation, collecting stdout, throwing on non-zero.
    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let child = subprocess()
        let collected = Collected()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try child.run(
                    executable: git,
                    arguments: arguments,
                    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    environment: environment,
                    stdin: Data(),
                    onBytes: { collected.append($0) },
                    onExit: { status in
                        if status == 0 {
                            continuation.resume(returning: collected.string)
                        } else {
                            continuation.resume(throwing: GitCheckoutError.gitFailed(
                                arguments: arguments, status: status, output: collected.string
                            ))
                        }
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes) }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

enum GitCheckoutError: Error, Equatable, CustomStringConvertible {
    case gitFailed(arguments: [String], status: Int32, output: String)

    var description: String {
        switch self {
        case .gitFailed(let arguments, let status, let output):
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = "git " + arguments.joined(separator: " ")
            return tail.isEmpty ? "\(cmd) exited \(status)" : "\(cmd) exited \(status): \(tail)"
        }
    }
}
