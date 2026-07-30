import AppKit
import Foundation
import ImageIO
import SceneKit
import Testing
@testable import Baguette

@Suite("SceneKitDeviceRenderer")
struct SceneKitDeviceRendererTests {

    @Test func `renders a generated device scene to requested PNG dimensions`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sceneURL = scratch.appending(path: "device.scn")
        try Self.writeScene(to: sceneURL)
        let plan = try Self.plan(directory: scratch, file: "device.scn")
        let screen = try Self.screenPNG()

        let png = try SceneKitDeviceRenderer().render(plan: plan, screenImage: screen)

        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 240)
    }

    @Test func `reports the declared local asset when it is missing`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let plan = try Self.plan(directory: scratch, file: "missing.usdz")

        #expect(throws: DeviceModelError.localAssetNotFound("missing.usdz")) {
            _ = try SceneKitDeviceRenderer().render(
                plan: plan,
                screenImage: Data("not reached".utf8)
            )
        }
    }

    @Test func `material appearance variant changes rendered device finish`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sceneURL = scratch.appending(path: "device.scn")
        try Self.writeScene(to: sceneURL)
        let orange = try Self.plan(
            directory: scratch, file: "device.scn", finish: "orange"
        )
        let blue = try Self.plan(
            directory: scratch, file: "device.scn", finish: "blue"
        )
        let screen = try Self.screenPNG()

        let orangePNG = try SceneKitDeviceRenderer().render(
            plan: orange, screenImage: screen
        )
        let bluePNG = try SceneKitDeviceRenderer().render(
            plan: blue, screenImage: screen
        )

        #expect(orangePNG != bluePNG)
    }
}

private extension SceneKitDeviceRendererTests {
    static func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "baguette-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeScene(to url: URL) throws {
        let scene = SCNScene()
        let device = SCNNode(geometry: SCNBox(
            width: 2.2, height: 4.4, length: 0.2, chamferRadius: 0.15
        ))
        device.name = "Device"
        device.geometry?.firstMaterial?.name = "DeviceBody"
        device.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray

        let screenMaterial = SCNMaterial()
        screenMaterial.name = "ScreenMaterial"
        screenMaterial.diffuse.contents = NSColor.black
        let screen = SCNNode(geometry: SCNPlane(width: 1.9, height: 3.9))
        screen.name = "Screen"
        screen.geometry?.materials = [screenMaterial]
        screen.position = SCNVector3(0, 0, 0.11)
        device.addChildNode(screen)
        scene.rootNode.addChildNode(device)

        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func screenPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 100, height: 200))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 200)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return png
    }

    static func plan(
        directory: URL,
        file: String,
        finish: String? = nil
    ) throws -> DeviceRenderPlan {
        let model = InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "test-device",
                displayName: "Test Device",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(file: file, downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "ScreenMaterial",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: finish == nil ? [] : [
                    DeviceVariantSet(
                        id: "finish",
                        displayName: "Finish",
                        primPath: "/Device",
                        usdName: "Finish",
                        default: "orange",
                        choices: [
                            DeviceVariantChoice(
                                id: "orange",
                                displayName: "Orange",
                                usdValue: "Orange",
                                previewColor: "#ff6600",
                                materialColors: ["DeviceBody": "#ff6600"]
                            ),
                            DeviceVariantChoice(
                                id: "blue",
                                displayName: "Blue",
                                usdValue: "Blue",
                                previewColor: "#334477",
                                materialColors: ["DeviceBody": "#334477"]
                            ),
                        ],
                        kind: .materials
                    ),
                ]
            ),
            directoryURL: directory
        )
        return try DeviceRenderPlan.build(
            model: model,
            variants: finish.map { ["finish": $0] } ?? [:],
            rotation: DeviceRotation(x: -8, y: 18, z: 0),
            outputSize: RenderDimensions(width: 320, height: 240)
        )
    }
}
