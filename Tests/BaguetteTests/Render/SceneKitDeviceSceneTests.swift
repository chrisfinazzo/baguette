import Foundation
import IOSurface
import SceneKit
import Testing
@testable import Baguette

@Suite("SceneKitDeviceScene")
struct SceneKitDeviceSceneTests {
    @Test func `successive simulator surfaces produce codec-ready BGRA frames`() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeScene(to: scratch.appending(path: "device.scn"))
        let plan = try Self.plan(directory: scratch)
        let blue = try #require(Self.surface(red: 0, green: 0, blue: 255))
        let red = try #require(Self.surface(red: 255, green: 0, blue: 0))
        let scene = try SceneKitDeviceScene(plan: plan, quality: 0.75)

        let blueFrame = try scene.render(screen: blue)
        let redFrame = try scene.render(screen: red)

        #expect(IOSurfaceGetWidth(blueFrame) == 320)
        #expect(IOSurfaceGetHeight(blueFrame) == 240)
        #expect(Self.bytes(blueFrame) != Self.bytes(redFrame))
    }

    @Test func `camera updates change the next frame without rebuilding the scene`() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-camera-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeScene(to: scratch.appending(path: "device.scn"))
        let scene = try SceneKitDeviceScene(plan: Self.plan(directory: scratch))

        let before = try scene.render(screen: try #require(Self.surface(
            red: 0, green: 0, blue: 255
        )))
        scene.update(camera: Device3DCamera(
            rotation: DeviceRotation(x: 0, y: 40, z: 0),
            zoom: 1.4
        ))
        let after = try scene.render(screen: try #require(Self.surface(
            red: 0, green: 0, blue: 255
        )))

        #expect(Self.bytes(after) != Self.bytes(before))
        #expect(Self.seed(after) > 1)
    }

    @Test func `live rendering reuses a bounded triple buffer`() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-buffer-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeScene(to: scratch.appending(path: "device.scn"))
        let scene = try SceneKitDeviceScene(plan: Self.plan(directory: scratch))
        let screen = try #require(Self.surface(red: 24, green: 48, blue: 96))

        var surfaceIDs: [IOSurfaceID] = []
        for turn in 0..<9 {
            scene.update(camera: Device3DCamera(
                rotation: DeviceRotation(x: 0, y: Double(turn * 5), z: 0),
                zoom: 1
            ))
            surfaceIDs.append(IOSurfaceGetID(try scene.render(screen: screen)))
        }

        #expect(Set(surfaceIDs.prefix(3)).count == 3)
        #expect(Set(surfaceIDs).count == 3)
    }

    @Test func `screen material preserves simulator midtones without additive clipping`() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Self.writeScene(to: scratch.appending(path: "device.scn"))
        let scene = try SceneKitDeviceScene(plan: Self.plan(
            directory: scratch,
            rotation: .zero
        ))
        let gray = try #require(Self.surface(red: 96, green: 96, blue: 96))

        let frame = try scene.render(screen: gray)
        let pixel = Self.pixel(frame, x: 160, y: 120)

        #expect((75...125).contains(Int(pixel.red)))
        #expect(abs(Int(pixel.red) - Int(pixel.green)) <= 2)
        #expect(abs(Int(pixel.green) - Int(pixel.blue)) <= 2)
    }

    @Test func `live render preserves the authored cosmic orange color space`() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let models = try LiveDeviceModels(rootURLs: [
            repository.appending(path: "Sources/Baguette/Resources/Models3D")
        ])
        let model = try #require(try models.find(id: "iphone-17-pro-max"))
        let scene = try SceneKitDeviceScene(plan: DeviceRenderPlan.build(
            model: model,
            variants: ["finish": "cosmic-orange"],
            rotation: DeviceRotation(x: -8, y: 158, z: 0),
            outputSize: RenderDimensions(width: 480, height: 480),
            background: .color("#EEF1F5")
        ))

        let frame = try scene.render(screen: try #require(Self.surface(
            red: 0, green: 0, blue: 0
        )))

        #expect(Self.saturatedRedPixelCount(frame) < 4_000)
    }

    @Test func `deep blue variant recolors texture backed body panels`() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let models = try LiveDeviceModels(rootURLs: [
            repository.appending(path: "Sources/Baguette/Resources/Models3D")
        ])
        let model = try #require(try models.find(id: "iphone-17-pro-max"))
        let deepBlue = try #require(
            model.definition.resolveVariants(["finish": "deep-blue"]).first
        )

        #expect(deepBlue.materialColors["SMUhrjUPCjJkPUK"] == "#5B627C")
        #expect(deepBlue.materialColors["HETovHCBsEjcSiP"] == "#5B627C")
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

    static func plan(
        directory: URL,
        rotation: DeviceRotation = DeviceRotation(x: -8, y: 18, z: 0)
    ) throws -> DeviceRenderPlan {
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
            rotation: rotation,
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

    static func bytes(_ surface: IOSurface) -> Data {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        return Data(
            bytes: IOSurfaceGetBaseAddress(surface),
            count: IOSurfaceGetAllocSize(surface)
        )
    }

    static func seed(_ surface: IOSurface) -> UInt32 {
        var seed: UInt32 = 0
        IOSurfaceLock(surface, .readOnly, &seed)
        IOSurfaceUnlock(surface, .readOnly, nil)
        return seed
    }

    static func pixel(
        _ surface: IOSurface,
        x: Int,
        y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let address = IOSurfaceGetBaseAddress(surface)
            .assumingMemoryBound(to: UInt8.self)
        let offset = y * IOSurfaceGetBytesPerRow(surface) + x * 4
        return (address[offset + 2], address[offset + 1], address[offset])
    }

    static func saturatedRedPixelCount(_ surface: IOSurface) -> Int {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let bytes = IOSurfaceGetBaseAddress(surface)
            .assumingMemoryBound(to: UInt8.self)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let blue = bytes[offset]
                let green = bytes[offset + 1]
                let red = bytes[offset + 2]
                if red >= 252 && Int(red) - Int(green) > 45
                    && Int(red) - Int(blue) > 45 {
                    count += 1
                }
            }
        }
        return count
    }
}
