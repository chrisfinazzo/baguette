import AppKit
import CoreImage
import Foundation
import IOSurface
import SceneKit

/// Persistent SceneKit adapter for one live 3D stream connection.
///
/// Model resolution, variant authoring, scene loading, camera, and lighting
/// happen once. Per simulator frame only the screen texture and snapshot are
/// updated.
final class SceneKitDeviceScene: DeviceScene, @unchecked Sendable {
    private let plan: DeviceRenderPlan
    private let quality: Double
    private let scene: SCNScene
    private let screenNode: SCNNode
    private let renderer: SCNRenderer
    private let scratch: URL
    private let ciContext = CIContext()
    private let lock = NSLock()

    init(
        plan: DeviceRenderPlan,
        quality: Double,
        assets: VerifiedDeviceAssets = VerifiedDeviceAssets()
    ) throws {
        self.plan = plan
        self.quality = quality
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        do {
            let assetURL = try assets.resolve(plan.model)
            let sceneURL = try Self.preparedSceneURL(
                assetURL: assetURL,
                selections: plan.variants,
                scratch: scratch
            )
            guard let source = try? SCNScene(url: sceneURL, options: nil) else {
                throw DeviceModelError.sceneLoadFailed(assetURL.path)
            }
            let definition = plan.model.definition
            guard let subject = source.rootNode.childNode(
                withName: definition.scene.rootNode,
                recursively: true
            ) else {
                throw DeviceModelError.sceneNodeNotFound(definition.scene.rootNode)
            }
            Self.applyMaterialColors(
                plan.variants.reduce(into: [:]) { colors, selection in
                    colors.merge(selection.materialColors) { _, requested in requested }
                },
                under: subject
            )
            guard let screen = Self.findScreenNode(
                under: subject,
                explicitName: definition.scene.screenNode,
                materialName: definition.scene.screenMaterial
            ) else {
                throw DeviceModelError.sceneNodeNotFound(
                    definition.scene.screenNode ?? definition.scene.screenMaterial
                )
            }
            screenNode = screen

            let output = SCNScene()
            output.background.contents = Self.backgroundColor(plan.background)
            let wrapper = SCNNode()
            wrapper.name = "baguette-device"
            subject.removeFromParentNode()
            wrapper.addChildNode(subject)
            output.rootNode.addChildNode(wrapper)
            wrapper.eulerAngles = SCNVector3(
                Self.radians(plan.rotation.x),
                Self.radians(plan.rotation.y),
                Self.radians(plan.rotation.z)
            )
            let bounds = wrapper.boundingBox
            let minimum = bounds.min
            let maximum = bounds.max
            guard maximum.x > minimum.x || maximum.y > minimum.y || maximum.z > minimum.z else {
                throw DeviceModelError.sceneHasNoGeometry
            }
            let center = SCNVector3(
                (minimum.x + maximum.x) / 2,
                (minimum.y + maximum.y) / 2,
                (minimum.z + maximum.z) / 2
            )
            wrapper.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

            let width = max(Double(maximum.x - minimum.x), 0.001)
            let height = max(Double(maximum.y - minimum.y), 0.001)
            let depth = max(Double(maximum.z - minimum.z), 0.001)
            let aspect = Double(plan.outputSize.width) / Double(plan.outputSize.height)
            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.orthographicScale = max(height, width / aspect) * 0.59
            camera.zNear = 0.001
            camera.zFar = max(1000, depth * 100)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(
                0, 0, Float(max(width, height) + depth + 10)
            )
            output.rootNode.addChildNode(cameraNode)
            Self.addLights(to: output)
            scene = output

            let sceneRenderer = SCNRenderer(device: nil, options: nil)
            sceneRenderer.scene = output
            sceneRenderer.pointOfView = cameraNode
            renderer = sceneRenderer
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    func render(screen surface: IOSurface) throws -> Data {
        try lock.withLock {
            let sourceImage = try image(from: surface)
            let texture = Self.fittedTexture(
                sourceImage,
                target: plan.model.definition.scene.textureSize,
                fit: plan.fit
            )
            Self.replaceMaterial(
                on: screenNode,
                named: plan.model.definition.scene.screenMaterial,
                texture: texture
            )
            let image = renderer.snapshot(
                atTime: 0,
                with: CGSize(
                    width: plan.outputSize.width,
                    height: plan.outputSize.height
                ),
                antialiasingMode: .multisampling4X
            )
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: quality]
                  ) else {
                throw DeviceModelError.renderFailed
            }
            return jpeg
        }
    }

