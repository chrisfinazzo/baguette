import Foundation

/// The host-side landing spot for a browser-uploaded camera source.
/// Unlike the `/files` upload (which `simctl` consumes synchronously
/// inside the request), a camera source must *outlive* its POST so the
/// camera WebSocket can stream from it later — so it's staged into a
/// persistent per-udid directory and remembered here, keyed by udid.
/// The camera WS resolves the staged path on `camera_start` and clears
/// the slot on teardown, so the browser never sends a filesystem path
/// across the wire.
///
/// `@MainActor` because both the upload route and the camera WS handler
/// touch it from that isolation.
@MainActor
final class CameraSourceStaging {
    static let shared = CameraSourceStaging()

    private let root: URL
    private var staged: [String: URL] = [:]

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("baguette-camera-source", isDirectory: true)) {
        self.root = root
    }

    /// Stage `data` for `udid`, replacing any file previously staged for
    /// it, and return the host path. The filename is reduced to its last
    /// path component so a crafted `name` can't escape the slot.
    @discardableResult
    func stage(udid: String, filename: String, data: Data) throws -> URL {
        let leaf = (filename as NSString).lastPathComponent
        let name = leaf.isEmpty ? "source" : leaf
        let dir = root.appendingPathComponent(udid, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try data.write(to: dest)
        staged[udid] = dest
        return dest
    }

    /// The staged host path for `udid`, or `nil` if nothing is staged.
    func path(udid: String) -> String? {
        staged[udid]?.path
    }

    /// Drop the staged file (and its slot directory) for `udid`.
    func clear(udid: String) {
        let dir = root.appendingPathComponent(udid, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        staged[udid] = nil
    }
}
