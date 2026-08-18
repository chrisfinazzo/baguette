import Foundation
import Mockable

/// Arms / disarms one dylib in a simulator's launchd-domain
/// `DYLD_INSERT_LIBRARIES`. The env var survives until the simulator
/// reboots, so the orchestrator re-arms on boot rather than every time a
/// feature starts.
///
/// Both calls name the dylib, because the variable is **shared**: more than
/// one baguette feature injects (the virtual camera, and motion), so
/// arming must preserve whatever else is loaded and disarming must remove
/// only its own entry. `InjectedDylibs` models that merge.
@Mockable
protocol SimulatorInjection: AnyObject, Sendable {
    func arm(dylibPath: String, on simulator: any Simulator) async throws
    func disarm(dylibPath: String, on simulator: any Simulator) async throws
}
