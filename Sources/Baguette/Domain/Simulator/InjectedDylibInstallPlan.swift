import Foundation
import CryptoKit

/// A dylib baguette ships for injection into simulator apps.
///
/// Two today — the virtual camera and virtual motion — sharing one install
/// layout, one arming mechanism (`InjectedDylibs`) and one
/// `DYLD_INSERT_LIBRARIES`.
struct InjectedDylib: Equatable, Sendable {
    /// Base name; the file on disk is `<name>.dylib`.
    let name: String
    /// Env var that points at a hand-built copy, for iterating on the dylib
    /// without rebuilding baguette.
    let environmentOverride: String

    var fileName: String { "\(name).dylib" }

    static let camera = InjectedDylib(
        name: "VirtualCamera", environmentOverride: "BAGUETTE_VIRTUALCAMERA_DYLIB")
    static let motion = InjectedDylib(
        name: "VirtualMotion", environmentOverride: "BAGUETTE_VIRTUALMOTION_DYLIB")
}

/// Pure factory: turns a (dylib-bytes, support-dir, dylib) triple into the
/// install layout. Per-hash subdirs dodge the iOS Simulator's dyld
/// page-hash cache rejecting replaced dylibs at the same path with
/// `code:codesigning(3) invalid-page(2)` — every release ships a
/// different sha12, gets a different install path.
///
/// Dylibs from the same build share a directory and differ only by file
/// name, so both can be armed at once.
struct InjectedDylibInstallPlan: Equatable {
    let sha12: String
    let buildDir: String
    let destPath: String

    static func compute(bytes: Data, supportDir: String,
                        dylib: InjectedDylib) -> InjectedDylibInstallPlan {
        let sha = String(sha256Hex(bytes).prefix(12))
        let buildDir = (supportDir as NSString).appendingPathComponent("builds/\(sha)")
        let destPath = (buildDir as NSString).appendingPathComponent(dylib.fileName)
        return InjectedDylibInstallPlan(sha12: sha, buildDir: buildDir, destPath: destPath)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
