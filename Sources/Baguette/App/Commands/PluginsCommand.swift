import ArgumentParser
import Foundation

/// `baguette plugin <list|show|validate|run>`
///
/// Named `PluginsCommand` because it operates on the installed
/// collection; the CLI verb stays singular (`baguette plugin …`) to
/// match `git remote` / `docker plugin`. The Domain's `PluginCommand`
/// is a different thing — one contribution inside a manifest.
struct PluginsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Inspect and run installed plugins",
        subcommands: [List.self, Show.self, Validate.self, Run.self]
    )

    /// Shared `--plugin-dir` for local authoring: point baguette at a
    /// directory of plugins without installing them. Mirrors Claude
    /// Code's own flag, which is the difference between a plugin
    /// system people can iterate against and one they can't.
    struct RootsOption: ParsableArguments {
        @Option(
            name: .customLong("plugin-dir"),
            help: "Extra directory of plugins; repeatable. Shadows installed plugins of the same name."
        )
        var pluginDirs: [String] = []

        var plugins: FileSystemPlugins {
            FileSystemPlugins.standard(
                extraRoots: pluginDirs.map { URL(fileURLWithPath: $0) }
            )
        }
    }

    // MARK: - subcommands

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List installed plugins"
        )

        @OptionGroup var roots: RootsOption

        func run() throws {
            print(PluginsCommand.listing(try roots.plugins.all()))
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print what a plugin contributes, without running it"
        )

        @OptionGroup var roots: RootsOption
        @Argument(help: "Plugin name.") var name: String

        func run() throws {
            guard let plugin = try roots.plugins.plugin(named: name) else {
                log("No plugin named \(name)")
                throw ExitCode.failure
            }
            print(PluginsCommand.detail(plugin))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Check a plugin directory's manifest and say what's wrong"
        )

        @Argument(help: "Path to the plugin directory.") var path: String

        func run() throws {
            let manifest = URL(fileURLWithPath: path)
                .appendingPathComponent(FileSystemPlugins.manifestFilename)
            guard let data = try? Data(contentsOf: manifest) else {
                log("No \(FileSystemPlugins.manifestFilename) at \(path)")
                throw ExitCode.failure
            }
            switch PluginsCommand.validate(json: data) {
            case .valid(let name, let commands, let panels):
                print("\(name) is valid — \(commands) command(s), \(panels) panel(s)")
            case .invalid(let reason):
                log("Invalid manifest: \(reason)")
                throw ExitCode.failure
            }
        }
    }

    /// `baguette plugin run a11y:audit --udid <UDID>`
    ///
    /// The same path the serve route takes, so a plugin can be
    /// developed and debugged entirely from the terminal before any
    /// browser is involved.
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "Run a plugin command by its namespaced id"
        )

        @OptionGroup var roots: RootsOption
        @Argument(help: "Namespaced command id, e.g. a11y:audit.") var command: String
        @Option(help: "Device the command targets.") var udid: String?
        @Option(help: "Origin of a running `baguette serve`.")
        var url: String = "http://127.0.0.1:8421"

        func run() async throws {
            let outcome = await PluginDispatch.run(
                qualifiedCommand: command,
                context: PluginDispatch.Context(
                    serverURL: url,
                    udid: udid,
                    // No serve session to mint against from the CLI;
                    // the plugin API rejects this, which is correct —
                    // a CLI-run plugin should be pointed at a real
                    // server with `--url` and its printed token.
                    token: ProcessInfo.processInfo.environment["BAGUETTE_TOKEN"] ?? ""
                ),
                plugins: roots.plugins
            )
            switch outcome {
            case .ok(let result):
                print(result.json)
                if !result.ok { throw ExitCode.failure }
            default:
                log(outcome.errorText ?? "plugin failed")
                throw ExitCode.failure
            }
        }
    }

    // MARK: - text projections (pure)

    static func listing(_ plugins: [Plugin]) -> String {
        guard !plugins.isEmpty else {
            return """
                No plugins installed.

                Plugins are directories containing \(FileSystemPlugins.manifestFilename), \
                discovered from:
                  ~/.baguette/plugins/        installed
                  ./.baguette/plugins/        checked into this repo
                  --plugin-dir <path>         local authoring
                """
        }
        return plugins.map { plugin in
            let contributions = [
                plugin.manifest.commands.isEmpty
                    ? nil : "\(plugin.manifest.commands.count) command(s)",
                plugin.manifest.panels.isEmpty
                    ? nil : "\(plugin.manifest.panels.count) panel(s)",
            ].compactMap { $0 }.joined(separator: ", ")
            let summary = plugin.manifest.description.map { " — \($0)" } ?? ""
            return "\(plugin.id)  \(plugin.manifest.version)  \(contributions)\(summary)"
        }.joined(separator: "\n")
    }

    static func detail(_ plugin: Plugin) -> String {
        var lines = ["\(plugin.id) \(plugin.manifest.version)"]
        if let description = plugin.manifest.description { lines.append(description) }
        lines.append("root: \(plugin.root.path)")

        if !plugin.manifest.commands.isEmpty {
            lines.append("")
            lines.append("commands:")
            for command in plugin.manifest.commands {
                lines.append(
                    "  \(plugin.qualified(command.id))  \(command.title)"
                    + "  [\(command.run.joined(separator: " "))]"
                )
            }
        }
        if !plugin.manifest.panels.isEmpty {
            lines.append("")
            lines.append("panels:")
            for panel in plugin.manifest.panels {
                let when = panel.when.map { " when \($0.rawValue)" } ?? ""
                lines.append("  \(plugin.qualified(panel.id))  \(panel.title)  [\(panel.icon.rawValue)]\(when)")
            }
        }
        return lines.joined(separator: "\n")
    }

    enum Validation: Equatable {
        case valid(name: String, commands: Int, panels: Int)
        case invalid(reason: String)
    }

    static func validate(json data: Data) -> Validation {
        do {
            let manifest = try PluginManifest.parsing(json: data)
            return .valid(
                name: manifest.name,
                commands: manifest.commands.count,
                panels: manifest.panels.count
            )
        } catch let error as PluginManifestError {
            return .invalid(reason: error.description)
        } catch {
            return .invalid(reason: "\(error)")
        }
    }
}

