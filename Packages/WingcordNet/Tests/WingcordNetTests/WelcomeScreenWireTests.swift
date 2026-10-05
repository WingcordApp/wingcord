import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The Welcome Screen's one route, read and patched as Discord's `225315`
/// reads and patches it, and the invite that carries one.
@Suite("Welcome Screen on the wire")
struct WelcomeScreenWireTests {

    private let guild = GuildID(rawValue: 1)

    private static let screen = """
    {"description":"A place for sailors",
     "welcome_channels":[
       {"channel_id":"10","description":"Say hi","emoji_id":null,"emoji_name":"👋"},
       {"channel_id":"11","description":"Read the news","emoji_id":"77","emoji_name":"boat"},
       {"description":"no channel, so no option"}
     ]}
    """

    @Test("The answer reads as the description and its channels, dropping one with no channel")
    func reads() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: Self.screen)
        let screen = try await rest.welcomeScreen(of: guild)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/guilds/1/welcome-screen")

        #expect(screen.description == "A place for sailors")
        #expect(screen.channels.count == 2)
        #expect(screen.channels[0] == WelcomeScreen.Channel(
            channelID: ChannelID(rawValue: 10), description: "Say hi", emojiName: "👋"
        ))
        #expect(screen.channels[1].emojiID == EmojiID(rawValue: 77))
        #expect(!screen.isEmpty)
    }

    @Test("Disable sends enabled false and nothing else")
    func disable() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: Self.screen)
        _ = try await rest.disableWelcomeScreen(in: guild)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/guilds/1/welcome-screen")
        #expect(request.json?.keys.sorted() == ["enabled"])
        #expect(request.json?["enabled"] as? Bool == false)
    }

    @Test("A move sends the whole list as it was read, and only the list")
    func channels() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: Self.screen)
        _ = try await rest.setWelcomeChannels(
            [
                WelcomeScreen.Channel(channelID: ChannelID(rawValue: 11), description: "Read the news",
                                      emojiID: EmojiID(rawValue: 77), emojiName: "boat"),
                WelcomeScreen.Channel(channelID: ChannelID(rawValue: 10), description: "Say hi", emojiName: "👋"),
            ],
            in: guild
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?.keys.sorted() == ["welcome_channels"])
        let sent = try #require(request.json?["welcome_channels"] as? [[String: Any]])
        #expect(sent.map { $0["channel_id"] as? String } == ["11", "10"])
        #expect(sent[0]["emoji_id"] as? String == "77")
        #expect(sent[0]["emoji_name"] as? String == "boat")
        #expect(sent[1]["emoji_name"] as? String == "👋")
    }

    @Test("Taking the last channel out turns the screen off in the same write")
    func lastChannelDisables() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: #"{"welcome_channels":[]}"#)
        let screen = try await rest.setWelcomeChannels([], in: guild, disables: true)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["enabled"] as? Bool == false)
        #expect((request.json?["welcome_channels"] as? [Any])?.isEmpty == true)
        #expect(screen.isEmpty)
    }

    @Test("An invite's guild carries its Welcome Screen and features into the acceptance")
    func inviteCarriesTheScreen() async throws {
        let body = """
        {"code":"sail","type":0,"new_member":true,"guild_id":"1",
         "guild":{"id":"1","name":"Sailors","features":["COMMUNITY","WELCOME_SCREEN_ENABLED"],
                  "welcome_screen":\(Self.screen)}}
        """
        let (rest, _) = await RequestRecorder.client(body: body)
        let acceptance = try await rest.acceptInvite("sail", sessionID: "s")
        #expect(acceptance.welcomeScreen?.channels.count == 2)
        #expect(acceptance.features.contains("WELCOME_SCREEN_ENABLED"))
    }
}
