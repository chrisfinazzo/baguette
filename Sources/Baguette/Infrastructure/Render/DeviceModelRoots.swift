import Foundation

enum DeviceModelRoots {
    static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> [URL] {
        var roots: [URL] = []
        if let override = environment["BAGUETTE_3D_MODEL_DIR"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            roots.append(
                applicationSupport
                    .appending(path: "com.tddworks.baguette")
                    .appending(path: "3d-models")
            )
        }
        if let resources = bundle.resourceURL {
            roots.append(resources.appending(path: "Models3D"))
        }
        return roots
    }
}
