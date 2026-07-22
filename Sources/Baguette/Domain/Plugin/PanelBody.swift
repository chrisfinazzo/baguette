import Foundation

/// A side panel a plugin adds to focus mode, described entirely as
/// data. The host owns every pixel: it picks the glyph from `icon`,
/// renders the card chrome, and fills `body` from the named command's
/// output. The plugin supplies no markup, no CSS and no script.
///
/// That constraint is the whole security posture of v1. `sim.html` is
/// the origin `Server.isTrustedBrowserRequest` spends ~70 lines
/// defending; anything a plugin could inject there would be
/// same-origin and could drive the simulator silently. Keeping panels
/// declarative means untrusted manifest text never becomes markup.
struct PluginPanel: Equatable, Sendable {
    let id: String
    let title: String
    let icon: PluginIcon
    /// When the panel is offered. `nil` means always.
    let when: PluginCondition?
    let body: PanelBody

    init(id: String, title: String, icon: PluginIcon, when: PluginCondition? = nil, body: PanelBody) {
        self.id = id
        self.title = title
        self.icon = icon
        self.when = when
        self.body = body
    }

    // MARK: - parsing

    /// `declaredCommands` are the ids this plugin contributes; a body
    /// naming anything else is a typo the author should hear about at
    /// validate time rather than on first click.
    static func parsing(dict: [String: Any], declaredCommands: Set<String>) throws -> PluginPanel {
        let id = dict["id"] as? String ?? ""

        let iconName = dict["icon"] as? String ?? ""
        guard let icon = PluginIcon(rawValue: iconName) else {
            throw PluginManifestError.unknownIcon(name: iconName)
        }

        var condition: PluginCondition?
        if let rawWhen = dict["when"] as? String {
            guard let parsed = PluginCondition(rawValue: rawWhen) else {
                throw PluginManifestError.unknownCondition(expression: rawWhen)
            }
            condition = parsed
        }

        let body = try PanelBody.parsing(
            dict: dict["body"] as? [String: Any] ?? [:],
            declaredCommands: declaredCommands
        )

        return PluginPanel(
            id: id,
            title: dict["title"] as? String ?? id,
            icon: icon,
            when: condition,
            body: body
        )
    }
}

/// What fills a panel. One case in v1 — deliberately.
///
/// The known ceiling of a declarative UI is that every new widget kind
/// costs a baguette release. That's the accepted trade for not running
/// plugin code in the page. When a real plugin needs something a list
/// can't express, the successor is a sandboxed-iframe `webview` case
/// behind an `apiVersion` bump — which is why an unrecognised kind
/// throws rather than rendering an empty card.
enum PanelBody: Equatable, Sendable {
    /// Rows come from running the plugin's `source` command and
    /// reading the `rows` array off its JSON answer.
    case list(source: String, rowAction: RowAction?)

    static func parsing(dict: [String: Any], declaredCommands: Set<String>) throws -> PanelBody {
        let kind = dict["kind"] as? String ?? ""
        guard kind == "list" else {
            throw PluginManifestError.unknownPanelBody(kind: kind)
        }

        let source = dict["source"] as? String ?? ""
        guard declaredCommands.contains(source) else {
            throw PluginManifestError.unknownCommandSource(id: source)
        }

        var rowAction: RowAction?
        if let raw = dict["rowAction"] as? String {
            guard let parsed = RowAction(rawValue: raw) else {
                throw PluginManifestError.unknownRowAction(name: raw)
            }
            rowAction = parsed
        }

        return .list(source: source, rowAction: rowAction)
    }
}

/// What clicking a row does. Each maps to something the host already
/// knows how to do, using the row's own `frame` (device points, the
/// same space as gesture coordinates — so no conversion).
enum RowAction: String, Equatable, Sendable, CaseIterable {
    /// Paint the AX-inspector box over the row's frame.
    case highlight
    /// Dispatch a tap at the centre of the row's frame.
    case tap
    /// Copy the row's `copy` string to the clipboard.
    case copy
}

/// When a contribution is offered. A closed set, evaluated by the host
/// against state it already tracks — not an expression language.
enum PluginCondition: String, Equatable, Sendable, CaseIterable {
    case simulatorBooted = "simulator.booted"
}

/// The glyphs baguette ships. Plugins name one; they never supply
/// markup, because a manifest is untrusted text destined for the DOM
/// and inline SVG in that position is a script-injection vector.
///
/// Adding a case is a host release. That's the cost of the closed set,
/// and it's the point.
enum PluginIcon: String, Equatable, Sendable, CaseIterable {
    case accessibility
    case reload
    case link
    case list
    case bell
    case wrench
    case lock
    case globe
    case camera
    case clock
    case document
    case play
}
