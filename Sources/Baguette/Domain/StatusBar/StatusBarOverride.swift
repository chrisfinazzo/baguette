import Foundation

/// A set of status-bar overrides to apply to a booted simulator. Every
/// field is optional: a caller overrides only the indicators it cares
/// about and leaves the rest at the simulator's live values. Mirrors
/// the flags accepted by `xcrun simctl status_bar <udid> override` —
/// see `docs/features/status-bar.md` for the verified flag surface.
///
/// The value is the unit-testable core of the feature: `overrideArguments`
/// is a pure projection to the argv tail simctl expects, with the
/// numeric fields clamped to the ranges simctl enforces (so a bad
/// slider value can't make the spawn fail). The Infrastructure adapter
/// (`SimctlStatusBar`) just prepends `simctl status_bar <udid> override`
/// and runs it.
public struct StatusBarOverride: Equatable, Sendable {
    /// A fixed clock value. simctl also sets the date when the string
    /// is a valid ISO date; a bare time like `"9:41"` only moves the
    /// clock.
    public var time: String?
    /// Cellular operator/carrier name. The empty string is meaningful
    /// — it blanks the carrier — so it is emitted rather than dropped.
    public var operatorName: String?
    public var dataNetwork: DataNetwork?
    public var wifiMode: WifiMode?
    /// Wi-Fi signal strength, clamped to 0…3 on the wire.
    public var wifiBars: Int?
    public var cellularMode: CellularMode?
    /// Cellular signal strength, clamped to 0…4 on the wire.
    public var cellularBars: Int?
    public var batteryState: BatteryState?
    /// Battery percentage, clamped to 0…100 on the wire.
    public var batteryLevel: Int?

    public init(
        time: String? = nil,
        operatorName: String? = nil,
        dataNetwork: DataNetwork? = nil,
        wifiMode: WifiMode? = nil,
        wifiBars: Int? = nil,
        cellularMode: CellularMode? = nil,
        cellularBars: Int? = nil,
        batteryState: BatteryState? = nil,
        batteryLevel: Int? = nil
    ) {
        self.time = time
        self.operatorName = operatorName
        self.dataNetwork = dataNetwork
        self.wifiMode = wifiMode
        self.wifiBars = wifiBars
        self.cellularMode = cellularMode
        self.cellularBars = cellularBars
        self.batteryState = batteryState
        self.batteryLevel = batteryLevel
    }

    /// True when no field is set — the caller has nothing to apply.
    /// `simctl … override` requires at least one flag, so callers
    /// should treat an empty override as a no-op (or an error).
    public var isEmpty: Bool { overrideArguments.isEmpty }

    /// The argv tail after `simctl status_bar <udid> override`. Flags
    /// appear in a stable order so the output is deterministic and
    /// testable; simctl itself accepts them in any order.
    public var overrideArguments: [String] {
        var args: [String] = []
        if let time { args += ["--time", time] }
        if let operatorName { args += ["--operatorName", operatorName] }
        if let dataNetwork { args += ["--dataNetwork", dataNetwork.wireName] }
        if let wifiMode { args += ["--wifiMode", wifiMode.wireName] }
        if let wifiBars { args += ["--wifiBars", String(clamp(wifiBars, 0, 3))] }
        if let cellularMode { args += ["--cellularMode", cellularMode.wireName] }
        if let cellularBars { args += ["--cellularBars", String(clamp(cellularBars, 0, 4))] }
        if let batteryState { args += ["--batteryState", batteryState.wireName] }
        if let batteryLevel { args += ["--batteryLevel", String(clamp(batteryLevel, 0, 100))] }
        return args
    }

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}

/// Cellular data-network indicator. Wire spellings are simctl's
/// `--dataNetwork` values; `hide` removes the indicator entirely.
public enum DataNetwork: String, Sendable, CaseIterable, Equatable {
    case hide
    case wifi
    case threeG  = "3g"
    case fourG   = "4g"
    case lte
    case lteA    = "lte-a"
    case ltePlus = "lte+"
    case fiveG   = "5g"
    case fiveGPlus = "5g+"
    case fiveGUWB  = "5g-uwb"
    case fiveGUC   = "5g-uc"

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }
}

/// Wi-Fi connection state shown in the status bar.
public enum WifiMode: String, Sendable, CaseIterable, Equatable {
    case searching
    case failed
    case active

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }
}

/// Cellular connection state shown in the status bar.
public enum CellularMode: String, Sendable, CaseIterable, Equatable {
    case notSupported
    case searching
    case failed
    case active

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }
}

/// Battery charging state. simctl renders `charged` and `discharging`
/// identically; both are accepted for parity with the simctl surface.
public enum BatteryState: String, Sendable, CaseIterable, Equatable {
    case charging
    case charged
    case discharging

    public var wireName: String { rawValue }
    public init?(wireName: String) { self.init(rawValue: wireName) }
}
