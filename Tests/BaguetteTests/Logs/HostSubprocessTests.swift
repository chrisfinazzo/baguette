import Testing
import Foundation
@testable import Baguette

/// `HostSubprocess` is the one file in the spawn path that talks to the
/// real OS, so everything else is unit-tested against `MockSubprocess`
/// and this is normally left to a manual smoke test.
///
/// It earns real coverage anyway, because two of its behaviours are load
/// bearing and invisible from the mock: the **stdin** path carries a
/// plugin command's arguments, and the **environment** it hands the
/// child is what a plugin reads `BAGUETTE_URL` / `BAGUETTE_TOKEN` from.
/// Both are exercised here with tiny, deterministic system binaries —
/// no simulator, no network, milliseconds each.
@Suite("HostSubprocess")
struct HostSubprocessTests {

    @Test func `stdout reaches the byte handler and the exit code is reported`() async throws {
        let run = try await Self.spawn(
            executable: "/bin/echo", arguments: ["hello from the child"]
        )
        #expect(run.status == 0)
        #expect(run.output.contains("hello from the child"))
    }

    @Test func `a non-zero exit is reported as its own status`() async throws {
        // Every caller's failure branch keys off this — `SimctlInterface`
        // and `SimctlStatusBar` both turn it into a typed error.
        let run = try await Self.spawn(executable: "/bin/sh", arguments: ["-c", "exit 7"])
        #expect(run.status == 7)
    }

    @Test func `stderr is folded into the same stream as stdout`() async throws {
        // Both pipes share one handle, so a tool that diagnoses on
        // stderr still reaches the caller rather than vanishing.
        let run = try await Self.spawn(
            executable: "/bin/sh", arguments: ["-c", "echo to-stderr 1>&2"]
        )
        #expect(run.output.contains("to-stderr"))
    }

    // MARK: - stdin

    @Test func `a stdin payload is delivered to the child`() async throws {
        // This is the channel a plugin command reads its context and
        // `args` from — the path where a dropped payload looks like a
        // click that did nothing.
        let payload = #"{"command":"a11y:display","args":{"appearance":"dark"}}"#
        let run = try await Self.spawn(
            executable: "/bin/cat", arguments: [], stdin: Data(payload.utf8)
        )
        #expect(run.status == 0)
        #expect(run.output == payload)
    }

    @Test func `a stdin payload past the pipe buffer doesn't deadlock`() async throws {
        // Written off the calling thread on purpose: anything past the
        // ~64 KB pipe buffer would otherwise block the spawn until the
        // child drained it, and the child can't run until the spawn
        // returns.
        let payload = String(repeating: "x", count: 256 * 1024)
        let run = try await Self.spawn(
            executable: "/bin/cat", arguments: [], stdin: Data(payload.utf8)
        )
        #expect(run.status == 0)
        #expect(run.output.count == payload.count)
    }

    @Test func `closing stdin delivers EOF so the child can finish`() async throws {
        // `wc -c` only answers once the stream ends. If the handle were
        // left open the child would hang and the test would time out.
        let run = try await Self.spawn(
            executable: "/usr/bin/wc", arguments: ["-c"], stdin: Data("12345".utf8)
        )
        #expect(run.status == 0)
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines) == "5")
    }

    // MARK: - working directory and environment

    @Test func `the child runs in the working directory it was given`() async throws {
        // A plugin's command is spawned with its own directory as cwd,
        // which is what makes a relative `["python3", "bin/x.py"]` work.
        let tmp = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let run = try await Self.spawn(
            executable: "/bin/pwd", arguments: [],
            stdin: Data(), workingDirectory: tmp, environment: [:]
        )
        // /var vs /private/var — compare the resolved paths.
        #expect(run.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(
            tmp.lastPathComponent
        ))
    }

    @Test func `a supplied environment replaces the parent's rather than merging`() async throws {
        // The documented contract, and the reason a plugin sees exactly
        // the three BAGUETTE_ vars it was handed. A merge would leak the
        // server's whole environment into third-party code.
        setenv("BAGUETTE_TEST_LEAK", "should-not-appear", 1)
        defer { unsetenv("BAGUETTE_TEST_LEAK") }

        let run = try await Self.spawn(
            executable: "/usr/bin/env", arguments: [],
            stdin: Data(),
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["BAGUETTE_TOKEN": "abc123"]
        )
        #expect(run.output.contains("BAGUETTE_TOKEN=abc123"))
        #expect(!run.output.contains("BAGUETTE_TEST_LEAK"))
    }

    // MARK: - termination

    @Test func `terminate stops a child that would otherwise outlive us`() async throws {
        // The timeout path: `PluginDispatch` terminates a command that
        // overran, and `SimDeviceLogStream` terminates on teardown.
        let subprocess = HostSubprocess()
        let finished = Finished()

        try subprocess.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            onBytes: { _ in },
            onExit: { status in finished.complete(status) }
        )
        subprocess.terminate()

        let status = try await finished.value(timeout: .seconds(10))
        // Signalled, not a clean exit.
        #expect(status != 0)
    }

    @Test func `terminating an already-finished child is harmless`() async throws {
        let run = try await Self.spawn(executable: "/usr/bin/true", arguments: [])
        #expect(run.status == 0)
        // The subprocess has already exited; this must not trap.
        run.subprocess.terminate()
    }

    @Test func `a missing executable throws instead of reporting a fake exit`() async throws {
        let subprocess = HostSubprocess()
        #expect(throws: (any Error).self) {
            try subprocess.run(
                executable: URL(fileURLWithPath: "/definitely/not/a/binary"),
                arguments: [],
                onBytes: { _ in },
                onExit: { _ in }
            )
        }
    }

    // MARK: - helpers

    struct Run {
        let status: Int32
        let output: String
        let subprocess: HostSubprocess
    }

    /// One-shot await over the callback API. Everything the child writes
    /// is accumulated; the continuation resumes on exit.
    static func spawn(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> Run {
        let subprocess = HostSubprocess()
        let collected = Collected()
        let finished = Finished()
        let url = URL(fileURLWithPath: executable)

        if let workingDirectory, let environment {
            try subprocess.run(
                executable: url, arguments: arguments,
                workingDirectory: workingDirectory, environment: environment,
                stdin: stdin ?? Data(),
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        } else if let stdin {
            try subprocess.run(
                executable: url, arguments: arguments, stdin: stdin,
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        } else {
            try subprocess.run(
                executable: url, arguments: arguments,
                onBytes: { collected.append($0) },
                onExit: { finished.complete($0) }
            )
        }

        let status = try await finished.value(timeout: .seconds(15))
        // The readability handler can fire after termination; give the
        // last chunk a moment to land rather than racing it.
        try? await Task.sleep(for: .milliseconds(60))
        return Run(status: status, output: collected.string, subprocess: subprocess)
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A one-shot exit signal that can be awaited, with a timeout so a
    /// hung child fails the test instead of hanging the suite.
    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?

        func complete(_ code: Int32) {
            lock.lock(); defer { lock.unlock() }
            if status == nil { status = code }
        }

        private var current: Int32? {
            lock.lock(); defer { lock.unlock() }
            return status
        }

        func value(timeout: Duration) async throws -> Int32 {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let status = current { return status }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ChildTimedOut()
        }
    }

    struct ChildTimedOut: Error {}

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-subprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
