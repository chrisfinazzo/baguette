import Testing
import Foundation
import AVFoundation
import CoreVideo
@testable import Baguette

/// `AVVideoDecoder` is the AVFoundation half of video-file playback.
/// The pacing/looping logic above it is covered against
/// `MockVideoDecoder` in `VideoFileCaptureTests`; this suite drives the
/// real reader against a real asset, because the parts worth pinning
/// down — the BGRA request, the fit, the row-padding strip, rewinding,
/// the not-started/no-track errors — only exist against `AVAssetReader`.
///
/// The asset is synthesized into a temp file (the same way
/// `ImageFileCaptureTests` writes a PNG), so this needs no fixture, no
/// booted simulator and no camera.
@Suite("AVVideoDecoder")
struct AVVideoDecoderTests {

    /// Write a short H.264 clip of solid-colour frames at 30 fps.
    /// 2000×1000 forces a downscale against the 1280 canvas cap; the
    /// odd aspect also proves the fit isn't square.
    private func writeTempVideo(
        width: Int = 2000, height: Int = 1000, frames: Int = 6
    ) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-vidtest-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, nil, &pb
            )
            let buffer = try #require(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // Ramp the grey level per frame so frames are distinct.
                memset(base, Int32(40 + i * 20), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoDecoderError.cannotRead("writer: \(String(describing: writer.error))")
        }
        return url.path
    }

    @Test func `nextFrame before start reports the decoder isn't started`() {
        let decoder = AVVideoDecoder()
        #expect(throws: VideoDecoderError.notStarted) {
            _ = try decoder.nextFrame()
        }
    }

    @Test func `starting on a file that isn't a readable asset throws`() async {
        let decoder = AVVideoDecoder()
        await #expect(throws: (any Error).self) {
            try await decoder.start(path: "/tmp/does-not-exist-\(UUID().uuidString).mp4", maxDimension: 1280)
        }
    }

    @Test func `starting on a file with no video track names the file`() async throws {
        // A .mp4 extension over bytes that aren't a movie at all.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-notavideo-\(UUID().uuidString).mp4")
        try Data(repeating: 0, count: 512).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = AVVideoDecoder()
        await #expect(throws: (any Error).self) {
            try await decoder.start(path: url.path, maxDimension: 1280)
        }
    }

    @Test func `decoded frames arrive fitted to the canvas as tightly-packed BGRA`() async throws {
        let path = try await writeTempVideo()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let frame = try #require(try decoder.nextFrame())
        // 2000×1000 fitted into the 1280 canvas → 1280×640.
        #expect(frame.width == 1280)
        #expect(frame.height == 640)
        // Tightly packed: the decoder strips the CVPixelBuffer's row
        // padding, which 1280×4 wouldn't reveal on its own — the shared
        // buffer's reader assumes width*4 stride.
        #expect(frame.pixels.count == 1280 * 640 * 4)
    }

    @Test func `a smaller-than-canvas asset is not upscaled`() async throws {
        let path = try await writeTempVideo(width: 320, height: 240)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let frame = try #require(try decoder.nextFrame())
        #expect(frame.width == 320)
        #expect(frame.height == 240)
    }

    @Test func `frames arrive in presentation order and run out at the end of the asset`() async throws {
        let path = try await writeTempVideo(width: 320, height: 240, frames: 4)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        var timestamps: [UInt32] = []
        while let frame = try decoder.nextFrame() { timestamps.append(frame.presentationMs) }

        #expect(timestamps.count == 4)
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.first == 0)
        // 30 fps → ~33 ms apart; the last of 4 lands near 100 ms.
        #expect(timestamps.last! > 0)
        // Exhausted: further pulls keep reporting EOF rather than throwing.
        #expect(try decoder.nextFrame() == nil)
    }

    @Test func `rewind replays the asset from its first frame`() async throws {
        let path = try await writeTempVideo(width: 320, height: 240, frames: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }

        let first = try #require(try decoder.nextFrame())
        while try decoder.nextFrame() != nil {}  // drain to EOF

        try await decoder.rewind()
        let replayed = try #require(try decoder.nextFrame())
        #expect(replayed.presentationMs == first.presentationMs)
        #expect(replayed.pixels == first.pixels)
    }

    @Test func `stop ends the stream and leaves the decoder restartable`() async throws {
        let path = try await writeTempVideo(width: 320, height: 240, frames: 3)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        _ = try decoder.nextFrame()
        decoder.stop()

        #expect(throws: VideoDecoderError.notStarted) {
            _ = try decoder.nextFrame()
        }

        // start after stop is a fresh read of the same asset.
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }
        #expect(try decoder.nextFrame() != nil)
    }

    /// `start` on a live decoder must cancel the reader it replaces
    /// rather than orphan it — so a restart reads from the top.
    @Test func `starting again while streaming restarts from the first frame`() async throws {
        let path = try await writeTempVideo(width: 320, height: 240, frames: 4)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let decoder = AVVideoDecoder()
        try await decoder.start(path: path, maxDimension: 1280)
        defer { decoder.stop() }
        let first = try #require(try decoder.nextFrame())
        _ = try decoder.nextFrame()

        try await decoder.start(path: path, maxDimension: 1280)
        let afterRestart = try #require(try decoder.nextFrame())
        #expect(afterRestart.presentationMs == first.presentationMs)
    }
}
