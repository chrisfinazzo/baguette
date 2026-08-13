import Testing
@testable import Baguette

/// Phone input keeps the integrated digitizer constant. CarPlay input
/// derives its HID target from the live connected screen id — never
/// from creatable plist 101 / hard-coded 0x40000065.
@Suite("DisplayTouchTarget")
struct DisplayTouchTargetTests {

    @Test func `phone always uses the integrated digitizer constant`() {
        let target = DisplayTouchTarget.resolve(
            kind: .phone,
            connectedScreenId: 1,
            derive: { _ in 0xDEAD_BEEF }
        )
        #expect(target == IndigoHIDTouchTarget.phone)
    }

    @Test func `carPlay uses the derived target for the live connected screen id`() {
        var seen: UInt32?
        let target = DisplayTouchTarget.resolve(
            kind: .carPlay,
            connectedScreenId: 204,
            derive: { id in
                seen = id
                return id | 0x4000_0000
            }
        )
        #expect(seen == 204)
        #expect(target == 0x4000_00CC)
        #expect(target != IndigoHIDTouchTarget.phone)
        #expect(target != 0x4000_0065)
    }

    /// There is no fallback for a non-phone plane, and that is the whole
    /// point.
    ///
    /// This used to answer `IndigoHIDTouchTarget.phone`, which is two
    /// bugs in one: a tap meant for the external display lands on the
    /// phone, and — far worse — dispatching to a digitizer target that
    /// doesn't describe a live screen takes `backboardd` down and
    /// SpringBoard with it. From outside that looks like the simulator
    /// spontaneously rebooting. A gesture nobody can deliver must be
    /// dropped, not redirected.
    @Test func `carPlay has no target when derivation fails`() {
        let target = DisplayTouchTarget.resolve(
            kind: .carPlay,
            connectedScreenId: 2,
            derive: { _ in nil }
        )
        #expect(target == nil)
    }

    /// Screen id `0` is what a caller passes when it has no binding at
    /// all. Deriving a digitizer target from it produces a number that
    /// looks plausible and describes nothing — exactly the input that
    /// restarts the guest — so the id never reaches `derive`.
    @Test func `carPlay refuses to derive from the absent screen id`() {
        var derived = false
        let target = DisplayTouchTarget.resolve(
            kind: .carPlay,
            connectedScreenId: 0,
            derive: { _ in derived = true; return 0x4000_0000 }
        )
        #expect(target == nil)
        #expect(!derived)
    }

    @Test func `phone is unaffected by the absent screen id`() {
        let target = DisplayTouchTarget.resolve(
            kind: .phone,
            connectedScreenId: 0,
            derive: { _ in nil }
        )
        #expect(target == IndigoHIDTouchTarget.phone)
    }
}
