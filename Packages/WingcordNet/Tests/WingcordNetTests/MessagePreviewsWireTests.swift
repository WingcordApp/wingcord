import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Message previews as Discord's mobile app asks for them: `POST
/// /channels/preload-messages` with the channels' ids, at most a hundred, and
/// one message per channel back.
@Suite("Message previews on the wire")
struct MessagePreviewsWireTests {
    private static let answer = #"""
    [{"id":"30","channel_id":"7","type":0,"content":"see you there","author":{"id":"5","username":"wren"}},
     {"id":"31","channel_id":"8","type":0,"content":"","author":{"id":"6","username":"alder"},
      "attachments":[{"id":"1","filename":"a.png","url":"https://x/a.png","proxy_url":"https://x/a.png","size":1,"content_type":"image/png"}]}]
    """#

    @Test("The channels go out as strings, and their newest messages come back with their authors")
    func roundTrip() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.answer)
        let page = try await rest.preloadMessages(channelIDs: [ChannelID(rawValue: 7), ChannelID(rawValue: 8)])
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/channels/preload-messages")
        #expect(request.json?.keys.sorted() == ["channel_ids"])
        #expect(request.json?["channel_ids"] as? [String] == ["7", "8"])
        #expect(page.messages.map(\.channelID.rawValue) == [7, 8])
        #expect(page.messages.first?.content == "see you there")
        #expect(page.authors[UserID(rawValue: 6)] != nil)
    }

    @Test("No more than a hundred channels go in one request")
    func limit() async throws {
        let (rest, token) = await RequestRecorder.client(body: "[]")
        _ = try await rest.preloadMessages(channelIDs: (1...150).map { ChannelID(rawValue: UInt64($0)) })
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect((request.json?["channel_ids"] as? [String])?.count == DiscordREST.previewChannelLimit)
    }

    @Test("Nothing to ask about sends nothing")
    func empty() async throws {
        let (rest, token) = await RequestRecorder.client(body: "[]")
        let page = try await rest.preloadMessages(channelIDs: [])
        #expect(page.messages.isEmpty)
        #expect(RequestRecorder.requests(for: token).isEmpty)
    }
}
