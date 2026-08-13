import Foundation
import Testing

@testable import Baguette

/// The extra screens a simulator can show beside its own glass: the
/// CarPlay external display, and the Apple Watch paired to it. The
/// browser rail offers a screen that is there and explains one that
/// isn't, so absence is an answer here — never an error.
@Suite("CompanionScreens")
struct CompanionScreensTests {

    @Test func `a device with neither screen reports both absent`() {
        let screens = CompanionScreens(carPlayConnected: false, watch: nil)

        #expect(screens.json == #"{"carplay":{"available":false},"watch":{"available":false}}"#)
    }

    @Test func `a connected CarPlay display is available`() {
        let screens = CompanionScreens(carPlayConnected: true, watch: nil)

        #expect(screens.json == #"{"carplay":{"available":true},"watch":{"available":false}}"#)
    }

    @Test func `a paired watch names itself so the rail can label and stream it`() {
        let screens = CompanionScreens(
            carPlayConnected: false,
            watch: PairedWatch(
                udid: "WATCH-1",
                name: "Apple Watch Series 11 (46mm)",
                state: .booted
            )
        )

        #expect(screens.json == """
            {"carplay":{"available":false},"watch":{"available":true,\
            "name":"Apple Watch Series 11 (46mm)","state":"Booted","udid":"WATCH-1"}}
            """)
    }

    @Test func `a paired watch that isn't booted is still available, and says so`() {
        let screens = CompanionScreens(
            carPlayConnected: true,
            watch: PairedWatch(udid: "WATCH-2", name: "Apple Watch Ultra 3", state: .shutdown)
        )

        #expect(screens.json == """
            {"carplay":{"available":true},"watch":{"available":true,\
            "name":"Apple Watch Ultra 3","state":"Shutdown","udid":"WATCH-2"}}
            """)
    }

    @Test func `a name carrying JSON punctuation stays one string`() {
        let screens = CompanionScreens(
            carPlayConnected: false,
            watch: PairedWatch(udid: "W", name: #"Watch "Test" \ 1"#, state: .booted)
        )

        let parsed = (try? JSONSerialization.jsonObject(with: Data(screens.json.utf8)))
            as? [String: Any]
        let watch = parsed?["watch"] as? [String: Any]
        #expect(watch?["name"] as? String == #"Watch "Test" \ 1"#)
    }
}
