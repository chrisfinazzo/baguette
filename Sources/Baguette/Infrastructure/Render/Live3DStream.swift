import Foundation
import IOSurface

/// Live MJPEG stream produced by one persistent 3D device scene.
///
/// `Screen` owns SimulatorKit frame delivery; `DeviceScene` owns the loaded
/// SceneKit scene. This orchestrator only manages their lifecycle and MJPEG
/// transport framing.
final class Live3DStream: Stream, @unchecked Sendable {
    private(set) var config: StreamConfig
    private let sink: any FrameSink
    private let scene: any DeviceScene
    private let lock = NSLock()
    private var screen: (any Screen)?

    init(
        config: StreamConfig,
        sink: any FrameSink,
        scene: any DeviceScene
    ) {
        self.config = config
        self.sink = sink
        self.scene = scene
    }

    func start(on screen: any Screen) throws {
        sink.write(MJPEGEnvelope.header)
        self.screen = screen
        try screen.start { [weak self] surface in
            self?.handle(surface)
        }
    }

    func stop() {
        screen?.stop()
        screen = nil
    }

    func apply(_ config: StreamConfig) {
        lock.withLock { self.config = config }
    }

    func requestKeyframe() {}
    func requestSnapshot() {}

    private func handle(_ surface: IOSurface) {
        do {
            let jpeg = try scene.render(screen: surface)
            sink.write(MJPEGEnvelope.framed(jpeg: jpeg))
        } catch {
            log("live 3D frame skipped: \(error)")
        }
    }
}
