import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `PluginDispatch` — argv assembly, the
/// pinned working directory, the injected environment, and the
/// stdout handshake. The irreducible spawn lives in `HostSubprocess`
/// (integration-only), so every branch here runs through
/// `MockSubprocess`.
@Suite("PluginDispatch")
struct PluginDispatchTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var workingDirectory: URL?
        var environment: [String: String]?
        var stdin: Data?
    }

    // MARK: - how the child is spawned

    @Test func `spawns the command's argv through env so PATH is honoured`() async throws {
        // `run` is an argv, not an absolute path — a plugin says
        // ["node", "bin/audit.js"] and shouldn't have to know where
        // the user's node lives. `/usr/bin/env` does the lookup.
        let (outcome, captures) = await Self.run()
        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/env"))
        #expect(captures.arguments == ["node", "bin/audit.js"])
        _ = outcome
    }

    @Test func `pins the working directory to the plugin's own root`() async throws {
        // Relative paths in `run` resolve against the plugin's files,
        // not against wherever `baguette serve` happened to launch.
        let (_, captures) = await Self.run()
        #expect(captures.workingDirectory?.lastPathComponent == "a11y")
    }

    @Test func `injects the server url, device and token into the environment`() async throws {
        // A plugin talks to the already-warm server rather than
        // re-spawning the ~1.2s baguette binary, so it needs the URL;
        // the token is what the plugin-API routes check.
        let (_, captures) = await Self.run()
        #expect(captures.environment?["BAGUETTE_URL"] == "http://127.0.0.1:8421")
        #expect(captures.environment?["BAGUETTE_UDID"] == "UDID-1")
        #expect(captures.environment?["BAGUETTE_TOKEN"] == "tok-abc")
    }

    @Test func `omits the device from the environment when no simulator is focused`() async throws {
        // Farm-level and device-independent commands run without one.
        // Absent is honest; empty-string would read as a real udid.
        let (_, captures) = await Self.run(udid: nil)
        #expect(captures.environment?["BAGUETTE_UDID"] == nil)
    }

    @Test func `writes the invocation context to the child's stdin`() async throws {
        let (_, captures) = await Self.run()
        let context = try JSONSerialization.jsonObject(
            with: try #require(captures.stdin)
        ) as? [String: Any]
        #expect(context?["command"] as? String == "a11y:audit")
        #expect(context?["udid"] as? String == "UDID-1")
        #expect(context?["url"] as? String == "http://127.0.0.1:8421")
    }

    // MARK: - what comes back

    @Test func `a clean exit returns the rows the plugin printed`() async throws {
        let (outcome, _) = await Self.run(
            stdout: #"{"ok":true,"rows":[{"title":"Button has no label","severity":"error"}]}"#
        )
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(result.rows.map(\.title) == ["Button has no label"])
        #expect(result.rows.first?.severity == .error)
    }

    @Test func `a plugin reporting its own failure is still a well-formed answer`() async throws {
        // The process did its job and answered honestly. That is not
        // baguette failing to run it, and the user should see the
        // plugin's own words.
        let (outcome, _) = await Self.run(stdout: #"{"ok":false,"message":"Metro is not running"}"#)
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(!result.ok)
        #expect(result.message == "Metro is not running")
    }

    @Test func `stdout arriving in several chunks is reassembled before parsing`() async throws {
        // Pipes split wherever they like; a JSON object cut in half is
        // not a malformed answer.
        let (outcome, _) = await Self.run(stdoutChunks: [#"{"ok":true,"ro"#, #"ws":[{"title":"x"}]}"#])
        guard case .ok(let result) = outcome else {
            Issue.record("expected .ok, got \(outcome)"); return
        }
        #expect(result.rows.map(\.title) == ["x"])
    }

    // MARK: - failure paths

    @Test func `an unknown qualified command is reported without spawning anything`() async throws {
        let (outcome, captures) = await Self.run(command: "a11y:nope")
        #expect(outcome == .unknownCommand(id: "a11y:nope"))
        #expect(captures.executable == nil)
    }

    @Test func `a non-zero exit surfaces the status and whatever the child said`() async throws {
        let (outcome, _) = await Self.run(
            stdout: "Error: Cannot find module 'bin/audit.js'", exitCode: 1
        )
        #expect(outcome == .exited(status: 1, output: "Error: Cannot find module 'bin/audit.js'"))
    }

    @Test func `output that isn't JSON is refused rather than shown as an empty result`() async throws {
        // An audit panel rendering nothing reads as "no problems
        // found", which is the worst available lie.
        let (outcome, _) = await Self.run(stdout: "Debugger attached.")
        #expect(outcome == .malformedAnswer(PluginResultError.malformedJSON.description))
    }

    @Test func `a spawn that throws is reported, not crashed`() async throws {
        let (outcome, _) = await Self.run(spawnThrows: true)
        guard case .spawnFailed = outcome else {
            Issue.record("expected .spawnFailed, got \(outcome)"); return
        }
    }

    // MARK: - helpers

    struct SpawnRefused: Error {}

    static func run(
        command: String = "a11y:audit",
        udid: String? = "UDID-1",
        stdout: String = #"{"ok":true}"#,
        stdoutChunks: [String]? = nil,
        exitCode: Int32 = 0,
        spawnThrows: Bool = false
    ) async -> (PluginDispatch.Outcome, Captures) {
        let captures = Captures()
        let sub = MockSubprocess()

        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, cwd, env, stdin, onBytes, onExit in
            if spawnThrows { throw SpawnRefused() }
            captures.executable = exe
            captures.arguments = args
            captures.workingDirectory = cwd
            captures.environment = env
            captures.stdin = stdin
            for chunk in stdoutChunks ?? [stdout] { onBytes(Data(chunk.utf8)) }
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()

        let plugins = MockPlugins()
        given(plugins).all().willReturn([
            Plugin(
                root: URL(fileURLWithPath: "/tmp/plugins/a11y"),
                manifest: PluginManifest(
                    name: "a11y", version: "1.0.0", apiVersion: 1,
                    commands: [
                        PluginCommand(id: "audit", title: "Run audit", run: ["node", "bin/audit.js"])
                    ]
                )
            )
        ])

        let outcome = await PluginDispatch.run(
            qualifiedCommand: command,
            context: PluginDispatch.Context(
                serverURL: "http://127.0.0.1:8421", udid: udid, token: "tok-abc"
            ),
            plugins: plugins,
            subprocess: { sub }
        )
        return (outcome, captures)
    }
}
