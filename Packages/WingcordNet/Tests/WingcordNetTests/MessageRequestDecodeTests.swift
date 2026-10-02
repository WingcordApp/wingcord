import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A private channel's standing as a message request, read off the channel.
struct MessageRequestDecodeTests {

    private func channel(_ json: String) throws -> Channel {
        try DiscordREST.decoder.decode(ChannelDTO.self, from: Data(json.utf8)).domain()
    }

    @Test func aRequestAndSpamAreReadOffTheChannel() throws {
        let request = try channel(#"""
        {"id":"1412835335932594548","type":1,"last_message_id":"1550268225628119758",
         "is_message_request":true,"is_message_request_timestamp":"2026-09-17T22:12:27.580000+00:00",
         "is_spam":false,"recipients":[{"id":"260445420521720605","username":".glassmage"}]}
        """#)
        #expect(request.messageRequest == .pending)

        let spam = try channel(#"{"id":"1","type":1,"is_message_request":true,"is_spam":true}"#)
        #expect(spam.messageRequest == .spam)
    }

    /// **Captured** — `message request accepted.har`, the `PUT` that accepted
    /// it: the conversation comes back carrying neither field, which is what
    /// makes decoding it the acceptance.
    @Test func theAcceptedAnswerIsAnOrdinaryConversation() throws {
        let accepted = try channel(#"""
        {"id":"1412835335932594548","type":1,"last_message_id":"1550268225628119758","flags":0,
         "recipients":[{"id":"260445420521720605","username":".glassmage","global_name":"Glassmage",
         "avatar":"09b58d1e7d9cbbb676c75b2184cc30f5","discriminator":"0","public_flags":64}]}
        """#)
        #expect(accepted.messageRequest == nil)
        #expect(accepted.recipientIDs.map(\.rawValue) == [260_445_420_521_720_605])
    }
}
