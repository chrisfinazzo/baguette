import Foundation

/// Runs one contributed plugin command and turns what the child said
/// into an outcome the CLI and the serve route can both project.
/// Sits alongside `GestureDispatcher` / `CopyDispatch` / `PasteDispatch`
/// as the App-layer orchestration for one entry point.
///
/// The whole execution model in one place: a command is an argv the
/// manifest declared, spawned **only** when the user activates it,
/// inside the plugin's own directory, with a fresh environment
/// carrying the invocation context. It answers with one JSON object on
/// stdout. Nothing about a plugin runs at scan time, and nothing a
/// plugin ships is ever loaded into baguette's own process or page.
enum PluginDispatch {

    /// What the plugin needs to know to talk back to the server it was
    /// launched from.
    struct Context: Equatable, Sendable {
        /// Origin of the already-warm server. Plugins call this rather
        /// than re-spawning the `baguette` binary, which costs ~1.2s in
        /// framework resolution alone.
        let serverURL: String
        /// The focused device, when there is one. Farm-level and
        /// device-independent commands run without.
        let udid: String?
        /// Per-session token the plugin-API routes check.
        let token: String

        init(serverURL: String, udid: String?, token: String) {
            self.serverURL = serverURL
            self.udid = udid
            self.token = token
        }
    }

    enum Outcome: Equatable {
        /// The plugin answered in the agreed shape. Note this covers
        /// `ok: false` too — a plugin reporting honestly that its job
        /// failed held up its end of the contract, and the user should
        /// see the plugin's own message rather than one we invented.
        case ok(PluginResult)
        /// No installed plugin contributes this namespaced id.
        case unknownCommand(id: String)
        /// The child never started (missing interpreter, bad perms).
        case spawnFailed(String)
        /// The child ran and failed. `output` is whatever it printed —
        /// stdout and stderr are pooled, so this is usually the stack
        /// trace the author needs.
        case exited(status: Int32, output: String)
        /// The child exited cleanly but didn't answer in the agreed
        /// shape. Deliberately not folded into an empty result: a
        /// panel rendering nothing reads as "all clear".
        case malformedAnswer(String)

        /// One `{"ok":…}` line, matching the `GestureDispatcher` ack
        /// contract used by `baguette input` and the CLI.
        var ackJSON: String {
            switch self {
            case .ok(let result) where result.ok:
                return #"{"ok":true}"#
            case .ok(let result):
                let message = result.message ?? "plugin reported failure"
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(message))\"}"
            default:
                return "{\"ok\":false,\"error\":\"\(GestureDispatcher.jsonEscape(errorText ?? ""))\"}"
            }
        }

        /// Human-readable failure, or nil when the plugin answered.
        var errorText: String? {
            switch self {
            case .ok: return nil
            case .unknownCommand(let id): return "no installed plugin contributes \"\(id)\""
            case .spawnFailed(let reason): return "plugin failed to start: \(reason)"
            case .exited(let status, let output):
                let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return tail.isEmpty
                    ? "plugin exited \(status)"
                    : "plugin exited \(status): \(tail)"
            case .malformedAnswer(let reason): return "plugin answered badly: \(reason)"
            }
        }
    }

    /// How long a command may run before it's terminated. A plugin
    /// button that never returns is indistinguishable from a hung UI,
    /// so the host bounds it rather than trusting authors to.
    static let timeout: Duration = .seconds(10)

    /// Resolve `qualifiedCommand` (`a11y:audit`) against the installed
    /// plugins and run it.
    ///
    /// When `grants` is supplied, the invocation gets its own token
    /// carrying exactly the plugin's declared capabilities, revoked the
    /// moment the command finishes. That token — not a shared session
    /// secret — is what the plugin API checks, so a plugin can only do
    /// what its manifest asked for.
    static func run(
        qualifiedCommand: String,
        context: Context,
        plugins: any Plugins,
        grants: PluginGrants? = nil,
        subprocess: @Sendable () -> any Subprocess = { HostSubprocess() }
    ) async -> Outcome {
        guard let (plugin, command) = (try? plugins.resolve(qualifiedCommand: qualifiedCommand)) ?? nil
        else {
            return .unknownCommand(id: qualifiedCommand)
        }

        // Least privilege, scoped to this one run: the child gets a
        // token carrying exactly what the manifest declared, revoked
        // the moment the command returns.
        let issuedToken = grants?.issue(
            plugin: plugin.id, capabilities: plugin.manifest.capabilities
        )
        let runContext = issuedToken.map {
            Context(serverURL: context.serverURL, udid: context.udid, token: $0)
        } ?? context
        defer { if let issuedToken { grants?.revoke(issuedToken) } }

        let child = subprocess()
        let collected = Collected()

        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        do {
                            try child.run(
                                executable: Self.env,
                                // The argv goes to `/usr/bin/env`, which does the
                                // PATH lookup — a plugin says ["node", …] without
                                // needing to know where the user's node lives.
                                arguments: command.run,
                                workingDirectory: plugin.root,
                                environment: environment(for: runContext),
                                stdin: contextJSON(qualifiedCommand, runContext),
                                onBytes: { collected.append($0) },
                                onExit: { status in
                                    continuation.resume(returning: finish(status: status, collected: collected))
                                }
                            )
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    child.terminate()
                    return .exited(status: -1, output: "timed out after \(timeout)")
                }

                // Whichever finishes first wins; the loser is cancelled.
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            return .spawnFailed("\(error)")
        }
    }

    // MARK: - private

    private static let env = URL(fileURLWithPath: "/usr/bin/env")

    /// Accumulates stdout across however many chunks the pipe decides
    /// to deliver. A JSON object split across two reads is not a
    /// malformed answer.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(bytes)
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    private static func finish(status: Int32, collected: Collected) -> Outcome {
        let output = collected.value
        guard status == 0 else {
            return .exited(
                status: status,
                output: String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        do {
            return .ok(try PluginResult.parsing(json: output))
        } catch {
            return .malformedAnswer("\(error)")
        }
    }

    /// The child's complete environment. `PATH` is forwarded so
    /// `/usr/bin/env` can find the interpreter; nothing else of the
    /// host's is passed through, so what a plugin inherits stays an
    /// explicit decision rather than an accident.
    private static func environment(for context: Context) -> [String: String] {
        var env: [String: String] = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "BAGUETTE_URL": context.serverURL,
            "BAGUETTE_TOKEN": context.token,
        ]
        // Absent rather than empty when nothing is focused — an empty
        // string would read as a real udid to a naive plugin.
        if let udid = context.udid { env["BAGUETTE_UDID"] = udid }
        return env
    }

    /// Same context as the environment, in structured form, for
    /// plugins that would rather read stdin than `process.env`.
    private static func contextJSON(_ qualifiedCommand: String, _ context: Context) -> Data {
        var dict: [String: Any] = [
            "command": qualifiedCommand,
            "url": context.serverURL,
            "token": context.token,
        ]
        if let udid = context.udid { dict["udid"] = udid }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }
}
