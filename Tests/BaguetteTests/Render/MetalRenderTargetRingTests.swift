import IOSurface
import Metal
import Testing
@testable import Baguette

@Suite("MetalRenderTargetRing")
struct MetalRenderTargetRingTests {
    @Test func `renders with four samples before resolving into the codec surface`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ring = try MetalRenderTargetRing(
            width: 320,
            height: 240,
            device: device
        )

        let target = ring.next()

        #expect(ring.sampleCount == (device.supportsTextureSampleCount(4) ? 4 : 1))
        #expect(target.renderTexture.sampleCount == ring.sampleCount)
        #expect(target.texture.sampleCount == 1)
    }

    @Test func `cycles through three stable codec surfaces`() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let ring = try MetalRenderTargetRing(
            width: 320,
            height: 240,
            device: device
        )

        let ids = (0..<6).map { _ in IOSurfaceGetID(ring.next().surface) }

        #expect(Set(ids.prefix(3)).count == 3)
        #expect(ids[3] == ids[0])
        #expect(ids[4] == ids[1])
        #expect(ids[5] == ids[2])
    }
}
