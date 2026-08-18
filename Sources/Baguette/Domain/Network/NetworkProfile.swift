import Foundation

/// The named network presets, borrowed wholesale from Network Link
/// Conditioner.
///
/// ## Why NLC's vocabulary and NLC's numbers
///
/// Every iOS developer already knows what NLC means by `3G` and
/// `Very Bad Network`, and those figures have been the shared reference for
/// a decade. Inventing baguette's own would mean defending them, and would
/// make two apps "tested on 3G" mean different things. So the words and the
/// figures both come across, and `NetworkProfileTests` pins each one — a
/// preset quietly getting faster would otherwise leave a green suite while
/// apps stopped being tested against the network they claim.
///
/// ## Two deliberate translations
///
/// - **NLC's delay is one-way**, paid outbound and again inbound.
///   `NetworkCondition.latencyMs` is the whole round trip — the figure a
///   developer means by "300 ms of latency" — so each preset doubles NLC's.
/// - **NLC conditions uplink and downlink separately.** baguette paces the
///   response body only, so a preset carries NLC's *downlink* bandwidth and
///   uploads run at full speed. Stated plainly in the docs rather than
///   papered over.
enum NetworkProfile: String, CaseIterable, Sendable {
    case wifi
    case dsl
    case lte
    case threeG = "3g"
    case edge
    case veryBadNetwork = "very-bad-network"
    case totalLoss = "100-loss"

    /// NLC's downlink bandwidth for this profile, in kbps.
    private var downlinkKbps: Double? {
        switch self {
        case .wifi: return 40_000
        case .dsl: return 2_000
        case .lte: return 50_000
        case .threeG: return 780
        case .edge: return 240
        case .veryBadNetwork: return 1_000
        // Nothing arrives, so there is no rate to pace it at.
        case .totalLoss: return nil
        }
    }

    /// NLC's **one-way** delay for this profile, in milliseconds. Doubled
    /// into a round trip by `condition`.
    private var oneWayDelayMs: Double {
        switch self {
        case .wifi: return 1
        case .dsl: return 5
        case .lte: return 65
        case .threeG: return 100
        case .edge: return 400
        case .veryBadNetwork: return 500
        case .totalLoss: return 0
        }
    }

    /// Percentage of requests this profile fails.
    private var lossPercent: Double {
        switch self {
        case .veryBadNetwork: return 10
        case .totalLoss: return 100
        case .wifi, .dsl, .lte, .threeG, .edge: return 0
        }
    }

    /// The condition this preset stands for.
    ///
    /// Can't fail: every figure above is a compile-time constant, all
    /// non-negative and in range, and `NetworkProfileTests` asserts each one
    /// — a bad constant fails the suite rather than reaching a simulator.
    var condition: NetworkCondition {
        NetworkCondition(
            latencyMs: oneWayDelayMs * 2,
            bandwidthKbps: downlinkKbps,
            lossPercent: lossPercent
        )!
    }
}
