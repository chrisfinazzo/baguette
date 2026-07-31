import CoreVideo
import IOSurface
import Testing
@testable import Baguette

@Suite("Scaler")
struct ScalerTests {
    @Test func `publishes the copied frame before asynchronous codec consumption`() throws {
        let source = try #require(Self.surface())
        let frame = try #require(Scaler().downscale(source, scale: 1))
        let output = try #require(CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue())
        var seed: UInt32 = 0

        IOSurfaceLock(output, .readOnly, &seed)
        IOSurfaceUnlock(output, .readOnly, nil)

        #expect(seed > 1)
    }

    private static func surface() -> IOSurface? {
        guard let surface = IOSurfaceCreate([
            kIOSurfaceWidth: 8,
            kIOSurfaceHeight: 8,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 32,
            kIOSurfaceAllocSize: 256,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary) else { return nil }
        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), 0x7f, 256)
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}
