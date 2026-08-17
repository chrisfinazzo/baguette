import Foundation

/// `Motion` backed by a small JSON file both sides can see, plus the
/// shared `DYLD_INSERT_LIBRARIES` arming.
///
/// The simulator shares the host's `/tmp`, which is how the camera already
/// hands frames to its dylib through `/tmp/SimCam.bgra`. Motion needs far
/// less bandwidth — one small intent whenever the device changes what it's
/// doing — so it's a plain atomic file write rather than a mapped ring
/// buffer.
///
/// The file is a **single current value, not a log**: each publish replaces
/// it, because a dylib reading a concatenation would fail to parse and
/// therefore see no motion at all.
final class SharedFileMotion: Motion, @unchecked Sendable {

    /// Where the intent is published. Same shared-`/tmp` convention as the
    /// camera's frame buffer.
    static let defaultPath = "/tmp/BaguetteMotion.json"

    private let fileURL: URL
    private let dylibPath: String
    private let injection: any SimulatorInjection

    init(
        fileURL: URL = URL(fileURLWithPath: SharedFileMotion.defaultPath),
        dylibPath: String,
        injection: any SimulatorInjection = SimctlSimulatorInjection()
    ) {
        self.fileURL = fileURL
        self.dylibPath = dylibPath
        self.injection = injection
    }

    func publish(_ intent: MotionIntent, on simulator: any Simulator) async throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        // Atomic, so a dylib reading concurrently never sees a half-written
        // intent — it either parses the old one or the new one.
        try intent.encoded().write(to: fileURL, options: .atomic)
        try await injection.arm(dylibPath: dylibPath, on: simulator)
    }

    func clear(on simulator: any Simulator) async throws {
        // The file is deliberately left in place. Disarming only stops
        // *future* launches loading the dylib; an app already running still
        // has it loaded and still reads this file, so deleting it would
        // leave a live reader with nothing to read. Callers park the device
        // with a stationary publish first, and that parked value is what a
        // running app keeps seeing.
        try await injection.disarm(dylibPath: dylibPath, on: simulator)
    }
}
