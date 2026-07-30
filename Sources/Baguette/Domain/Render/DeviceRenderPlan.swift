import Foundation

struct DeviceRotation: Equatable, Sendable, Codable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = DeviceRotation(x: 0, y: 0, z: 0)
}

struct DeviceRenderPlan: Equatable, Sendable {
    let model: InstalledDeviceModel
    let variants: [DeviceVariantSelection]
    let rotation: DeviceRotation
    let outputSize: RenderDimensions

    static func build(
        model: InstalledDeviceModel,
        variants: [String: String],
        rotation: DeviceRotation,
        outputSize: RenderDimensions
    ) throws -> DeviceRenderPlan {
        guard outputSize.width > 0, outputSize.height > 0 else {
            throw DeviceModelError.invalidOutputSize
        }
        guard rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite else {
            throw DeviceModelError.invalidRotation
        }
        return DeviceRenderPlan(
            model: model,
            variants: try model.definition.resolveVariants(variants),
            rotation: rotation,
            outputSize: outputSize
        )
    }
}
