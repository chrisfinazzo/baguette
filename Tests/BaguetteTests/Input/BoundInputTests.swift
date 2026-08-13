import Mockable
import Testing

@testable import Baguette

/// Input for a display plane that only exists while the plane does.
///
/// A stream session resolves its `Input` once and holds it for the whole
/// session, which is fine for the phone — the integrated digitizer never
/// goes anywhere. An external display is not like that: it is attached,
/// reconfigured and discarded underneath a live session, and its
/// digitizer target changes with it. Dispatching to the target that was
/// correct at session-open restarts `backboardd`.
///
/// So the plane's input asks again on every gesture, and dispatches
/// nothing when the answer is "the plane isn't bound".
@Suite("BoundInput")
struct BoundInputTests {

    @Test func `a bound plane passes the gesture to its live input`() {
        let live = MockInput()
        given(live).tap(at: .any, size: .any, duration: .any).willReturn(true)

        let input = BoundInput { live }

        #expect(input.tap(at: Point(x: 1, y: 2), size: Size(width: 8, height: 4), duration: 0))
        verify(live).tap(at: .any, size: .any, duration: .any).called(1)
    }

    @Test func `an unbound plane drops the gesture instead of dispatching it`() {
        let input = BoundInput { nil }

        #expect(!input.tap(at: Point(x: 1, y: 2), size: Size(width: 8, height: 4), duration: 0))
        #expect(!input.swipe(
            from: Point(x: 0, y: 0), to: Point(x: 1, y: 1),
            size: Size(width: 8, height: 4), duration: 0
        ))
        #expect(!input.touch1(
            phase: .down, at: Point(x: 1, y: 1), size: Size(width: 8, height: 4), edge: nil
        ))
        #expect(!input.touch2(
            phase: .down, first: Point(x: 1, y: 1), second: Point(x: 2, y: 2),
            size: Size(width: 8, height: 4)
        ))
        #expect(!input.button(.home, duration: 0))
        #expect(!input.key(KeyboardKey(hidUsage: HIDUsage(page: 7, usage: 4)), modifiers: [], duration: 0))
        #expect(!input.scroll(deltaX: 1, deltaY: 1))
        #expect(!input.twoFingerPath(
            start1: Point(x: 0, y: 0), end1: Point(x: 1, y: 1),
            start2: Point(x: 2, y: 2), end2: Point(x: 3, y: 3),
            size: Size(width: 8, height: 4), duration: 0
        ))
    }

    /// The point of the indirection: a plane that goes away mid-session
    /// stops receiving events, without the session being torn down and
    /// rebuilt around it.
    @Test func `a plane that goes away mid-session stops dispatching`() {
        let live = MockInput()
        given(live).tap(at: .any, size: .any, duration: .any).willReturn(true)
        let plane = PlaneState(input: live)

        let input = BoundInput { plane.input }
        let point = Point(x: 1, y: 2)
        let size = Size(width: 8, height: 4)

        #expect(input.tap(at: point, size: size, duration: 0))
        plane.input = nil
        #expect(!input.tap(at: point, size: size, duration: 0))

        // Exactly one dispatch — the second gesture never reached it.
        verify(live).tap(at: .any, size: .any, duration: .any).called(1)
    }

    /// And comes back when the plane does, so re-attaching a display
    /// doesn't require reopening the stream.
    @Test func `a plane that returns starts dispatching again`() {
        let live = MockInput()
        given(live).tap(at: .any, size: .any, duration: .any).willReturn(true)
        let plane = PlaneState(input: nil)

        let input = BoundInput { plane.input }
        let point = Point(x: 1, y: 2)
        let size = Size(width: 8, height: 4)

        #expect(!input.tap(at: point, size: size, duration: 0))
        plane.input = live
        #expect(input.tap(at: point, size: size, duration: 0))
    }

    private final class PlaneState: @unchecked Sendable {
        var input: (any Input)?
        init(input: (any Input)?) { self.input = input }
    }
}
