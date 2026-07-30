import AppKit
import Foundation
import SceneKit

struct SceneKitDeviceRenderer: DeviceRenderer, Sendable {
    private let assets: VerifiedDeviceAssets

    init(assets: VerifiedDeviceAssets = VerifiedDeviceAssets()) {
        self.assets = assets
    }

    func render(plan: DeviceRenderPlan, screenImage: Data) throws -> Data {
        let assetURL = try assets.resolve(plan.model)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sceneURL = try preparedSceneURL(
            assetURL: assetURL,
            selections: plan.variants,
            scratch: scratch
        )
        guard let sourceScene = try? SCNScene(url: sceneURL, options: nil) else {
            throw DeviceModelError.sceneLoadFailed(assetURL.path)
        }
        let definition = plan.model.definition
        guard let subject = sourceScene.rootNode.childNode(
            withName: definition.scene.rootNode,
            recursively: true
        ) else {
            throw DeviceModelError.sceneNodeNotFound(definition.scene.rootNode)
        }
        guard let screenNode = findScreenNode(
            under: subject,
            explicitName: definition.scene.screenNode,
            materialName: definition.scene.screenMaterial
        ) else {
            throw DeviceModelError.sceneNodeNotFound(
                definition.scene.screenNode ?? definition.scene.screenMaterial
            )
        }
        guard let sourceImage = NSImage(data: screenImage) else {
            throw DeviceModelError.screenImageInvalid
        }
        let texture = fittedTexture(
            sourceImage,
            target: definition.scene.textureSize,
            fit: plan.fit
        )
        replaceMaterial(
            on: screenNode,
            named: definition.scene.screenMaterial,
            texture: texture
        )

        let scene = SCNScene()
        scene.background.contents = backgroundColor(plan.background)
        let wrapper = SCNNode()
        wrapper.name = "baguette-device"
        subject.removeFromParentNode()
        wrapper.addChildNode(subject)
        scene.rootNode.addChildNode(wrapper)
        wrapper.eulerAngles = SCNVector3(
            radians(plan.rotation.x),
            radians(plan.rotation.y),
            radians(plan.rotation.z)
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
        camera.orthographicScale = max(height, width / aspect) * 1.18
        camera.zNear = 0.001
        camera.zFar = max(1000, depth * 100)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Float(max(width, height) + depth + 10))
        scene.rootNode.addChildNode(cameraNode)
        addLights(to: scene)

        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(
            atTime: 0,
            with: CGSize(width: plan.outputSize.width, height: plan.outputSize.height),
            antialiasingMode: .multisampling4X
        )
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DeviceModelError.renderFailed
        }
        return png
    }

    private func preparedSceneURL(
        assetURL: URL,
        selections: [DeviceVariantSelection],
        scratch: URL
    ) throws -> URL {
        guard !selections.isEmpty else { return assetURL }
        let stagedName = "device.\(assetURL.pathExtension)"
        let stagedAsset = scratch.appending(path: stagedName)
        try FileManager.default.createSymbolicLink(
            at: stagedAsset,
            withDestinationURL: assetURL
        )
        let overlay = try USDVariantOverlay.make(
            assetReference: stagedName,
            selections: selections
        )
        let overlayURL = scratch.appending(path: "variants.usda")
        try overlay.write(to: overlayURL, atomically: true, encoding: .utf8)
        return overlayURL
    }

    private func findScreenNode(
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

    private func replaceMaterial(on node: SCNNode, named name: String, texture: NSImage) {
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

    private func fittedTexture(
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

    private func backgroundColor(_ background: DeviceRenderBackground) -> NSColor {
        switch background {
        case .transparent:
            return .clear
        case .color(let hex):
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return NSColor(
                red: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
        }
    }

    private func addLights(to scene: SCNScene) {
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

    private func radians(_ degrees: Double) -> Float {
        Float(degrees * .pi / 180)
    }
}
