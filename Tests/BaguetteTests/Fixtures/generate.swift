import Foundation
import AVFoundation
import CoreVideo

// One-shot generator for the AVVideoDecoderTests fixtures. Run on a Mac
// with a working H.264 encoder; the output is committed, so CI never
// encodes anything.
//
//   swift genfixtures.swift <output-dir>
//
// Frames are solid grey ramping 40, 60, 80, 100 per frame at 30 fps, so
// consecutive frames decode to distinct pixels — the rewind test asserts
// the replayed frame matches frame 0 specifically.

func writeVideo(to url: URL, width: Int, height: Int, frames: Int) async throws {
    try? FileManager.default.removeItem(at: url)

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
    guard writer.startWriting() else {
        throw NSError(domain: "gen", code: 1, userInfo: [NSLocalizedDescriptionKey: "startWriting: \(String(describing: writer.error))"])
    }
    writer.startSession(atSourceTime: .zero)

    for i in 0..<frames {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buffer = pb else { throw NSError(domain: "gen", code: 2) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(40 + i * 20), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var guard_ = 0
        while !input.isReadyForMoreMediaData {
            usleep(1000)
            guard_ += 1
            if guard_ > 5000 { throw NSError(domain: "gen", code: 3, userInfo: [NSLocalizedDescriptionKey: "encoder never drained"]) }
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) else {
            throw NSError(domain: "gen", code: 4, userInfo: [NSLocalizedDescriptionKey: "append failed: \(String(describing: writer.error))"])
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw NSError(domain: "gen", code: 5, userInfo: [NSLocalizedDescriptionKey: "finish: \(String(describing: writer.error))"])
    }
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

try await writeVideo(to: outDir.appendingPathComponent("ramp-2000x1000.mp4"), width: 2000, height: 1000, frames: 4)
try await writeVideo(to: outDir.appendingPathComponent("ramp-320x240.mp4"), width: 320, height: 240, frames: 4)

for name in ["ramp-2000x1000.mp4", "ramp-320x240.mp4"] {
    let u = outDir.appendingPathComponent(name)
    let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as! Int
    let asset = AVURLAsset(url: u)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let natural = try await tracks[0].load(.naturalSize)
    print("\(name): \(size) bytes, naturalSize \(Int(natural.width))x\(Int(natural.height))")
}
