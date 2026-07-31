import Foundation
import CoreImage
import CoreVideo
import IOSurface

/// Copies an `IOSurface` into a pooled, codec-ready `CVPixelBuffer`, optionally
/// downscaling it by an integer divisor. Output stays 4:2:0-aligned and the GPU
/// write is published before synchronous JPEG or asynchronous VideoToolbox use.
final class Scaler {
    private let context = CIContext(options: [.priorityRequestLow: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: RenderDimensions?

    /// Returns a fresh `CVPixelBuffer` with `surface` rendered into it at
    /// 1/`scale` size on each axis. Returns nil on allocation failure.
    func downscale(_ surface: IOSurface, scale: Int) -> CVPixelBuffer? {
        let srcW = IOSurfaceGetWidth(surface)
        let srcH = IOSurfaceGetHeight(surface)
        let size = RenderDimensions(
            width: max(2, srcW / scale),
            height: max(2, srcH / scale)
        ).alignedFor420

        if pool == nil || size != poolSize {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }

        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let dst = pbOut else { return nil }

        let src = CIImage(ioSurface: surface)
        let sx = CGFloat(size.width) / CGFloat(srcW)
        let sy = CGFloat(size.height) / CGFloat(srcH)
        context.render(src.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: dst)
        // Core Image writes through the GPU. Publish that completed write
        // before VideoToolbox retains the buffer for asynchronous encoding.
        CVPixelBufferLockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(dst, [])
        return dst
    }
}
