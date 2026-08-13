import Foundation

/// One display plane backed by SimulatorKit ports + Connected Screens.
final class SimulatorKitDisplay: Display, @unchecked Sendable {
    let kind: DisplayKind
    private let udid: String
    private let host: any DeviceHost
    private let enumerateIO: () throws -> String
    private let lock = NSLock()
    private var cached: DisplayBinding?

    init(
        kind: DisplayKind,
        udid: String,
        host: any DeviceHost,
        enumerateIO: @escaping () throws -> String
    ) {
        self.kind = kind
        self.udid = udid
        self.host = host
        self.enumerateIO = enumerateIO
    }

    func resolve() throws -> DisplayBinding {
        let sized = try SimulatorKitFramebufferPorts.sizedPorts(udid: udid, host: host)
        let screens = SimctlIOEnumerate.connectedScreens(from: try enumerateIO())
        let ports = FramebufferPortSnapshots.assigningScreenIds(
            ports: sized,
            screens: screens
        )
        let binding = try ConnectedScreens.binding(kind: kind, ports: ports)
        lock.lock()
        cached = binding
        lock.unlock()
        return binding
    }

    func screen() -> any Screen {
        // Prefer a fresh resolve; fall back to the last successful
        // binding so a transient probe miss after bind() doesn't open
        // an unbound phone stream under a CarPlay label.
        let binding = (try? resolve()) ?? cachedBinding()
        return SimulatorKitScreen(udid: udid, host: host, binding: binding)
    }

    /// Input that re-derives its digitizer target on every gesture.
    ///
    /// The phone's target is a constant, so this costs it nothing. An
    /// external plane's target comes from a connected screen id that
    /// churns as the display is attached, reconfigured and discarded —
    /// under a session that resolved its `Input` once, at open. Holding
    /// the target from then means dispatching to a screen that may be
    /// gone, which restarts `backboardd`.
    ///
    /// Note the missing `?? cachedBinding()`: falling back to the last
    /// good binding is exactly how a dead screen id survives its screen.
    /// Capture is fine for the framebuffer — a stale surface is a stale
    /// picture — but not for HID.
    func input() -> any Input {
        // Strong capture on purpose: the plane owns the probe, and the
        // session's input should keep it alive for as long as it may be
        // asked. Nothing holds the input back, so there is no cycle.
        BoundInput { [self] in
            guard let binding = try? self.resolve(),
                  let target = DisplayTouchTarget.resolve(
                      kind: self.kind,
                      connectedScreenId: binding.connectedScreenId,
                      derive: IndigoHIDTargetForScreen.target(for:)
                  )
            else { return nil }
            return IndigoHIDInput(udid: self.udid, host: self.host, touchTarget: target)
        }
    }

    private func cachedBinding() -> DisplayBinding? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }
}
