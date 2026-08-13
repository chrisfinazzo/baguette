import Foundation

/// Resolves the Indigo HID digitizer target for a display plane.
/// Phone always uses the integrated constant; an external plane derives
/// from the live connected screen id via `IndigoHIDTargetForScreen`.
///
/// Nil means "do not dispatch". There is deliberately no fallback for a
/// non-phone plane: this used to answer `IndigoHIDTouchTarget.phone`
/// when derivation failed, which sent the external display's gestures to
/// the phone and — the part that actually hurt — let a digitizer target
/// that describes no live screen reach the HID stack. That restarts
/// `backboardd`, taking SpringBoard and any CarPlay session with it, and
/// presents as the simulator rebooting on its own. A gesture nobody can
/// deliver is dropped.
enum DisplayTouchTarget {
    /// The id CoreSimulator never assigns to a connected screen, and so
    /// the value a caller passes when it has no binding at all.
    private static let noScreen: UInt32 = 0

    static func resolve(
        kind: DisplayKind,
        connectedScreenId: UInt32,
        derive: (UInt32) -> UInt32?
    ) -> UInt32? {
        switch kind {
        case .phone:
            return IndigoHIDTouchTarget.phone
        case .carPlay:
            // Never derive from the absent id: it yields a plausible
            // number describing nothing, which is the shape of the
            // crash rather than a way to avoid it.
            guard connectedScreenId != noScreen else { return nil }
            return derive(connectedScreenId)
        }
    }
}
