import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The reply bar's @ OFF on the wire — Discord's `getSendMessageOptionsForReply`
/// and its edit, which keeps a quiet reply quiet.
@Suite("Quiet replies on the wire")
struct QuietReplyWireTests {

    private let channel = ChannelID(rawValue: 9)
    private static let sent = #"{"id":"2","channel_id":"9","content":"hey","author":{"id":"5","username":"alex"}}"#

    @Test("A reply that pings sends no allowed_mentions")
    func pingingReply() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.sendMessage(
            in: channel, content: "hey", nonce: "1", replyingTo: MessageID(rawValue: 1)
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["allowed_mentions"] == nil)
        #expect(request.json?["message_reference"] != nil)
    }

    @Test("A quiet reply parses every mention but the replied-to author")
    func quietReply() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.sendMessage(
            in: channel, content: "hey", nonce: "1",
            replyingTo: MessageID(rawValue: 1), pingsRepliedAuthor: false
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        let mentions = try #require(request.json?["allowed_mentions"] as? [String: Any])
        #expect(mentions["parse"] as? [String] == ["users", "roles", "everyone"])
        #expect(mentions["replied_user"] as? Bool == false)
    }

    @Test("A message that is not a reply never says anything about replies")
    func plainMessage() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.sendMessage(in: channel, content: "hey", nonce: "1", pingsRepliedAuthor: false)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["allowed_mentions"] == nil)
    }

    @Test("Editing a quiet reply sends the quiet mentions again")
    func quietEdit() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.editMessage(MessageID(rawValue: 2), in: channel, content: "hey!", keepsReplyQuiet: true)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        let mentions = try #require(request.json?["allowed_mentions"] as? [String: Any])
        #expect(mentions["replied_user"] as? Bool == false)
    }
}
