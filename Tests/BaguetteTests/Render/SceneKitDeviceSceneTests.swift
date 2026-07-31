import Foundation
import ImageIO
import IOSurface
import SceneKit
import Testing
@testable import Baguette

@Suite("SceneKitDeviceScene")
struct SceneKitDeviceSceneTests {
    @Test func `successive simulator surfaces produce live JPEG frames`() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeScene(to: scratch.appending(path: "device.scn"))
        let plan = try Self.plan(directory: scratch)
        let blue = try #require(Self.surface(red: 0, green: 0, blue: 255))
        let red = try #require(Self.surface(red: 255, green: 0, blue: 0))
        let scene = try SceneKitDeviceScene(plan: plan, quality: 0.75)

        let blueJPEG = try scene.render(screen: blue)
        let redJPEG = try scene.render(screen: red)

        #expect(Array(blueJPEG.prefix(2)) == [0xff, 0xd8])
        #expect(blueJPEG != redJPEG)
        #expect(try Self.dimensions(blueJPEG) == RenderDimensions(width: 320, height: 240))
    }
}

private extension SceneKitDeviceSceneTests {
    static func writeScene(to url: URL) throws {
        let scene = SCNScene()
        let body = SCNNode(geometry: SCNBox(
            width: 2.2, height: 4.4, length: 0.2, chamferRadius: 0.15
        ))
        body.name = "Device"
        body.geometry?.firstMaterial?.name = "DeviceBody"
        body.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray
        let material = SCNMaterial()
        material.name = "ScreenMaterial"
        let screen = SCNNode(geometry: SCNPlane(width: 1.9, height: 3.9))
        screen.name = "Screen"
        screen.geometry?.materials = [material]
        screen.position = SCNVector3(0, 0, 0.11)
        body.addChildNode(screen)
        scene.rootNode.addChildNode(body)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func plan(directory: URL) throws -> DeviceRenderPlan {
        let model = InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "live-test",
                displayName: "Live Test",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(file: "device.scn", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "ScreenMaterial",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: []
            ),
            directoryURL: directory
        )
        return try DeviceRenderPlan.build(
            model: model,
            variants: [:],
            rotation: DeviceRotation(x: -8, y: 18, z: 0),
            outputSize: RenderDimensions(width: 320, height: 240),
            background: .color("#eef1f5")
        )
    }

    static func surface(red: UInt8, green: UInt8, blue: UInt8) -> IOSurface? {
        guard let surface = IOSurfaceCreate([
            kIOSurfaceWidth: 100,
            kIOSurfaceHeight: 200,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 400,
            kIOSurfaceAllocSize: 80_000,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary) else { return nil }
        IOSurfaceLock(surface, [], nil)
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        for index in stride(from: 0, to: 80_000, by: 4) {
            bytes[index] = blue
            bytes[index + 1] = green
            bytes[index + 2] = red
            bytes[index + 3] = 255
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }

    static func dimensions(_ jpeg: Data) throws -> RenderDimensions {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return RenderDimensions(
            width: try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            height: try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
