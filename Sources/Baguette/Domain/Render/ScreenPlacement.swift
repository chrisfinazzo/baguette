import Foundation

/// UV-space placement of a simulator frame on a device screen surface.
/// Scale below 1 crops the overflowing axis (cover); scale above 1
/// letterboxes the deficient axis (contain). Engine-agnostic: SceneKit
/// consumed this as a contents transform, RealityKit as a texture
/// coordinate transform.
struct ScreenPlacement: Equatable, Sendable {
    let scaleX: Double
    let scaleY: Double
    let offsetX: Double
    let offsetY: Double

    static let identity = ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
}

extension DeviceScreenFit {
    func placement(source: RenderDimensions, target: RenderDimensions) -> ScreenPlacement {
        guard self != .stretch else { return .identity }
        let sourceAspect = Double(source.width) / Double(source.height)
        let targetAspect = Double(target.width) / Double(target.height)
        var scaleX = 1.0
        var scaleY = 1.0
        if (self == .cover) == (sourceAspect > targetAspect) {
            scaleX = targetAspect / sourceAspect
        } else {
            scaleY = sourceAspect / targetAspect
        }
        return ScreenPlacement(
            scaleX: scaleX,
            scaleY: scaleY,
            offsetX: (1 - scaleX) / 2,
            offsetY: (1 - scaleY) / 2
        )
    }
}
