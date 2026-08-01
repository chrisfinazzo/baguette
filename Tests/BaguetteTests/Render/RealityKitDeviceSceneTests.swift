import Foundation
import IOSurface
import Testing

@testable import Baguette

@Suite("RealityKitDeviceScene")
struct RealityKitDeviceSceneTests {
    @Test func `successive simulator surfaces produce codec-ready BGRA frames`() throws {
        let scratch = try Self.makeScratch("frames")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plan = try Self.plan(directory: scratch)
        let blue = try #require(Self.surface(red: 0, green: 0, blue: 255))
        let red = try #require(Self.surface(red: 255, green: 0, blue: 0))
        let scene = try RealityKitDeviceScene(plan: plan)

        let blueFrame = try scene.render(screen: blue)
        let redFrame = try scene.render(screen: red)

        #expect(IOSurfaceGetWidth(blueFrame) == 320)
        #expect(IOSurfaceGetHeight(blueFrame) == 240)
        #expect(Self.bytes(blueFrame) != Self.bytes(redFrame))
    }

    @Test func `camera updates change the next frame without rebuilding the scene`() throws {
        let scratch = try Self.makeScratch("camera")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try RealityKitDeviceScene(plan: Self.plan(directory: scratch))

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
        let scratch = try Self.makeScratch("buffer-pool")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try RealityKitDeviceScene(plan: Self.plan(directory: scratch))
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
        let scratch = try Self.makeScratch("color")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try RealityKitDeviceScene(plan: Self.plan(
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

    @Test func `screen frame renders upright, not mirrored vertically`() throws {
        let scratch = try Self.makeScratch("upright")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let scene = try RealityKitDeviceScene(plan: Self.plan(
            directory: scratch,
            rotation: .zero
        ))
        let split = try #require(Self.verticallySplitSurface(
            top: (red: 200, green: 30, blue: 30),
            bottom: (red: 30, green: 30, blue: 200)
        ))

        let frame = try scene.render(screen: split)
        let upper = Self.pixel(frame, x: 160, y: 70)
        let lower = Self.pixel(frame, x: 160, y: 170)

        #expect(upper.red > upper.blue)
        #expect(lower.blue > lower.red)
    }

    @Test func `steep poses draw the screen content edge with blended coverage`() throws {
        let scratch = try Self.makeScratch("edge-aa")
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Pitch + yaw make the screen edge diagonal in image space; the
        // engine's MSAA skips the unlit screen pass, so edge coverage
        // must come from supersampling.
        let scene = try RealityKitDeviceScene(plan: Self.plan(
            directory: scratch,
            rotation: DeviceRotation(x: -20, y: 40, z: 0)
        ))
        let white = try #require(Self.surface(red: 255, green: 255, blue: 255))

        let frame = try scene.render(screen: white)

        var rowsWithEdge = 0
        var rowsWithBlend = 0
        for y in stride(from: 40, through: 200, by: 4) {
            guard let edge = Self.darkToBrightTransition(frame, y: y) else { continue }
            rowsWithEdge += 1
            if edge.intermediates > 0 { rowsWithBlend += 1 }
        }
        #expect(rowsWithEdge > 20)
        #expect(rowsWithBlend * 10 >= rowsWithEdge * 7)
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
        let scene = try RealityKitDeviceScene(plan: DeviceRenderPlan.build(
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

    @Test func `deep blue variant replaces body textures instead of tinting them`() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let models = try LiveDeviceModels(rootURLs: [
            repository.appending(path: "Sources/Baguette/Resources/Models3D")
        ])
        let model = try #require(try models.find(id: "iphone-17-pro-max"))
        let plan = try DeviceRenderPlan.build(
            model: model,
            variants: ["finish": "deep-blue"],
            rotation: DeviceRotation(x: 0, y: 180, z: 0),
            outputSize: RenderDimensions(width: 240, height: 480),
            background: .color("#FFFFFF")
        )
        let scene = try RealityKitDeviceScene(plan: plan)

        let frame = try scene.render(screen: try #require(Self.surface(
            red: 0, green: 0, blue: 0
        )))

        // The camera plateau (upper back) must read blue-gray, not the
        // muddy brown a tint multiplied into the orange base texture makes.
        let plateau = Self.pixel(frame, x: 120, y: 100)
        #expect(plateau.blue >= plateau.red)
    }
}

private extension RealityKitDeviceSceneTests {
    static func makeScratch(_ label: String) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-rk-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try RealityKitRenderFixtures.deviceUSDA.write(
            to: scratch.appending(path: "device.usda"),
            atomically: true,
            encoding: .utf8
        )
        return scratch
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
                asset: DeviceModelAsset(file: "device.usda", downloadURL: nil, sha256: nil),
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
        filledSurface { _, _ in (red, green, blue) }
    }

    static func verticallySplitSurface(
        top: (red: UInt8, green: UInt8, blue: UInt8),
        bottom: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> IOSurface? {
        filledSurface { _, y in y < 100 ? top : bottom }
    }

    static func filledSurface(
        _ color: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8)
    ) -> IOSurface? {
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
        for y in 0..<200 {
            for x in 0..<100 {
                let pixel = color(x, y)
                let offset = y * 400 + x * 4
                bytes[offset] = pixel.blue
                bytes[offset + 1] = pixel.green
                bytes[offset + 2] = pixel.red
                bytes[offset + 3] = 255
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }

    /// Finds the first dark→bright transition in a row and counts pixels
    /// strictly between the dark and bright plateaus — antialiased edge
    /// coverage. Returns nil when the row has no qualifying edge.
    static func darkToBrightTransition(
        _ surface: IOSurface,
        y: Int
    ) -> (x: Int, intermediates: Int)? {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let address = IOSurfaceGetBaseAddress(surface)
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface)
        func lum(_ x: Int) -> Int {
            let offset = y * rowBytes + x * 4
            return (Int(address[offset]) + Int(address[offset + 1])
                + Int(address[offset + 2])) / 3
        }
        var x = 8
        while x < width - 8 {
            if lum(x) < 110, lum(x + 1) >= 110 {
                var probe = x + 1
                var intermediates = 0
                while probe < width, lum(probe) < 230, probe - x <= 8 {
                    intermediates += 1
                    probe += 1
                }
                if probe < width, lum(probe) >= 230 {
                    return (x, intermediates)
                }
            }
            x += 1
        }
        return nil
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
