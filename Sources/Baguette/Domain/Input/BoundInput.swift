import Foundation

/// Input for a display plane that only exists while the plane does.
///
/// A stream session resolves its `Input` once and holds it for the
/// session's lifetime. For the phone that is fine — the integrated
/// digitizer is a constant and never moves. An external display is not
/// like that: it is attached, reconfigured and discarded underneath a
/// live session, and its digitizer target is derived from a connected
/// screen id that changes with it. The target that was correct when the
/// socket opened can describe a screen that no longer exists by the time
/// the user touches the pane, and dispatching there restarts
/// `backboardd` — SpringBoard and any CarPlay session go with it.
///
/// So this asks again on every gesture, and dispatches nothing when the
/// answer is "the plane isn't bound". A dropped gesture is a pane that
/// doesn't respond; the alternative is a simulator that reboots.
struct BoundInput: Input {
    /// The plane's input right now, or nil while it isn't bound.
    /// Called once per gesture — deliberately not cached.
    private let live: @Sendable () -> (any Input)?

    init(live: @escaping @Sendable () -> (any Input)?) {
        self.live = live
    }

    func tap(at point: Point, size: Size, duration: Double) -> Bool {
        live()?.tap(at: point, size: size, duration: duration) ?? false
    }

    func swipe(from start: Point, to end: Point, size: Size, duration: Double) -> Bool {
        live()?.swipe(from: start, to: end, size: size, duration: duration) ?? false
    }

    func touch1(phase: GesturePhase, at point: Point, size: Size, edge: DeviceEdge?) -> Bool {
        live()?.touch1(phase: phase, at: point, size: size, edge: edge) ?? false
    }

    func touch2(phase: GesturePhase, first: Point, second: Point, size: Size) -> Bool {
        live()?.touch2(phase: phase, first: first, second: second, size: size) ?? false
    }

    func button(_ button: DeviceButton, duration: Double) -> Bool {
        live()?.button(button, duration: duration) ?? false
    }

    func key(_ key: KeyboardKey, modifiers: Set<KeyModifier>, duration: Double) -> Bool {
        live()?.key(key, modifiers: modifiers, duration: duration) ?? false
    }

    func scroll(deltaX: Double, deltaY: Double) -> Bool {
        live()?.scroll(deltaX: deltaX, deltaY: deltaY) ?? false
    }

    func twoFingerPath(
        start1: Point, end1: Point,
        start2: Point, end2: Point,
        size: Size, duration: Double
    ) -> Bool {
        live()?.twoFingerPath(
            start1: start1, end1: end1,
            start2: start2, end2: end2,
            size: size, duration: duration
        ) ?? false
    }
}
