import Foundation

/// The extra screens a simulator can show beside its own glass: the
/// CarPlay external display it can drive, and the Apple Watch paired
/// with it.
///
/// Availability is the point. The focus-mode rail offers a screen that
/// is there and explains one that isn't, so "absent" is an answer this
/// type carries rather than an error the caller has to interpret — a
/// device with neither is the common case, not a failure.
struct CompanionScreens: Sendable, Equatable {
    let carPlayConnected: Bool
    let watch: PairedWatch?

    var json: String {
        var watchField: [String: Any] = ["available": watch != nil]
        if let watch {
            watchField["udid"] = watch.udid
            watchField["name"] = watch.name
            watchField["state"] = watch.state.description
        }
        let dict: [String: Any] = [
            "carplay": ["available": carPlayConnected],
            "watch": watchField,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data(#"{"carplay":{"available":false},"watch":{"available":false}}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
