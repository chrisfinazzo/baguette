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
        var delivery: (@Sendable (IOSurface) -> Void)?
        given(screen).start(onFrame: .any).willProduce { onFrame in
            delivery = onFrame
        }
        given(scene).render(screen: .any)
            .willThrow(DeviceModelError.renderFailed)
        let stream = Live3DStream(config: .default, sink: sink, scene: scene)

        try stream.start(on: screen)
        delivery?(surface)

        #expect(sink.chunks == [MJPEGEnvelope.header])
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
}
