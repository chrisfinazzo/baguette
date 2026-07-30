import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("Server 3D render routes")
struct Render3DRoutesTests {

    @Test func `render3D resolves simulator model and invokes renderer`() throws {
        let (simulators, simulator, models, installed) = Self.fixture()
        let renderer = MockDeviceRenderer()
        given(renderer).render(plan: .any, screenImage: .value(Data("SCREEN".utf8)))
            .willReturn(Data("PNG".utf8))

        let outcome = Server.render3D(
            udid: "U",
            options: DeviceRenderOptions(
                rotation: DeviceRotation(x: 1, y: 2, z: 3),
                variants: ["finish": "silver"],
                size: RenderDimensions(width: 800, height: 600),
                fit: .contain,
                background: .transparent
            ),
            screenImage: Data("SCREEN".utf8),
            sourceSize: RenderDimensions(width: 100, height: 200),
            simulators: simulators,
            models: models,
            renderer: renderer
        )

        #expect(outcome == .rendered(Data("PNG".utf8)))
        verify(models).match(
            deviceType: .value("iPhone 17 Pro"),
            deviceName: .value("Demo")
        ).called(1)
        verify(renderer).render(
            plan: .matching {
                $0.model == installed
                    && $0.outputSize == RenderDimensions(width: 800, height: 600)
                    && $0.variants.map(\.usdValue) == ["Silver"]
            },
            screenImage: .value(Data("SCREEN".utf8))
        ).called(1)
        _ = simulator
    }

    @Test func `render3D reports unknown simulator without consulting models`() {
        let simulators = MockSimulators()
        let models = MockDeviceModels()
        let renderer = MockDeviceRenderer()
        given(simulators).find(udid: .value("ghost")).willReturn(nil)

        let outcome = Server.render3D(
            udid: "ghost",
            options: Self.defaults,
            screenImage: Data(),
            sourceSize: RenderDimensions(width: 100, height: 200),
            simulators: simulators,
            models: models,
            renderer: renderer
        )

        #expect(outcome == .unknownDevice)
    }

    @Test func `model metadata exposes only public ids and choices`() throws {
        let (simulators, _, models, _) = Self.fixture()

        let json = try #require(Server.model3DJSONString(
            udid: "U",
            simulators: simulators,
            models: models
        ))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["id"] as? String == "iphone")
        let sets = try #require(object["variantSets"] as? [[String: Any]])
        let firstSet = try #require(sets.first)
        #expect(firstSet["id"] as? String == "finish")
        let choices = try #require(firstSet["choices"] as? [[String: Any]])
        #expect(choices.compactMap { $0["id"] as? String } == ["black", "silver"])
        #expect(json.contains("primPath") == false)
        #expect(json.contains("usdName") == false)
        #expect(json.contains("usdValue") == false)
    }
}

private extension Render3DRoutesTests {
    static var defaults: DeviceRenderOptions {
        DeviceRenderOptions(
            rotation: .zero,
            variants: [:],
            size: nil,
            fit: .cover,
            background: .transparent
        )
    }

    static func fixture() -> (
        MockSimulators, MockSimulator, MockDeviceModels, InstalledDeviceModel
    ) {
        let installed = InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "iphone",
                displayName: "iPhone",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(file: "device.usdz", downloadURL: nil, sha256: nil),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: [
                    DeviceVariantSet(
                        id: "finish",
                        displayName: "Finish",
                        primPath: "/Device",
                        usdName: "Color",
                        default: "black",
                        choices: [
                            DeviceVariantChoice(
                                id: "black", displayName: "Black",
                                usdValue: "Black", previewColor: "#000000"
                            ),
                            DeviceVariantChoice(
                                id: "silver", displayName: "Silver",
                                usdValue: "Silver", previewColor: "#cccccc"
                            ),
                        ]
                    )
                ]
            ),
            directoryURL: URL(fileURLWithPath: "/models/iphone")
        )
        let simulator = MockSimulator()
        given(simulator).deviceTypeName.willReturn("iPhone 17 Pro")
        given(simulator).name.willReturn("Demo")
        let simulators = MockSimulators()
        given(simulators).find(udid: .value("U")).willReturn(simulator)
        let models = MockDeviceModels()
        given(models).match(deviceType: .any, deviceName: .any).willReturn(installed)
        return (simulators, simulator, models, installed)
    }
}
