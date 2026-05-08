import ArgumentParser
import Foundation

/// `baguette orientation --udid <UDID> <portrait|landscape-left|landscape-right|portrait-upside-down>`
///
/// Sends a `GSEventTypeDeviceOrientationChanged` Purple event to the
/// booted simulator so the iOS guest sees `UIDeviceOrientationDidChange`
/// and rotates the UIKit world. Wire format documented in
/// `Domain/Orientation/OrientationEvent.swift`; the actual mach IPC
/// is in `Infrastructure/Orientation/PurpleEventOrientation.swift`.
struct OrientationCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orientation",
        abstract: "Set the booted simulator's interface orientation"
    )

    @OptionGroup var options: DeviceOption

    @Argument(help: "Target orientation: portrait, landscape-left, landscape-right, portrait-upside-down")
    var value: DeviceOrientation

    func run() {
        let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
        guard let simulator = simulators.find(udid: options.udid) else {
            log("Device \(options.udid) not found")
            Foundation.exit(1)
        }
        guard simulator.canAcceptInput else {
            log("Device \(simulator.name) is not booted")
            Foundation.exit(1)
        }
        guard simulator.orientation().set(value) else {
            log("Orientation change rejected (PurpleWorkspacePort unreachable?)")
            Foundation.exit(1)
        }
        log("Set \(simulator.name) → \(value.cliName)")
    }
}

extension DeviceOrientation: ExpressibleByArgument {
    /// Accept the kebab-case spellings the CLI exposes; reject anything
    /// else with ArgumentParser's standard usage message.
    public init?(argument: String) {
        switch argument {
        case "portrait":             self = .portrait
        case "portrait-upside-down": self = .portraitUpsideDown
        case "landscape-left":       self = .landscapeLeft
        case "landscape-right":      self = .landscapeRight
        default: return nil
        }
    }

    /// Reverse of `init(argument:)` — used to echo the chosen value
    /// back to the user in `OrientationCommand.run()`.
    fileprivate var cliName: String {
        switch self {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft:      return "landscape-left"
        case .landscapeRight:     return "landscape-right"
        }
    }
}
