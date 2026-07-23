import Foundation
import Mockable

/// The ability to fetch a bakery's files onto disk — the boundary
/// between "decide what to install" (pure Domain) and "actually talk to
/// git" (Infrastructure).
///
/// Conversational I/O with an external tool (clone, resolve HEAD,
/// later pull), so it's a `@Mockable` collaborator per the codebase's
/// adapter-splitting rule: the orchestrator (`BakeryInstall`) depends
/// on `any Checkout`, tests inject a fake pointing at a pre-populated
/// temp dir, and the concrete `GitCheckout` stays integration-only.
@Mockable
protocol Checkout: Sendable {
    /// Shallow-clone `ref` into `directory`, returning the directory
    /// and the commit that was pinned.
    func clone(_ ref: BakeryRef, into directory: URL) async throws -> CheckoutResult

    /// Re-pull an existing clone in place, returning the new commit.
    func pull(at directory: URL) async throws -> String
}

/// Where a bakery's files landed, and at what commit.
struct CheckoutResult: Equatable, Sendable {
    let directory: URL
    let commit: String
}
