import Foundation

/// What a plugin is allowed to ask baguette to do. A manifest declares
/// the set it needs; the server grants exactly that set for the life of
/// one command invocation and refuses everything else.
///
/// Least privilege by default: a manifest that declares nothing gets
/// nothing. The set is closed so a typo is a parse error rather than a
/// silent denial at runtime — and so a user reading
/// `baguette plugin show` sees a finite, meaningful list before
/// installing.
enum PluginCapability: String, Equatable, Sendable, CaseIterable, Comparable {
    /// Read the on-screen accessibility tree.
    case describeUI = "describe-ui"
    /// Capture the screen.
    case screenshot
    /// Dispatch gestures, keys and button presses to the device. The
    /// most powerful one — it can drive the device anywhere, including
    /// through consent dialogs — so it is never implied.
    case input
    /// Read the unified log stream.
    case logs
    /// Read or override the status bar.
    case statusBar = "status-bar"
    /// Read or set the simulated location.
    case location
    /// Install apps / add media to the device.
    case files
    /// List simulators and their state.
    case simulators

    static func < (lhs: PluginCapability, rhs: PluginCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
