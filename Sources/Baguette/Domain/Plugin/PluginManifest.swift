import Foundation

/// What a plugin says about itself — the contents of its
/// `baguette-plugin.json`. One value describes one installed plugin:
/// who it is, which contract it was written against, and what it
/// contributes to the UI.
///
/// The manifest is the *declaration* half of the plugin contract. It
/// carries no executable code, so baguette can read it, show the user
/// what a plugin would add, and decide whether to render anything —
/// all without running a single line the plugin shipped. Code only
/// runs when the user activates a contribution (see `PluginCommand`).
///
/// Parsing is a pure function over bytes, which is what keeps the
/// plugin system unit-testable: no filesystem, no subprocess, no
/// dynamic loading anywhere in this type.
struct PluginManifest: Equatable, Sendable {

    /// The manifest contract this build of baguette understands.
    /// A manifest declaring a *newer* number is refused outright
    /// rather than parsed leniently — see `parsing(json:)`.
    static let supportedAPIVersion = 1

    let name: String
    let version: String
    let apiVersion: Int
    /// One-line summary shown by `baguette plugin list` / `show`.
    /// `nil` when the manifest omits it.
    let description: String?
    /// What this plugin may ask baguette to do. Empty means nothing —
    /// least privilege by default.
    let capabilities: [PluginCapability]
    let commands: [PluginCommand]
    let panels: [PluginPanel]

    init(
        name: String,
        version: String,
        apiVersion: Int,
        description: String? = nil,
        capabilities: [PluginCapability] = [],
        commands: [PluginCommand] = [],
        panels: [PluginPanel] = []
    ) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.description = description
        self.capabilities = capabilities
        self.commands = commands
        self.panels = panels
    }

    // MARK: - parsing

    /// Parse a `baguette-plugin.json` payload.
    ///
    /// The `apiVersion` gate runs **before** any field is read. A
    /// manifest from the future may use shapes this build cannot
    /// interpret, so refusing it wholesale is honest; parsing what we
    /// recognise and dropping the rest would silently give the user a
    /// half-working plugin.
    static func parsing(json data: Data) throws -> PluginManifest {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginManifestError.malformedJSON
        }
        guard let dict = raw as? [String: Any] else {
            throw PluginManifestError.malformedJSON
        }

        let apiVersion = dict["apiVersion"] as? Int ?? supportedAPIVersion
        guard apiVersion <= supportedAPIVersion else {
            throw PluginManifestError.unsupportedAPIVersion(
                declared: apiVersion, supported: supportedAPIVersion
            )
        }

        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw PluginManifestError.missingName
        }
        guard let version = dict["version"] as? String, !version.isEmpty else {
            throw PluginManifestError.missingVersion
        }

        let capabilities = try (dict["capabilities"] as? [String] ?? []).map { raw in
            guard let capability = PluginCapability(rawValue: raw) else {
                throw PluginManifestError.unknownCapability(name: raw)
            }
            return capability
        }

        let contributes = dict["contributes"] as? [String: Any] ?? [:]

        // Commands parse first: a panel body names the command whose
        // output fills it, and we validate that reference here rather
        // than discovering the typo on the user's first click.
        let commandDicts = contributes["commands"] as? [[String: Any]] ?? []
        let commands = try commandDicts.map(PluginCommand.parsing(dict:))
        let declaredCommands = Set(commands.map(\.id))

        let panelDicts = contributes["panels"] as? [[String: Any]] ?? []
        let panels = try panelDicts.map {
            try PluginPanel.parsing(dict: $0, declaredCommands: declaredCommands)
        }

        return PluginManifest(
            name: name,
            version: version,
            apiVersion: apiVersion,
            description: dict["description"] as? String,
            capabilities: capabilities,
            commands: commands,
            panels: panels
        )
    }
}

/// Why a `baguette-plugin.json` couldn't be read. Every case names
/// something the plugin author can fix, because these surface through
/// `baguette plugin validate` as authoring feedback.
enum PluginManifestError: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case missingName
    case missingVersion
    case emptyCommandRun(id: String)
    case unsupportedAPIVersion(declared: Int, supported: Int)
    case unknownIcon(name: String)
    case unknownCondition(expression: String)
    case unknownPanelBody(kind: String)
    case unknownRowAction(name: String)
    case unknownCommandSource(id: String)
    case unknownCapability(name: String)

    var description: String {
        switch self {
        case .malformedJSON:
            return "baguette-plugin.json is not a JSON object"
        case .missingName:
            return "manifest is missing a non-empty \"name\""
        case .missingVersion:
            return "manifest is missing a non-empty \"version\""
        case .emptyCommandRun(let id):
            return "command \"\(id)\" has an empty \"run\" — nothing to execute"
        case .unsupportedAPIVersion(let declared, let supported):
            return """
                manifest declares apiVersion \(declared); this baguette \
                supports up to \(supported) — upgrade baguette
                """
        case .unknownIcon(let name):
            return """
                unknown icon \"\(name)\" — use one of: \
                \(PluginIcon.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .unknownCondition(let expression):
            return """
                unknown \"when\" condition \"\(expression)\" — use one of: \
                \(PluginCondition.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .unknownPanelBody(let kind):
            return "unknown panel body kind \"\(kind)\" — this baguette renders: list"
        case .unknownRowAction(let name):
            return """
                unknown rowAction \"\(name)\" — use one of: \
                \(RowAction.allCases.map(\.rawValue).joined(separator: ", "))
                """
        case .unknownCommandSource(let id):
            return "panel body names command \"\(id)\", which this plugin does not contribute"
        case .unknownCapability(let name):
            return """
                unknown capability \"\(name)\" — use one of: \
                \(PluginCapability.allCases.map(\.rawValue).joined(separator: ", "))
                """
        }
    }
}
