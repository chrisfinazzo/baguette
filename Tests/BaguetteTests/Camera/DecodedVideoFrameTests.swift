import Testing
import Foundation
@testable import Baguette

@Suite("DecodedVideoFrame")
struct DecodedVideoFrameTests {

    @Test func `builds a CameraFrame under the assigned sequence, keeping its own timestamp`() throws {
        let decoded = DecodedVideoFrame(
            pixels: Data(count: 16), width: 2, height: 2, presentationMs: 33
        )
        let frame = try decoded.frame(sequence: 5)
        #expect(frame.sequence == 5)
        #expect(frame.timestampMs == 33)
        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.pixels.count == 16)
    }

    @Test func `rejects a decoded frame whose pixels don't match its dimensions`() {
        let bad = DecodedVideoFrame(
            pixels: Data(count: 8), width: 2, height: 2, presentationMs: 0
        )
        #expect(throws: (any Error).self) {
            _ = try bad.frame(sequence: 1)
        }
    }
}
