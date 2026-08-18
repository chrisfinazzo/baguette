import Foundation

/// Owns the motion feature's state for one simulator: which kind is being
/// published, what the pedometer has accrued, and whether a location walk
/// is allowed to drive it.
///
/// Mirrors `CameraSession` — `@MainActor`, one `@Mockable` collaborator,
/// failures reported through `lastError` rather than thrown at the caller.
///
/// ## Why motion is opt-in
///
/// Publishing arms a **simulator-wide** `DYLD_INSERT_LIBRARIES` that only
/// takes effect on the next app launch. Doing that as a silent side effect
/// of moving the device would be a nasty surprise, so `drive` — the hook a
/// location walk or route calls — does nothing until motion has been turned
/// on explicitly. Once it is on, moving the device drives it.
@MainActor
final class MotionSession {

    enum Phase: Equatable {
        case idle
        case publishing(MotionKind)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?

    /// Steps accrued so far, including the leg in flight at the last
    /// publish. Surfaced for the browser's readout.
    var steps: Int { ledger.steps }
    /// Metres accrued so far, on the same basis as `steps`.
    var metres: Double { ledger.metres }

    /// The speed currently being reported, in metres per second. Surfaced
    /// alongside the kind so a readout can show *why* it says what it says.
    var speed: Double { current?.speed ?? 0 }

    /// The smallest speed change worth a republish. Each publish costs a
    /// `launchctl` spawn and the joystick sends a fresh vector several
    /// times a second; this is the same epsilon `sim-location.js` already
    /// throttles its own sends with (`SPEED_EPSILON`).
    static let speedEpsilon = 0.1

    private let motion: any Motion
    private let now: @Sendable () -> Double

    private var ledger: MotionLedger = .empty
    private var current: MotionIntent?
    private var armedSimulator: (any Simulator)?

    init(motion: any Motion, now: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.motion = motion
        self.now = now
    }

    /// Turn motion on, or change what's being reported.
    func set(kind: MotionKind, confidence: MotionConfidence, speed: Double,
             on simulator: any Simulator) async {
        await publish(kind: kind, confidence: confidence, speed: speed, on: simulator)
    }

    /// Drive motion from a location walk or route speed.
    ///
    /// A no-op while motion is off — see the note on opt-in above. The kind
    /// is classified from the speed, so the preset a user picked in the
    /// browser's Walk mode is the kind the app under test observes.
    func drive(speed: Double, on simulator: any Simulator) async {
        guard case .publishing = phase else { return }
        let kind = MotionKind.from(speed: speed)
        // Skip a republish that would tell an app nothing new.
        if let current, current.kind == kind,
           abs(current.speed - speed) < Self.speedEpsilon {
            return
        }
        await publish(kind: kind, confidence: current?.confidence ?? .high,
                      speed: speed, on: simulator)
    }

    /// Park the device and stop future app launches reading motion.
    ///
    /// Parks **before** disarming: an app already running still has the
    /// dylib loaded, so the last thing it reads must say "not moving"
    /// rather than a stale walk. The totals already walked survive, because
    /// a pedometer that reset to zero would make an app's chart jump
    /// backwards.
    func stop() async {
        guard case .publishing = phase, let simulator = armedSimulator else { return }
        bankCurrentLeg()
        let parked = MotionIntent.stationary(startedAt: now(), stepsBefore: ledger.steps,
                                            distanceBefore: ledger.metres)
        try? await motion.publish(parked, on: simulator)
        try? await motion.clear(on: simulator)
        phase = .idle
        current = nil
        armedSimulator = nil
    }

    private func publish(kind: MotionKind, confidence: MotionConfidence, speed: Double,
                         on simulator: any Simulator) async {
        bankCurrentLeg()
        let intent = ledger.intent(kind: kind, confidence: confidence, speed: speed,
                                  startedAt: now())
        do {
            try await motion.publish(intent, on: simulator)
        } catch {
            lastError = error.localizedDescription
            return
        }
        current = intent
        armedSimulator = simulator
        phase = .publishing(kind)
        lastError = nil
    }

    /// Rolls the leg in flight into the running totals, so the next intent
    /// carries them forward.
    private func bankCurrentLeg() {
        guard let current else { return }
        ledger = ledger.banking(current, at: now())
    }
}
