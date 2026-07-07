import Foundation

/// A zip that carries an app — how a folder-form `.app` bundle travels
/// over HTTP. The browser can't upload a directory as one file, so the
/// drop target packs the bundle into a stored zip and posts that; a
/// user-zipped `.app` arrives the same way. `simctl install` doesn't
/// take zips, so unlike `AppBundle` this value isn't installable as-is:
/// it must be extracted first (`ditto -x -k`), then the single `.app`
/// inside is installed through the normal `AppBundle` path.
///
/// All three answers here are pure: `at(_:)` classifies by extension
/// (no disk access, so the serve route can reject before reading the
/// body), `extractArguments(to:)` projects the ditto argv tail, and
/// `installableApp(amongExtracted:)` picks the app from the extracted
/// top-level names. The Infrastructure adapter (`SimctlApps`) just runs
/// the two subprocesses around them.
public struct AppArchive: Equatable, Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Classify a host file as an app archive, or `nil` when it isn't
    /// a zip. `.ipa` is deliberately excluded — it installs directly
    /// via `AppBundle` without an extraction step.
    public static func at(_ path: URL) -> AppArchive? {
        guard path.pathExtension.lowercased() == "zip" else { return nil }
        return AppArchive(path: path)
    }

    /// The argv tail handed to `/usr/bin/ditto -x -k <zip> <dest>`.
    /// ditto (not `unzip`) because it restores the unix modes stored
    /// in the zip's external attributes — the app's main executable
    /// must come out executable.
    public func extractArguments(to destination: URL) -> [String] {
        ["-x", "-k", path.path, destination.path]
    }

    /// Pick the app from the archive's extracted top-level entries:
    /// exactly one `.app` (case-insensitive), after ignoring Finder
    /// junk (`__MACOSX`) and dotfiles. Two apps are ambiguous —
    /// refused (`nil`) rather than guessed at.
    public static func installableApp(amongExtracted entries: [String]) -> String? {
        let apps = entries.filter {
            !$0.hasPrefix(".") && $0 != "__MACOSX"
                && ($0 as NSString).pathExtension.lowercased() == "app"
        }
        return apps.count == 1 ? apps[0] : nil
    }
}
