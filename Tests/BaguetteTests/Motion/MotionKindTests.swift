import Testing
import Foundation
@testable import Baguette

/// Pure-value coverage for `MotionKind` — the classification an app reads
/// back as `CMMotionActivity`.
///
/// The device never tells us what it's doing; a walk vector does. The
/// browser's Walk mode already asks the question in the user's language —
/// its speed presets are `Walk 1.4 · Run 3.5 · Cycle 6 · Drive 13.4 ·
/// Highway 29` (m/s) — so the classification is pinned to those presets
/// rather than invented. If a preset ever stops classifying as its own
/// label, the thresholds have drifted and these tests say so.
///
/// The frontend stays a dumb sender: it keeps posting the same walk
/// vector it always did, and the speed is classified here.
@Suite("MotionKind")
struct MotionKindTests {

    @Test func `classifies each of the browser's speed presets as its own label`() {
        #expect(MotionKind.from(speed: 1.4) == .walking)
        #expect(MotionKind.from(speed: 3.5) == .running)
        #expect(MotionKind.from(speed: 6) == .cycling)
        #expect(MotionKind.from(speed: 13.4) == .automotive)
        #expect(MotionKind.from(speed: 29) == .automotive)
    }

    @Test func `reads a standstill as stationary`() {
        // Releasing the joystick pins the device — `location set` reports
        // `speed,-1 course,-1`, and the app should see "not moving".
        #expect(MotionKind.from(speed: 0) == .stationary)
    }

    @Test func `treats a negative speed as unknown, not as a standstill`() {
        // CoreLocation spells "I don't know the speed" as -1. That is not
        // the same claim as "the device is still", and an app that gates on
        // `stationary` deserves the difference.
        #expect(MotionKind.from(speed: -1) == .unknown)
    }

    @Test func `keeps a slow drift stationary rather than calling it a walk`() {
        // Dead-reckoning jitter around the pin shouldn't read as walking.
        #expect(MotionKind.from(speed: 0.1) == .stationary)
    }
}
