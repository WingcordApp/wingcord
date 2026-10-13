import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A Streaming activity's `url`, which Watch Stream opens.
@Suite("Streaming activities")
struct StreamingActivityDecodeTests {

    @Test("The stream's link is read, and is what Watch opens")
    func streamURL() throws {
        let json = #"{"type":1,"name":"Twitch","details":"Ranked grind","state":"Valorant","url":"https://www.twitch.tv/somebody"}"#
        let activity = try #require(try DiscordREST.decoder.decode(ActivityDTO.self, from: Data(json.utf8)).domain)
        #expect(activity.kind == .streaming)
        #expect(activity.url == URL(string: "https://www.twitch.tv/somebody"))
        #expect(activity.watchURL == activity.url)
    }

    @Test("An activity without one has none")
    func noURL() throws {
        let json = #"{"type":0,"name":"Celeste"}"#
        let activity = try #require(try DiscordREST.decoder.decode(ActivityDTO.self, from: Data(json.utf8)).domain)
        #expect(activity.url == nil)
        #expect(activity.watchURL == nil)
    }
}
