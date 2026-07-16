import Testing
import Foundation
import Mockable
@testable import Baguette

@Suite("VideoFileCapture orchestrator")
struct VideoFileCaptureTests {

    /// Hands out a looping script of decoded frames; `nil` marks EOF.
    final class Feed: @unchecked Sendable {
        private let script: [DecodedVideoFrame?]
        private var idx = 0
        init(_ script: [DecodedVideoFrame?]) { self.script = script }
        func next() -> DecodedVideoFrame? {
            defer { idx += 1 }
            return script[idx % script.count]
        }
    }

    final class Recorder: @unchecked Sendable {
        var frames: [CameraFrame] = []
        func record(_ f: CameraFrame) { frames.append(f) }
        var count: Int { frames.count }
    }

    final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private func decoded(pts: UInt32) -> DecodedVideoFrame {
        DecodedVideoFrame(pixels: Data(count: 16), width: 2, height: 2, presentationMs: pts)
    }

    /// Poll until `cond` holds or a short deadline elapses.
    private func waitUntil(_ cond: @escaping @Sendable () -> Bool) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func `start rejects a source that isn't a video`() async {
        let cap = VideoFileCapture(decoder: MockVideoDecoder())
        await #expect(throws: (any Error).self) {
            try await cap.start(source: .image(path: "/tmp/pic.png")) { _ in }
        }
    }

    @Test func `emits frames with a monotonic sequence and loops the asset at EOF`() async throws {
        let decoder = MockVideoDecoder()
        let feed = Feed([decoded(pts: 0), decoded(pts: 20), nil])  // 2 frames, then loop
        let rewinds = Counter()
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willProduce { rewinds.bump() }
        given(decoder).stop().willReturn(())

        let rec = Recorder()
        let cap = VideoFileCapture(decoder: decoder)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { rec.record($0) }

        // Four frames means we crossed the EOF boundary at least once.
        await waitUntil { rec.count >= 4 }
        await cap.stop()

        #expect(Array(rec.frames.prefix(4)).map(\.sequence) == [1, 2, 3, 4])
        #expect(rewinds.value >= 1)
    }

    @Test func `stop tears down the decoder`() async throws {
        let decoder = MockVideoDecoder()
        let feed = Feed([decoded(pts: 0)])
        given(decoder).start(path: .any, maxDimension: .any).willReturn(())
        given(decoder).nextFrame().willProduce { feed.next() }
        given(decoder).rewind().willReturn(())
        given(decoder).stop().willReturn(())

        let cap = VideoFileCapture(decoder: decoder)
        try await cap.start(source: .video(path: "/tmp/clip.mp4")) { _ in }
        await cap.stop()

        verify(decoder).stop().called(1)
    }
}
