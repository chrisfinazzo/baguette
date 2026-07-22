import Foundation

/// Locator for the plugins baguette itself ships (currently the
/// reference accessibility audit). Deliberately the same three-step
/// lookup `WebRoot` uses for the web assets, for the same reasons:
///
///   1. `$BAGUETTE_PLUGIN_DIR` — explicit override.
///   2. Source-tree path (dev) — when the running executable lives
///      inside the package's `.build/`, walk up to the package root
///      and read `Plugins/` directly. Edit a bundled plugin and the
///      next run picks it up; no rebuild.
///   3. Sidecar `Baguette_Baguette.bundle` next to the executable —
///      the SPM resource bundle, resolved via `dladdr` rather than
///      `Bundle.module`, which `fatalError`s when the bundle is
///      missing (e.g. a binary-only install).
///
/// Returns nil when nothing resolves. A missing bundled root is not an
/// error — it just means no plugins ship with this build.
enum PluginRoot {

    /// Path inside the package's source tree.
    static let sourceTreePath = "Sources/Baguette/Resources/Plugins"
    /// Directory name inside the SPM resource bundle.
    static let bundleDirectoryName = "Plugins"

    static func bundled() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BAGUETTE_PLUGIN_DIR"] {
            let url = URL(fileURLWithPath: override)
            return isDirectory(url) ? url : nil
        }
        if let dev = sourceTreeRoot() { return dev }
        return sidecarRoot()
    }

    // MARK: - private

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Walk up from the executable looking for the package's bundled
    /// plugins. Only matches when running out of `.build/`; returns
    /// nil for a release install. Mirrors `WebRoot.sourceTreeRoot`.
    private static func sourceTreeRoot() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = url.appendingPathComponent(sourceTreePath)
            if isDirectory(candidate) { return candidate }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static func sidecarRoot() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let cstr = info.dli_fname else { return nil }
        let exeDir = URL(fileURLWithPath: String(cString: cstr)).deletingLastPathComponent()
        let bundleURL = exeDir.appendingPathComponent("Baguette_Baguette.bundle")
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              let bundle = Bundle(url: bundleURL),
              let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent(bundleDirectoryName)
        return isDirectory(candidate) ? candidate : nil
    }
}
