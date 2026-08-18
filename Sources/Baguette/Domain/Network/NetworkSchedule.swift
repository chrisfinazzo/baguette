import Foundation

/// How a bandwidth becomes the two numbers the injected dylib paces a
/// response body with: release `bytesPerTick` every `tickIntervalMs`.
///
/// ## Why the host computes this
///
/// Same division motion established — **policy in tested Swift, arithmetic
/// in the dylib.** Choosing a tick that is smooth without thrashing a timer,
/// and keeping the delivered rate honest when a tick works out to a
/// fraction of a byte, are judgement calls; the dylib should hold a budget
/// and subtract from it, nothing more.
///
/// ## Why the interval moves and the byte count doesn't
///
/// The obvious shape is "fixed 50 ms tick, however many bytes that is". It's
/// wrong at the slow end: a link where a tick is 6.25 bytes rounds to 6 and
/// then quietly delivers 4% less than asked. So the rounded byte count is
/// taken as given and the **interval** is derived back from it, which makes
/// the delivered rate exact at every bandwidth.
struct NetworkSchedule: Equatable, Sendable {

    /// Bytes the dylib may hand to the app each tick.
    let bytesPerTick: Int

    /// Milliseconds between ticks.
    let tickIntervalMs: Double

    /// The tick length aimed for. Short enough that a download looks like it
    /// is arriving rather than stuttering, long enough not to wake a timer
    /// hundreds of times a second. Slow links stretch past it, because a
    /// sub-byte tick is not a thing to schedule.
    private static let targetTickSeconds = 0.05

    /// Fails when `bandwidthKbps` isn't a rate. `NetworkCondition` already
    /// rejects those, so in practice this is belt and braces around the one
    /// arithmetic path that would otherwise divide by zero.
    init?(bandwidthKbps: Double) {
        guard bandwidthKbps.isFinite, bandwidthKbps > 0 else { return nil }
        let bytesPerSecond = bandwidthKbps * 1000 / 8
        let bytes = max(1, Int((bytesPerSecond * Self.targetTickSeconds).rounded()))
        bytesPerTick = bytes
        tickIntervalMs = Double(bytes) / bytesPerSecond * 1000
    }
}

extension NetworkCondition {
    /// The pacing schedule for this condition, or `nil` when the link is
    /// unmetered and bytes should arrive at full speed.
    var schedule: NetworkSchedule? {
        bandwidthKbps.flatMap(NetworkSchedule.init(bandwidthKbps:))
    }
}
