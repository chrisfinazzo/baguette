import AppKit
import Foundation
import IOSurface
import Metal
import SceneKit

/// Persistent SceneKit adapter for one live 3D stream connection.
///
/// Model resolution, variant authoring, scene loading, camera, and lighting
/// happen once. Per simulator frame only the screen texture and snapshot are
/// updated.
final class SceneKitDeviceScene: DeviceScene, @unchecked Sendable {
    private let plan: DeviceRenderPlan
    private let scene: SCNScene
    private let screenNode: SCNNode
    private let wrapperNode: SCNNode
    private let camera: SCNCamera
    private let baseCameraScale: Double
    private let renderer: SCNRenderer
    private let metalDevice: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let depthTexture: any MTLTexture
    private let scratch: URL
    private let lock = NSLock()

    init(
        plan: DeviceRenderPlan,
        quality _: Double = 0.7,
        assets: VerifiedDeviceAssets = VerifiedDeviceAssets()
    ) throws {
        self.plan = plan
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
            wrapperNode = wrapper
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
            camera.wantsHDR = true
            camera.wantsExposureAdaptation = false
            baseCameraScale = camera.orthographicScale
            self.camera = camera
            camera.zNear = 0.001
            camera.zFar = max(1000, depth * 100)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(
                0, 0, Float(max(width, height) + depth + 10)
            )
            output.rootNode.addChildNode(cameraNode)
            DeviceStudioLighting.apply(to: output)
            scene = output

            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else {
                throw DeviceModelError.renderFailed
            }
            metalDevice = device
            commandQueue = queue
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: plan.outputSize.width,
                height: plan.outputSize.height,
                mipmapped: false
            )
            depthDescriptor.storageMode = .private
            depthDescriptor.usage = .renderTarget
            guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
                throw DeviceModelError.renderFailed
            }
            self.depthTexture = depthTexture

            let sceneRenderer = SCNRenderer(device: device, options: nil)
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

    func render(screen surface: IOSurface) throws -> IOSurface {
        try lock.withLock {
            let texture = try inputTexture(from: surface)
            Self.replaceMaterial(
                on: screenNode,
                named: plan.model.definition.scene.screenMaterial,
                texture: texture,
                source: RenderDimensions(
                    width: IOSurfaceGetWidth(surface),
                    height: IOSurfaceGetHeight(surface)
                ),
                target: plan.model.definition.scene.textureSize,
                fit: plan.fit
            )
            SCNTransaction.flush()
            return try renderSurface()
        }
    }

    private func inputTexture(from surface: IOSurface) throws -> any MTLTexture {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = metalDevice.makeTexture(descriptor: descriptor) else {
            throw DeviceModelError.screenImageInvalid
        }
        IOSurfaceLock(surface, .readOnly, nil)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: IOSurfaceGetBaseAddress(surface),
            bytesPerRow: IOSurfaceGetBytesPerRow(surface)
        )
        IOSurfaceUnlock(surface, .readOnly, nil)
        return texture
    }

    private func renderSurface() throws -> IOSurface {
        let width = plan.outputSize.width
        let height = plan.outputSize.height
        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        guard let surface = IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * height,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary) else {
            throw DeviceModelError.renderFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let output = metalDevice.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ), let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DeviceModelError.renderFailed
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor(plan.background)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        renderer.render(
            atTime: 0,
            viewport: CGRect(x: 0, y: 0, width: width, height: height),
            commandBuffer: commandBuffer,
            passDescriptor: pass
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw DeviceModelError.renderFailed
        }
        return surface
    }

    func update(camera requested: Device3DCamera) {
        lock.withLock {
            wrapperNode.eulerAngles = SCNVector3(
                Self.radians(requested.rotation.x),
                Self.radians(requested.rotation.y),
                Self.radians(requested.rotation.z)
            )
            camera.orthographicScale = baseCameraScale / requested.zoom
        }
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
        texture: any MTLTexture,
        source: RenderDimensions,
        target: RenderDimensions,
        fit: DeviceScreenFit
    ) {
        guard let geometry = node.geometry else { return }
        geometry.materials = geometry.materials.map { existing in
            guard existing.name == name else { return existing }
            let material = existing.copy() as? SCNMaterial ?? SCNMaterial()
            material.name = existing.name
            material.diffuse.contents = texture
            let transform = textureTransform(source: source, target: target, fit: fit)
            material.diffuse.contentsTransform = transform
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.magnificationFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.mipFilter = .linear
            material.emission.contents = NSColor.black
            material.emission.intensity = 0
            material.lightingModel = .constant
            return material
        }
    }

    private static func textureTransform(
        source: RenderDimensions,
        target: RenderDimensions,
        fit: DeviceScreenFit
    ) -> SCNMatrix4 {
        guard fit != .stretch else { return SCNMatrix4Identity }
        let sourceAspect = Double(source.width) / Double(source.height)
        let targetAspect = Double(target.width) / Double(target.height)
        var scaleX = 1.0
        var scaleY = 1.0
        if (fit == .cover) == (sourceAspect > targetAspect) {
            scaleX = targetAspect / sourceAspect
        } else {
            scaleY = sourceAspect / targetAspect
        }
        let translation = SCNMatrix4MakeTranslation(
            CGFloat((1 - scaleX) / 2),
            CGFloat((1 - scaleY) / 2),
            0
        )
        return SCNMatrix4Mult(
            SCNMatrix4MakeScale(CGFloat(scaleX), CGFloat(scaleY), 1),
            translation
        )
    }

    private static func clearColor(
        _ background: DeviceRenderBackground
    ) -> MTLClearColor {
        let color = backgroundColor(background).usingColorSpace(.deviceRGB) ?? .clear
        return MTLClearColor(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
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

    private static func radians(_ degrees: Double) -> Float {
        Float(degrees * .pi / 180)
    }
}
