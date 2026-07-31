import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette

@Suite("Live3DStream")
struct Live3DStreamTests {
    @Test func `streams delivered simulator surfaces through one device scene`() throws {
        let screen = MockScreen()
        let scene = MockDeviceScene()
        let sink = Recording3DFrameSink()
        let surface = try #require(Self.surface())
        var delivery: (@Sendable (IOSurface) -> Void)?
        given(screen).start(onFrame: .any).willProduce { onFrame in
            delivery = onFrame
        }
        given(screen).stop().willReturn()
        given(scene).render(screen: .any).willReturn(Data([0xff, 0xd8, 0xff, 0xd9]))
        let stream = Live3DStream(
            config: .default,
            sink: sink,
            scene: scene
        )

        try stream.start(on: screen)
        delivery?(surface)
        #expect(Self.waitUntil { sink.chunks.count == 2 })
        stream.stop()

        #expect(sink.chunks.first == MJPEGEnvelope.header)
        #expect(sink.chunks.dropFirst().first ==
            MJPEGEnvelope.framed(jpeg: Data([0xff, 0xd8, 0xff, 0xd9])))
        verify(scene).render(screen: .any).called(1)
        verify(screen).stop().called(1)
    }

    @Test func `failed scene frame is skipped without ending subscription`() throws {
        let screen = MockScreen()
        let scene = MockDeviceScene()
        let sink = Recording3DFrameSink()
        let surface = try #require(Self.surface())
        let renderAttempted = DispatchSemaphore(value: 0)
        var delivery: (@Sendable (IOSurface) -> Void)?
        given(screen).start(onFrame: .any).willProduce { onFrame in
            delivery = onFrame
        }
        given(scene).render(screen: .any).willProduce { _ in
            renderAttempted.signal()
            throw DeviceModelError.renderFailed
        }
        let stream = Live3DStream(config: .default, sink: sink, scene: scene)

        try stream.start(on: screen)
        delivery?(surface)
        #expect(renderAttempted.wait(timeout: .now() + 1) == .success)

        #expect(sink.chunks == [MJPEGEnvelope.header])
        verify(scene).render(screen: .any).called(1)
    }

    @Test func `slow scene rendering does not block simulator frame delivery`() throws {
        let screen = MockScreen()
        let scene = MockDeviceScene()
        let sink = Recording3DFrameSink()
        let surface = try #require(Self.surface())
        let releaseRender = DispatchSemaphore(value: 0)
        var delivery: (@Sendable (IOSurface) -> Void)?
        given(screen).start(onFrame: .any).willProduce { onFrame in
            delivery = onFrame
        }
        given(scene).render(screen: .any).willProduce { _ in
            _ = releaseRender.wait(timeout: .now() + 0.15)
            return Data([0xff, 0xd8, 0xff, 0xd9])
        }
        let stream = Live3DStream(config: .default, sink: sink, scene: scene)
        try stream.start(on: screen)

        let started = ContinuousClock.now
        delivery?(surface)
        let elapsed = started.duration(to: .now)
        releaseRender.signal()

        #expect(elapsed < .milliseconds(50))
    }
}

private final class Recording3DFrameSink: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var chunks: [Data] {
        lock.withLock { storage }
    }

    func write(_ data: Data) {
        lock.withLock { storage.append(data) }
    }
}

private extension Live3DStreamTests {
    static func surface() -> IOSurface? {
        IOSurfaceCreate([
            kIOSurfaceWidth: 2,
            kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 8,
            kIOSurfaceAllocSize: 16,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary)
    }

    static func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
