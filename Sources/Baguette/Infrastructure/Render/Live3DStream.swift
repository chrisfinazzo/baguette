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
    private let renderQueue = DispatchQueue(
        label: "com.baguette.live-3d-render",
        qos: .userInteractive
    )
    private var screen: (any Screen)?
    private var isRendering = false
    private var pendingSurface: IOSurface?
    private var isStopped = true

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
        lock.withLock {
            self.screen = screen
            isStopped = false
        }
        try screen.start { [weak self] surface in
            self?.enqueue(surface)
        }
    }

    func stop() {
        let activeScreen = lock.withLock {
            isStopped = true
            pendingSurface = nil
            let activeScreen = screen
            screen = nil
            return activeScreen
        }
        activeScreen?.stop()
    }

    func apply(_ config: StreamConfig) {
        lock.withLock { self.config = config }
    }

    func requestKeyframe() {}
    func requestSnapshot() {}

    private func enqueue(_ surface: IOSurface) {
        let shouldStart = lock.withLock {
            guard !isStopped else { return false }
            if isRendering {
                pendingSurface = surface
                return false
            }
            isRendering = true
            return true
        }
        guard shouldStart else { return }
        renderQueue.async { [weak self] in
            self?.render(surface)
        }
    }

    private func render(_ firstSurface: IOSurface) {
        var surface: IOSurface? = firstSurface
        while let current = surface {
            do {
                let jpeg = try scene.render(screen: current)
                let shouldWrite = lock.withLock { !isStopped }
                if shouldWrite {
                    sink.write(MJPEGEnvelope.framed(jpeg: jpeg))
                }
            } catch {
                log("live 3D frame skipped: \(error)")
            }
            surface = lock.withLock {
                guard !isStopped, let pendingSurface else {
                    self.pendingSurface = nil
                    isRendering = false
                    return nil
                }
                self.pendingSurface = nil
                return pendingSurface
            }
        }
    }
}
