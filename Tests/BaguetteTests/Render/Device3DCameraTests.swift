import Foundation
import Testing
@testable import Baguette

@Suite("Device3DCamera")
struct Device3DCameraTests {
    @Test func `parses a live camera control envelope`() throws {
        let camera = try #require(try Device3DCamera.parsing(json: Data(#"""
        {
          "type": "set_3d_camera",
          "rotation": {"x": -12, "y": 31, "z": 2},
          "zoom": 1.25
        }
        """#.utf8)))

        #expect(camera == Device3DCamera(
            rotation: DeviceRotation(x: -12, y: 31, z: 2),
            zoom: 1.25
        ))
    }

    @Test func `ignores envelopes owned by another control`() throws {
        #expect(try Device3DCamera.parsing(
            json: Data(#"{"type":"set_fps","fps":30}"#.utf8)
        ) == nil)
    }

    @Test func `rejects unsafe rotation and zoom values`() {
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DCamera.parsing(json: Data(#"""
            {
              "type": "set_3d_camera",
              "rotation": {"x": 91, "y": 0, "z": 0},
              "zoom": 1
            }
            """#.utf8))
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            _ = try Device3DCamera.parsing(json: Data(#"""
            {
              "type": "set_3d_camera",
              "rotation": {"x": 0, "y": 0, "z": 0},
              "zoom": 0
            }
            """#.utf8))
        }
    }

    @Test func `projection serializes ordered screen corners and device size`() {
        let projection = DeviceScreenProjection(
            viewport: RenderDimensions(width: 960, height: 720),
            device: RenderDimensions(width: 402, height: 874),
            corners: [
                DeviceScreenPoint(x: 100, y: 50),
                DeviceScreenPoint(x: 800, y: 70),
                DeviceScreenPoint(x: 780, y: 650),
                DeviceScreenPoint(x: 120, y: 640),
            ]
        )

        #expect(projection.json.contains(#""type":"3d_projection""#))
        #expect(projection.json.contains(#""width":402"#))
        #expect(projection.json.contains(#""x":100"#))
    }
}
