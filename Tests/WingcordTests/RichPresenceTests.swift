import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Turning an activity's `SET_ACTIVITY` into a presence this client publishes.
///
/// The payload below is Watch Together's own, from `session.log` — the frame it
/// sent a second or two after starting. The link and button fields come from a
/// live Medal presence: two buttons, a large image linking to
/// `medal.tv/games/counter-strike-2` and a small one to `medal.tv/`.
@Suite("Rich presence")
@MainActor
struct RichPresenceTests {

    private let application = ApplicationID(rawValue: 880_218_394_199_220_334)

    private func published(_ payload: [String: Any]) -> RichPresenceActivity? {
        let model = AppModel()
        model.publishActivity(payload, application: application)
        return model.publishedActivity
    }

    /// Watch Together's own frame.
    @Test("An embedded activity's SET_ACTIVITY becomes a presence")
    func embeddedActivity() throws {
        let activity = try #require(published([
            "type": 3,
            "details": "Adding videos",
            "assets": ["large_image": "servericon"],
            "party": ["id": "abc", "size": [1, 10]],
            "name": "Watch Together",
        ]))
        #expect(activity.type == 3)
        #expect(activity.name == "Watch Together")
        #expect(activity.details == "Adding videos")
        #expect(activity.assets?.largeImage == "servericon")
        #expect(activity.party?.current == 1)
        #expect(activity.party?.maximum == 10)
        #expect(activity.applicationID == application)
    }

    /// Medal's shape: two buttons, and a link on each image.
    @Test("Button labels and image links survive")
    func buttonsAndLinks() throws {
        let activity = try #require(published([
            "name": "Counter-Strike 2 with Medal",
            "type": 0,
            "details": "Clipping Counter-Strike 2",
            "state": "with Medal",
            "buttons": ["Follow on Medal", "Download Medal"],
            "assets": [
                "large_image": "cs2",
                "large_text": "Counter-Strike 2",
                "large_url": "https://medal.tv/games/counter-strike-2?ref=discordrpc",
                "small_image": "medal",
                "small_url": "https://medal.tv/?ref=discordrpc",
            ],
        ]))
        #expect(activity.state == "with Medal")
        #expect(activity.buttons == ["Follow on Medal", "Download Medal"])
        #expect(activity.assets?.largeURL?.host() == "medal.tv")
        #expect(activity.assets?.smallURL?.absoluteString == "https://medal.tv/?ref=discordrpc")
    }

    /// **Milliseconds, whatever the app sent.** Sent as seconds, an elapsed
    /// clock reads as decades — the same trap `Message.sentAt` documents.
    @Test("Seconds are promoted to milliseconds; milliseconds are left alone")
    func timestampUnits() throws {
        let seconds = try #require(published([
            "name": "A", "type": 0, "timestamps": ["start": 1_788_409_502],
        ]))
        #expect(seconds.timestamps?.start == 1_788_409_502_000)

        let millis = try #require(published([
            "name": "A", "type": 0, "timestamps": ["start": 1_788_409_502_552],
        ]))
        #expect(millis.timestamps?.start == 1_788_409_502_552)
    }

    /// Watch Together sends its party id as an array of characters rather than
    /// a string. Anything that is not a plain string is dropped rather than
    /// stringified into nonsense.
    @Test("A party id that is not a string is dropped, not coerced")
    func oddPartyID() throws {
        let activity = try #require(published([
            "name": "A", "type": 0, "party": ["id": ["a", "b"], "size": [2, 8]],
        ]))
        #expect(activity.party?.id == nil)
        #expect(activity.party?.current == 2)
    }

    /// A nameless activity is not published: `name` is required by the gateway
    /// and by the reply's own schema, and the bridge fills it in before this is
    /// ever reached.
    @Test("An activity with no name is refused")
    func namelessIsRefused() {
        #expect(published(["type": 0]) == nil)
        #expect(published(["name": "", "type": 0]) == nil)
    }

    /// A type this client has no name for round-trips rather than becoming
    /// "Playing".
    @Test("An unknown activity type is echoed, not normalised")
    func unknownTypeRoundTrips() throws {
        let activity = try #require(published(["name": "A", "type": 6]))
        #expect(activity.type == 6)
    }
}
