import Testing
import Foundation
@testable import Baguette

@Suite("CameraSourceStaging")
@MainActor
struct CameraSourceStagingTests {

    private func makeStaging() -> CameraSourceStaging {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("camstage-\(UUID().uuidString)", isDirectory: true)
        return CameraSourceStaging(root: root)
    }

    @Test func `staging writes the file and exposes its host path`() throws {
        let staging = makeStaging()
        let url = try staging.stage(udid: "U", filename: "pic.png", data: Data([1, 2, 3]))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(staging.path(udid: "U") == url.path)
        staging.clear(udid: "U")
    }

    @Test func `a new upload replaces the previous staged file`() throws {
        let staging = makeStaging()
        let first = try staging.stage(udid: "U", filename: "a.png", data: Data([1]))
        let second = try staging.stage(udid: "U", filename: "b.mp4", data: Data([2]))
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(staging.path(udid: "U") == second.path)
        staging.clear(udid: "U")
    }

    @Test func `clear removes the staged file and forgets the path`() throws {
        let staging = makeStaging()
        let url = try staging.stage(udid: "U", filename: "pic.png", data: Data([1]))
        staging.clear(udid: "U")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(staging.path(udid: "U") == nil)
    }

    @Test func `each udid stages into its own slot`() throws {
        let staging = makeStaging()
        _ = try staging.stage(udid: "A", filename: "a.png", data: Data([1]))
        _ = try staging.stage(udid: "B", filename: "b.png", data: Data([2]))
        #expect(staging.path(udid: "A") != nil)
        #expect(staging.path(udid: "B") != nil)
        #expect(staging.path(udid: "A") != staging.path(udid: "B"))
        staging.clear(udid: "A")
        staging.clear(udid: "B")
    }

    @Test func `a path-traversal filename is reduced to its last component`() throws {
        let staging = makeStaging()
        let url = try staging.stage(udid: "U", filename: "../../etc/evil.png", data: Data([1]))
        #expect(url.lastPathComponent == "evil.png")
        staging.clear(udid: "U")
    }
}
