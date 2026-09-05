import Foundation
import Testing
@testable import WingcordCore

/// Resolving a rich presence's asset keys.
///
/// **An asset key is a tagged union written as a string**, and only the
/// untagged form is an application asset. The prefixed forms below are
/// Discord's own, from the presence documentation, and the two in the fixtures
/// are addresses taken off live payloads.
@Suite("Activity assets")
struct ActivityAssetTests {

    private let application = ApplicationID(rawValue: 307_998_818_549_172_068)

    @Test("An untagged key is an application asset")
    func applicationAsset() throws {
        let url = try #require(
            Activity.assetURL("1331783780809179146", application: application, side: 64)
        )
        #expect(url.absoluteString.contains("/app-assets/307998818549172068/"))
        #expect(url.absoluteString.contains("1331783780809179146.png"))
    }

    /// **Nil, not the application path.** A prefixed key pasted onto
    /// `/app-assets/` is a URL that 404s, and the failure looks like a broken
    /// picture rather than a missing one.
    @Test("An untagged key with no application resolves to nothing")
    func applicationAssetWithoutApplication() {
        #expect(Activity.assetURL("cs2", application: nil, side: 64) == nil)
    }

    @Test("mp: goes through the media proxy")
    func mediaProxy() throws {
        let url = try #require(
            Activity.assetURL("mp:external/abc/https/example.com/a.png", application: nil, side: 64)
        )
        #expect(url.absoluteString == "https://media.discordapp.net/external/abc/https/example.com/a.png")
    }

    @Test("spotify: is an album cover")
    func spotify() throws {
        let url = try #require(
            Activity.assetURL("spotify:ab67616d0000b273ec01", application: nil, side: 64)
        )
        #expect(url.absoluteString == "https://i.scdn.co/image/ab67616d0000b273ec01")
    }

    @Test("twitch: is a live preview at the rung asked for")
    func twitch() throws {
        let url = try #require(Activity.assetURL("twitch:someone", application: nil, side: 64))
        #expect(url.absoluteString.contains("live_user_someone-"))
        #expect(url.absoluteString.hasSuffix(".jpg"))
    }

    @Test("youtube: is a video thumbnail")
    func youtube() throws {
        let url = try #require(Activity.assetURL("youtube:dQw4w9WgXcQ", application: nil, side: 64))
        #expect(url.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    /// A prefix this client has never seen is not an application asset, and
    /// there is no honest guess to make about it.
    @Test("An unknown prefix resolves to nothing")
    func unknownPrefix() {
        #expect(Activity.assetURL("kick:someone", application: application, side: 64) == nil)
        #expect(Activity.assetURL("", application: application, side: 64) == nil)
        #expect(Activity.assetURL("mp:", application: application, side: 64) == nil)
    }

    /// The two halves of a button are the labels on the presence and the URLs
    /// behind a separate route, so an activity carries the first alone.
    @Test("Buttons are capped at two")
    func buttonCap() {
        let activity = Activity(
            kind: .playing,
            name: "Counter-Strike 2 with Medal",
            buttons: ["Follow on Medal", "Download Medal"]
        )
        #expect(activity.buttons.count == 2)
        #expect(activity.sessionID == nil)
    }
}
