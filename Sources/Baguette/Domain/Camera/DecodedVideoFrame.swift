import Foundation

/// One frame handed back by a `VideoDecoder`, already fitted to the
/// shared canvas and copied out of its `CVPixelBuffer` so it survives
/// past the decode call (unlike the webcam path's `RawBGRAFrame`, whose
/// base address is valid only during the callback). Tightly-packed BGRA
/// — `pixels.count == width * height * 4`. `presentationMs` is the
/// frame's timestamp within the asset, which the orchestrator uses to
/// pace playback.
struct DecodedVideoFrame: Equatable, Sendable {
    let pixels: Data
    let width: UInt32
    let height: UInt32
    let presentationMs: UInt32

    /// Project into a `CameraFrame` under an orchestrator-assigned
    /// sequence. Throws if the pixels don't match the dimensions
    /// (delegates to `CameraFrame`'s validation).
    func frame(sequence: UInt32) throws -> CameraFrame {
        try CameraFrame(
            sequence: sequence,
            timestampMs: presentationMs,
            width: width,
            height: height,
            pixels: pixels
        )
    }
}
