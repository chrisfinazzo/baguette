import Foundation

/// Resolves the bundled `VirtualCamera.dylib` and copies it into a
/// per-hash subdirectory under
/// `~/Library/Application Support/Baguette/builds/<sha12>/VirtualCamera.dylib`.
/// The caller arms each booted sim with `DYLD_INSERT_LIBRARIES` pointing
/// at that path via `SimulatorInjection`.
///
/// Pure work (sha → dest path) lives in
/// `VirtualCameraInstallPlan`. This file owns the filesystem side —
/// bundle lookup, mkdir, write, permissions — kept thin so the
/// pure factory is exercised end-to-end by tests.
enum VirtualCameraInstaller {

    static var defaultSupportDir: String {
        ("~/Library/Application Support/Baguette" as NSString).expandingTildeInPath
    }

    /// Resolve the dylib bundled inside the running baguette binary.
    /// Returns `nil` in dev configurations that didn't stage the
    /// dylib (`build.sh` runs `VirtualCamera/build.sh` first; running
    /// `swift test` without that step leaves the resource absent —
    /// camera features then simply refuse to start).
    static func bundledDylibURL() -> URL? {
        Bundle.module.url(
            forResource: "VirtualCamera",
            withExtension: "dylib",
            subdirectory: "VirtualCamera"
        )
    }

    /// Read the bundled bytes, compute the install plan, apply it
    /// (idempotent), return the destination path. Returns `nil` if
    /// the dylib isn't bundled in this build configuration.
    static func installIfNeeded(supportDir: String = defaultSupportDir) -> String? {
        guard let url = bundledDylibURL(),
              let bytes = try? Data(contentsOf: url) else { return nil }
        let plan = VirtualCameraInstallPlan.compute(bytes: bytes, supportDir: supportDir)
        try? apply(plan: plan, bytes: bytes)
        return FileManager.default.fileExists(atPath: plan.destPath) ? plan.destPath : nil
    }

    /// Idempotent — if the file already exists at `plan.destPath` we
    /// trust its contents (the path itself is sha-keyed, so identical
    /// bytes land at the same path) and skip the rewrite. Skipping
    /// preserves the linker's adhoc signature, which iOS 26's
    /// simulator dyld rejects after any post-build `codesign --force`.
    static func apply(plan: VirtualCameraInstallPlan, bytes: Data) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: plan.destPath) { return }
        try fm.createDirectory(
            atPath: plan.buildDir,
            withIntermediateDirectories: true
        )
        try bytes.write(to: URL(fileURLWithPath: plan.destPath))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plan.destPath)
    }
}
