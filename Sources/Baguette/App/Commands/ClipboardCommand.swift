import ArgumentParser
import Foundation

/// `baguette clipboard <get|sync> --udid <UDID>`
///
/// The simulator's pasteboard as a resource: `get` prints its text
/// contents; `sync` copies the host Mac's pasteboard onto the
/// simulator full-fidelity — every representation, images included —
/// which is the path for pasting non-text content. Backed by
/// `xcrun simctl pbpaste | pbsync`; to *put text on* the pasteboard
/// use `baguette paste` (optionally `--no-press`).
struct ClipboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard",
        abstract: "Read the simulator's pasteboard or sync the host's onto it",
        subcommands: [Get.self, Sync.self]
    )

    /// `baguette clipboard get --udid <UDID>`
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print the simulator's pasteboard text to stdout"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
            guard let simulator = simulators.find(udid: options.udid) else {
                log("Device \(options.udid) not found")
                throw ExitCode.failure
            }
            do {
                // Raw, no trailing newline — mirrors `pbpaste` so the
                // output pipes byte-faithfully.
                print(try await simulator.pasteboard().text(), terminator: "")
            } catch {
                log("clipboard get failed: \(error)")
                throw ExitCode.failure
            }
        }
    }

    /// `baguette clipboard sync --udid <UDID>`
    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync",
            abstract: "Copy the host Mac's pasteboard onto the simulator (images included)"
        )

        @OptionGroup var options: DeviceOption

        func run() async throws {
            let simulators = CoreSimulators(deviceSetPath: options.deviceSet)
            guard let simulator = simulators.find(udid: options.udid) else {
                log("Device \(options.udid) not found")
                throw ExitCode.failure
            }
            do {
                try await simulator.pasteboard().syncFromHost()
            } catch {
                log("clipboard sync failed: \(error)")
                throw ExitCode.failure
            }
            log("Synced host pasteboard onto \(simulator.name)")
        }
    }
}
