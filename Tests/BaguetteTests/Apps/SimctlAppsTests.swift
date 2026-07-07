import Testing
import Foundation
import Mockable
@testable import Baguette

/// Orchestration coverage for `SimctlApps` — argv assembly + the
/// `Subprocess` exit handshake. The irreducible `xcrun` spawn lives in
/// `HostSubprocess` (integration-only), so every branch is driven
/// through `MockSubprocess`.
@Suite("SimctlApps")
struct SimctlAppsTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeApps(exitCode: Int32 = 0) -> (SimctlApps, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlApps(udid: "U", subprocess: sub), captures)
    }

    @Test func `install spawns xcrun simctl install with the app path`() async throws {
        let (apps, captures) = makeApps()
        try await apps.install(AppBundle(path: URL(fileURLWithPath: "/tmp/MyApp.ipa")))

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == ["simctl", "install", "U", "/tmp/MyApp.ipa"])
    }

    @Test func `a non-zero simctl exit propagates as an install failure`() async {
        let (apps, _) = makeApps(exitCode: 3)
        var caught: AppsError?
        do {
            try await apps.install(AppBundle(path: URL(fileURLWithPath: "/tmp/MyApp.ipa")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .installFailed(status: 3))
    }

    // MARK: archives — extract → locate → install

    /// Per-call capture for the two-subprocess archive flow: the ditto
    /// stub plays the extraction's side effect (materialising entries
    /// in the destination dir), the xcrun stub records the install argv.
    final class ArchiveCaptures: @unchecked Sendable {
        var extractionDir: String?
        var installArguments: [String]?
    }

    private func makeArchiveApps(
        dittoExit: Int32 = 0,
        installExit: Int32 = 0,
        extractedEntries: [String] = ["MyApp.app"]
    ) -> (SimctlApps, ArchiveCaptures) {
        let sub = MockSubprocess()
        let captures = ArchiveCaptures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            if exe == URL(fileURLWithPath: "/usr/bin/ditto") {
                let dest = args[args.count - 1]
                captures.extractionDir = dest
                for entry in extractedEntries {
                    try? FileManager.default.createDirectory(
                        atPath: dest + "/" + entry, withIntermediateDirectories: true
                    )
                }
                onExit(dittoExit)
            } else {
                captures.installArguments = args
                onExit(installExit)
            }
        }
        given(sub).terminate().willReturn()
        return (SimctlApps(udid: "U", subprocess: sub), captures)
    }

    @Test func `an archive is extracted with ditto and the inner app installed`() async throws {
        let (apps, captures) = makeArchiveApps()
        try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))

        let dir = try #require(captures.extractionDir)
        let argv = try #require(captures.installArguments)
        #expect(argv == ["simctl", "install", "U", dir + "/MyApp.app"])
    }

    @Test func `the extraction directory is cleaned up after the install`() async throws {
        let (apps, captures) = makeArchiveApps()
        try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))

        let dir = try #require(captures.extractionDir)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func `a non-zero ditto exit propagates as an extract failure`() async {
        let (apps, _) = makeArchiveApps(dittoExit: 2)
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/broken.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .extractFailed(status: 2))
    }

    @Test func `an archive with no app inside is refused`() async {
        let (apps, captures) = makeArchiveApps(extractedEntries: ["readme.txt"])
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/docs.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .noAppInArchive)
        #expect(captures.installArguments == nil)
    }

    @Test func `a simctl failure after extraction propagates as an install failure`() async {
        let (apps, _) = makeArchiveApps(installExit: 5)
        var caught: AppsError?
        do {
            try await apps.install(archive: AppArchive(path: URL(fileURLWithPath: "/tmp/up/MyApp.app.zip")))
        } catch {
            caught = error as? AppsError
        }
        #expect(caught == .installFailed(status: 5))
    }
}
