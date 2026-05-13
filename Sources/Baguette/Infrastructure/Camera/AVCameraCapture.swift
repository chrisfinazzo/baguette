import Foundation

/// `CameraCapture` orchestrator. Wraps a `VideoCapture` collaborator
/// and on every raw BGRA frame:
///
///   1. assigns a monotonic sequence number (per session — resets on start)
///   2. strips row padding via `BGRAConverter`
///   3. forwards the tightly-packed `CameraFrame` to the caller's `onFrame`
///
/// The actual `AVCaptureSession` plumbing lives behind `HostVideoCapture`
/// (~50 LOC, integration-only). This orchestrator is unit-covered
/// end-to-end via `MockVideoCapture`.
final class AVCameraCapture: CameraCapture, @unchecked Sendable {
    private let video: any VideoCapture
    private let lock = NSLock()
    private var sequence: UInt32 = 0

    init(video: any VideoCapture) {
        self.video = video
    }

    convenience init() {
        self.init(video: HostVideoCapture())
    }

    func start(
        device: CameraDevice,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) async throws {
        resetSequence()
        try await video.start(deviceUniqueID: device.uid) { [weak self] raw in
            guard let self else { return }
            let seq = self.nextSequence()
            do {
                let frame = try BGRAConverter.convert(
                    baseAddress: raw.baseAddress,
                    width: raw.width,
                    height: raw.height,
                    bytesPerRow: raw.bytesPerRow,
                    sequence: seq,
                    timestampMs: raw.timestampMs
                )
                onFrame(frame)
            } catch {
                // Single-frame conversion failures are non-fatal —
                // skip and keep streaming.
            }
        }
    }

    func stop() async {
        await video.stop()
    }

    private func nextSequence() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    private func resetSequence() {
        lock.lock(); defer { lock.unlock() }
        sequence = 0
    }
}
