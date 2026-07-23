import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `GitCheckout` — argv assembly, the
/// non-interactive / no-submodule safety flags, and the
/// clone-then-rev-parse handshake. The real `git` spawn lives in
/// `HostSubprocess` (integration-only); every branch here runs through
/// `MockSubprocess`, mirroring `SimctlLocationTests`.
@Suite("GitCheckout")
struct GitCheckoutTests {

    final class Captures: @unchecked Sendable {
        var calls: [[String]] = []          // arguments of each spawn, in order
        var environments: [[String: String]?] = []
    }

    /// A mock that answers each spawn: clone exits 0, `rev-parse`
    /// prints the commit. Matched by whether the argv contains
    /// "rev-parse".
    private func makeCheckout(commit: String = "abc123", cloneExit: Int32 = 0) -> (GitCheckout, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, workingDirectory: .any,
            environment: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, _, env, _, onBytes, onExit in
            captures.calls.append(args)
            captures.environments.append(env)
            if args.contains("rev-parse") {
                onBytes(Data("\(commit)\n".utf8))
                onExit(0)
            } else {
                onExit(cloneExit)
            }
        }
        given(sub).terminate().willReturn()
        return (GitCheckout(subprocess: { sub }), captures)
    }

    @Test func `clone shallow-fetches the url with no submodules`() async throws {
        let (git, captures) = makeCheckout()
        let ref = try BakeryRef.parse("acme/tools")
        let dest = URL(fileURLWithPath: "/tmp/cache/github.com/acme/tools")
        _ = try await git.clone(ref, into: dest)

        let clone = try #require(captures.calls.first)
        #expect(clone.contains("clone"))
        #expect(clone.contains("--depth"))
        #expect(clone.contains("1"))
        #expect(clone.contains(ref.cloneURL))
        #expect(clone.contains(dest.path))
        // No submodule recursion — a bakery must not drag in arbitrary
        // submodule URLs.
        #expect(!clone.contains("--recurse-submodules"))
    }

    @Test func `clone runs git non-interactively so a bad url fails fast`() async throws {
        // GIT_TERMINAL_PROMPT=0 turns a private/missing repo into an
        // immediate failure instead of a hang on a credential prompt.
        let (git, captures) = makeCheckout()
        _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: URL(fileURLWithPath: "/tmp/x"))
        #expect(captures.environments.first??["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func `clone reports the pinned commit via rev-parse`() async throws {
        let (git, captures) = makeCheckout(commit: "deadbeef")
        let result = try await git.clone(try BakeryRef.parse("acme/tools"), into: URL(fileURLWithPath: "/tmp/x"))
        #expect(result.commit == "deadbeef")
        // Second call resolves HEAD in the freshly cloned dir.
        #expect(captures.calls.last?.contains("rev-parse") == true)
    }

    @Test func `a failed clone throws rather than reporting a bogus commit`() async throws {
        let (git, _) = makeCheckout(cloneExit: 128)
        await #expect(throws: (any Error).self) {
            _ = try await git.clone(try BakeryRef.parse("acme/tools"), into: URL(fileURLWithPath: "/tmp/x"))
        }
    }
}