    private func image(from surface: IOSurface) throws -> NSImage {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let ciImage = CIImage(ioSurface: surface)
        guard let cgImage = ciContext.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            throw DeviceModelError.screenImageInvalid
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: width, height: height)
        )
    }

    private static func preparedSceneURL(
        assetURL: URL,
        selections: [DeviceVariantSelection],
        scratch: URL
    ) throws -> URL {
        let usdSelections = selections.filter { $0.kind == .usd }
        guard !usdSelections.isEmpty else { return assetURL }
        let stagedName = "device.\(assetURL.pathExtension)"
        let stagedAsset = scratch.appending(path: stagedName)
        try FileManager.default.createSymbolicLink(
            at: stagedAsset,
            withDestinationURL: assetURL
        )
        let overlay = try USDVariantOverlay.make(
            assetReference: stagedName,
            selections: usdSelections
        )
        let overlayURL = scratch.appending(path: "variants.usda")
        try overlay.write(to: overlayURL, atomically: true, encoding: .utf8)
        return overlayURL
    }

    private static func findScreenNode(
        under subject: SCNNode,
        explicitName: String?,
        materialName: String
    ) -> SCNNode? {
        if let explicitName,
           let node = subject.childNode(withName: explicitName, recursively: true) {
            return node
        }
        if subject.geometry?.materials.contains(where: { $0.name == materialName }) == true {
            return subject
        }
        for child in subject.childNodes {
            if let found = findScreenNode(
                under: child,
                explicitName: nil,
                materialName: materialName
            ) {
                return found
            }
        }
        return nil
    }

    private static func applyMaterialColors(
        _ colors: [String: String],
        under node: SCNNode
    ) {
        if let geometry = node.geometry {
            geometry.materials = geometry.materials.map { existing in
                guard let name = existing.name, let hex = colors[name] else {
                    return existing
                }
                let material = existing.copy() as? SCNMaterial ?? SCNMaterial()
                material.name = name
                material.diffuse.contents = color(hex)
                return material
            }
        }
        node.childNodes.forEach { applyMaterialColors(colors, under: $0) }
    }

    private static func replaceMaterial(
        on node: SCNNode,
        named name: String,
        texture: NSImage
    ) {
        guard let geometry = node.geometry else { return }
        geometry.materials = geometry.materials.map { existing in
            guard existing.name == name else { return existing }
            let material = existing.copy() as? SCNMaterial ?? SCNMaterial()
            material.name = existing.name
            material.diffuse.contents = texture
            material.emission.contents = texture
            material.emission.intensity = 1
            material.lightingModel = .constant
            return material
        }
    }

    private static func fittedTexture(
        _ source: NSImage,
        target: RenderDimensions,
        fit: DeviceScreenFit
    ) -> NSImage {
        let targetSize = NSSize(width: target.width, height: target.height)
        let output = NSImage(size: targetSize)
        output.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: targetSize)).fill()
        let sourceSize = source.size
        let destination: NSRect
        switch fit {
        case .stretch:
            destination = NSRect(origin: .zero, size: targetSize)
        case .cover, .contain:
            let scaleX = targetSize.width / sourceSize.width
            let scaleY = targetSize.height / sourceSize.height
            let scale = fit == .cover ? max(scaleX, scaleY) : min(scaleX, scaleY)
            let size = NSSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            destination = NSRect(
                x: (targetSize.width - size.width) / 2,
                y: (targetSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }
        source.draw(
            in: destination,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()
        return output
    }

    private static func backgroundColor(_ background: DeviceRenderBackground) -> NSColor {
        switch background {
        case .transparent: return .clear
        case .color(let hex): return color(hex)
        }
    }

    private static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    private static func addLights(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 700
        ambient.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        let key = SCNLight()
        key.type = .omni
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(4, 6, 8)
        scene.rootNode.addChildNode(keyNode)
    }

    private static func radians(_ degrees: Double) -> Float {
        Float(degrees * .pi / 180)
    }
}
