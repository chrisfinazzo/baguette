import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOSurface

/// The `Reel` that actually writes a file — a thin wrapper over
/// `AVAssetWriter` plus one Core Image blit per frame.
///
/// Deliberately dumb. Every decision (`how big`, `where the frame
/// lands`, `which frames make the cut`, `when to stop`) is already
/// settled by `ScreenRecorder` and arrives here as a `CapturePlacement`
/// and a presentation time; this type opens the writer, composites the
/// surface onto the canvas, and appends. That split is CLAUDE.md's
/// "conversational I/O" adapter pattern: the state machine is unit-tested
/// through `MockReel`, and only the irreducible AVFoundation calls below
/// stay integration-only.
///
/// **Why a server-side encoder is fine here and not in `serve`:**
/// `docs/features/recording.md` rejects server-side recording for the
/// live-stream / device-farm case because it would add an N+1th
/// VideoToolbox session next to the one each booted device already runs
/// for its live AVCC stream, and because an `ffmpeg -c copy` tap never
/// sees the SPS/PPS `H264Encoder` emits on its first IDR. `baguette
/// record` has no competing live stream and owns the encode from frame
/// one, so neither objection applies. This type is not reachable from
/// `baguette serve`.
final class AVAssetWriterReel: Reel, @unchecked Sendable {

    /// One `CIContext` for the life of the reel — building one per frame
    /// re-JITs the render graph and tanks throughput.
    private let context = CIContext(options: [.priorityRequestLow: false])
    private let lock = NSLock()

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var placement: CapturePlacement?
    private var background: HexColor?
    private var lastTime: Double = 0
    private var frameInterval: Double = 1.0 / 30.0

    /// Presentation times are expressed against this timescale; 600 is
    /// the usual QuickTime choice because it divides 24 / 25 / 30 / 60
    /// exactly, so no frame rate accumulates rounding drift.
    private static let timescale: CMTimeScale = 600

    // MARK: - Reel

    func open(to url: URL, placement: CapturePlacement, plan: RecordingPlan) throws {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: url,
                fileType: plan.format == .mp4 ? .mp4 : .mov
            )
        } catch {
            throw RecordingError.writerFailed(
                "cannot write \(url.path): \(error.localizedDescription)"
            )
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: placement.width,
                AVVideoHeightKey: placement.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.bitrateBps,
                    AVVideoExpectedSourceFrameRateKey: plan.fps,
                    // A keyframe every two seconds keeps seeking usable
                    // without bloating a short clip.
                    AVVideoMaxKeyFrameIntervalKey: plan.fps * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
        )
        // Frames arrive on SimulatorKit's cadence, not on the writer's —
        // real-time mode lets the writer drop rather than stall us.
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecordingError.writerFailed(
                "AVAssetWriter rejected a \(placement.width)×\(placement.height) H.264 track"
            )
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: placement.width,
                kCVPixelBufferHeightKey as String: placement.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter refused to start"
            )
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.placement = placement
        self.frameInterval = plan.frameInterval
        // Video has no alpha channel, so the letterbox always shows
        // *some* colour — the user's `--background`, opaque.
        self.background = plan.background
    }

    func append(frame surface: IOSurface, at seconds: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // A writer that isn't ready drops the frame rather than stalling
        // the screen's delivery queue behind the encoder.
        guard let adaptor, let input, let placement, let background,
              let pool = adaptor.pixelBufferPool,
              input.isReadyForMoreMediaData else { return false }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return false }

        context.render(
            Self.compose(surface, placement: placement, over: background),
            to: buffer
        )
        // Publish Core Image's GPU write before VideoToolbox reads the
        // buffer asynchronously — same handshake `VideoFrameScaler` does
        // before handing a buffer to a codec.
        CVPixelBufferLockBaseAddress(buffer, [])
        CVPixelBufferUnlockBaseAddress(buffer, [])

        guard adaptor.append(
            buffer,
            withPresentationTime: CMTime(
                seconds: seconds, preferredTimescale: Self.timescale
            )
        ) else { return false }

        lastTime = seconds
        return true
    }

    func close() async throws {
        guard let (writer, input, end) = takeWriter() else { return }
        input.markAsFinished()
        // The last frame occupies its own interval too, so the session
        // ends one interval past it — otherwise a 5 s recording reports
        // 4.97 s and the final frame flashes by.
        writer.endSession(atSourceTime: CMTime(
            seconds: end, preferredTimescale: Self.timescale
        ))
        await writer.finishWriting()

        if writer.status == .failed {
            throw RecordingError.writerFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter failed"
            )
        }
    }

    func discard() {
        // `cancelWriting` is the one call that both stops the writer and
        // deletes the file it had already created — exactly what "there
        // was no film on this reel" should leave behind.
        takeWriter()?.writer.cancelWriting()
    }

    /// Hand the writer over and clear it, so a second `close()` — or a
    /// `discard()` after one — is a no-op. Split out of the async
    /// `close()` because `NSLock` is unavailable from an async context.
    private func takeWriter()
        -> (writer: AVAssetWriter, input: AVAssetWriterInput, end: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let input else { return nil }
        let end = lastTime + frameInterval
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        return (writer, input, end)
    }

    // MARK: - Compositing

    /// Scale the simulator's surface into its `drawWidth × drawHeight`
    /// slot at `drawX / drawY` and lay it over the background.
    ///
    /// The one non-obvious line is the vertical mirror, and it is the
    /// same one `CaptureCanvas.compose` carries for screenshots: a
    /// `CapturePlacement` counts `drawY` **down from the top** — the
    /// convention `capture-size.js` speaks, because that's how a canvas
    /// 2D context talks — while Core Image counts **up from the bottom**.
    /// A symmetric letterbox hides the difference; an odd-pixel canvas
    /// (every frame the even-dimension rule grew) and every `.cover`
    /// crop do not. Both halves of the capture vocabulary have to land a
    /// frame on the same row.
    static func compose(
        _ surface: IOSurface,
        placement: CapturePlacement,
        over background: HexColor
    ) -> CIImage {
        let source = CIImage(ioSurface: surface)
        let width = max(1, CGFloat(IOSurfaceGetWidth(surface)))
        let height = max(1, CGFloat(IOSurfaceGetHeight(surface)))
        let canvas = CGRect(
            x: 0, y: 0, width: placement.width, height: placement.height
        )
        let scaled = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(placement.drawWidth) / width,
            y: CGFloat(placement.drawHeight) / height
        ))
        let originY = placement.height - placement.drawY - placement.drawHeight
        return scaled
            .transformed(by: CGAffineTransform(
                translationX: CGFloat(placement.drawX),
                y: CGFloat(originY)
            ))
            // `.cover` draws outside the canvas on purpose — that
            // overflow is the crop, and cropping is what removes it.
            .composited(over: mat(background, on: canvas))
            .cropped(to: canvas)
    }

    /// The letterbox, as an opaque image the size of the canvas. Video
    /// has no alpha channel, so there is always *some* mat colour —
    /// unlike a PNG screenshot, `transparent` isn't on the menu.
    private static func mat(_ colour: HexColor, on canvas: CGRect) -> CIImage {
        CIImage(color: CIColor(
            red: colour.red, green: colour.green, blue: colour.blue, alpha: 1
        )).cropped(to: canvas)
    }
}
