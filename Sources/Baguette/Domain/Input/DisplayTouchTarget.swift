import Foundation

/// Resolves the Indigo HID digitizer target for a display plane.
///
/// Both answers are constants, because a target is only valid if some
/// create-service message registered it — see `IndigoHIDTouchTarget`.
/// The plane picks *which* service to address; the screen it is
/// currently showing on has nothing to do with it.
///
/// `connectedScreenId` and `derive` are kept for the caller's shape and
/// deliberately unused for CarPlay. `IndigoHIDTargetForScreen` is a real
/// SimulatorKit export and it is tempting precisely because it looks
/// like the answer — it returns `0x40000000 | screenId`, a plausible
/// number that no service has registered. Sending there is what
/// restarted the guest.
enum DisplayTouchTarget {
    static func resolve(
        kind: DisplayKind,
        connectedScreenId: UInt32,
        derive: (UInt32) -> UInt32?,
        override: UInt32? = nil
    ) -> UInt32? {
        switch kind {
        case .phone:   return IndigoHIDTouchTarget.phone
        case .carPlay: return override ?? IndigoHIDTouchTarget.carPlay
        }
    }

    /// Parses a probe override — `BAGUETTE_CARPLAY_TARGET`, decimal or
    /// `0x`-prefixed. Exists because finding the right target is a
    /// search: the guest publishes the registered set only when it
    /// rejects one, and rebuilding between candidates is far slower
    /// than restarting with a different number.
    ///
    /// Nonsense is ignored rather than defaulted to something arbitrary
    /// — a typo'd target is exactly the unregistered value that kills
    /// the guest.
    static func parseOverride(_ raw: String?) -> UInt32? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        var radix = 10
        if text.lowercased().hasPrefix("0x") {
            radix = 16
            text = String(text.dropFirst(2))
        }
        return UInt32(text, radix: radix)
    }
}
