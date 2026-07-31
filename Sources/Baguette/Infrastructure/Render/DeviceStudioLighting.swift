import AppKit
import SceneKit

/// The neutral studio environment shared by live and still 3D rendering.
///
/// broad softboxes provide reflections without tinting or clipping device finishes.
enum DeviceStudioLighting {
    static func apply(to scene: SCNScene) {
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 2.6
    }

    private static let environment: NSImage = {
        let width = 1024
        let height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        let size = CGSize(width: width, height: height)
        let backgroundColors = [
            CGColor(gray: 0.36, alpha: 1),
            CGColor(gray: 0.30, alpha: 1),
            CGColor(gray: 0.12, alpha: 1),
            CGColor(gray: 0.25, alpha: 1),
        ] as CFArray
        let stops: [CGFloat] = [0, 0.32, 0.58, 1]
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: backgroundColors,
            locations: stops
        ) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }

        let panelWidth = size.width * 0.15
        let panelHeight = size.height * 0.34
        let panelY = size.height * 0.38
        let centers: [CGFloat] = [-0.02, 0.24, 0.50, 0.76, 1.02]
        for (index, center) in centers.enumerated() {
            let rect = CGRect(
                x: size.width * center - panelWidth / 2,
                y: panelY,
                width: panelWidth,
                height: panelHeight
            )
            let brightness: CGFloat = index == 3 ? 1 : 0.88
            let corner = panelWidth * 0.18

            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: panelWidth * 0.18,
                color: CGColor(gray: 1, alpha: 0.55)
            )
            context.setFillColor(CGColor(gray: brightness, alpha: 1))
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()

            let inner = rect.insetBy(
                dx: panelWidth * 0.12,
                dy: panelHeight * 0.14
            )
            context.setFillColor(CGColor(
                gray: min(brightness + 0.12, 1),
                alpha: 0.92
            ))
            context.addPath(CGPath(
                roundedRect: inner,
                cornerWidth: corner * 0.75,
                cornerHeight: corner * 0.75,
                transform: nil
            ))
            context.fillPath()

            let reflection = CGRect(
                x: rect.minX + panelWidth * 0.12,
                y: size.height * 0.20,
                width: panelWidth * 0.76,
                height: size.height * 0.18
            )
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: panelWidth * 0.22,
                color: CGColor(gray: 1, alpha: 0.25)
            )
            context.setFillColor(CGColor(gray: brightness, alpha: 0.12))
            context.fillEllipse(in: reflection)
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: image, size: size)
    }()
}
