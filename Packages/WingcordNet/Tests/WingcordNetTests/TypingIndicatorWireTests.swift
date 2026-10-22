import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `typing_indicator_style` both ways: on `TYPING_START`, and in the account's
/// `PATCH /users/@me` — the shapes of Discord's module `870600`.
struct TypingIndicatorWireTests {

    private func update(_ frame: String) throws -> GatewayUpdate? {
        let decoded = try JSONDecoder().decode(GatewayFrame.self, from: Data(frame.utf8))
        return GatewayUpdate(decoded.payload)
    }

    @Test("A typer's indicator arrives with their TYPING_START, custom emoji by id")
    func decodesTypingStart() throws {
        let frame = #"""
        {"op":0,"t":"TYPING_START","s":7,"d":{"channel_id":"1100","user_id":"2200","timestamp":1792507300,
         "typing_indicator_style":{"emojis":[{"custom_emoji_id":"123456789010468812","animated":true},{"unicode_emoji":"❤️"}],
         "animation":3,"typing_suggestion":1}}}
        """#
        guard case .typingStarted(let channel, let user, _, let style)? = try update(frame) else {
            Issue.record("expected a typing start")
            return
        }
        #expect(channel == ChannelID(rawValue: 1100))
        #expect(user == UserID(rawValue: 2200))
        let worn = try #require(style)
        #expect(worn.emojis == [
            EmojiRef(id: EmojiID(rawValue: 123_456_789_010_468_812), name: "", isAnimated: true),
            EmojiRef(name: "❤️"),
        ])
        #expect(worn.animation == .wave)
        #expect(worn.suggestion == .yapping)
    }

    @Test("No style, or a plain one, is the plain indicator")
    func plainTypingStart() throws {
        let none = #"{"op":0,"t":"TYPING_START","s":8,"d":{"channel_id":"1","user_id":"2","timestamp":1792507300}}"#
        guard case .typingStarted(_, _, _, let style)? = try update(none) else {
            Issue.record("expected a typing start")
            return
        }
        #expect(style == nil)
        let plain = #"""
        {"op":0,"t":"TYPING_START","s":9,"d":{"channel_id":"1","user_id":"2","timestamp":1792507300,
         "typing_indicator_style":{"emojis":[],"animation":0,"typing_suggestion":0}}}
        """#
        guard case .typingStarted(_, _, _, let plainStyle)? = try update(plain) else {
            Issue.record("expected a typing start")
            return
        }
        #expect(plainStyle == nil)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test("The write sends a custom emoji's id alone, and the numbers")
    func encodesPatch() throws {
        let style = TypingIndicatorStyle(
            emojis: [EmojiRef(id: EmojiID(rawValue: 42), name: "blob", isAnimated: true), EmojiRef(name: "❤️")],
            animation: .ring,
            suggestion: .daydreaming
        )
        let body = try json(CurrentUserPatch(typing_indicator_style: .set(style)))
        #expect(body.keys.sorted() == ["typing_indicator_style"])
        let sent = try #require(body["typing_indicator_style"] as? [String: Any])
        #expect(sent["animation"] as? Int == 2)
        #expect(sent["typing_suggestion"] as? Int == 6)
        let emojis = try #require(sent["emojis"] as? [[String: Any]])
        #expect(emojis.count == 2)
        #expect(emojis[0]["custom_emoji_id"] as? String == "42")
        #expect(emojis[0]["unicode_emoji"] == nil)
        #expect(emojis[1]["unicode_emoji"] as? String == "❤️")
        #expect(emojis[1]["custom_emoji_id"] == nil)
    }

    @Test("Removing the indicator sends null; leaving it alone sends nothing")
    func clearsAndLeaves() throws {
        let cleared = try json(CurrentUserPatch(typing_indicator_style: .cleared))
        #expect(cleared["typing_indicator_style"] is NSNull)
        let untouched = try json(CurrentUserPatch(global_name: .set("alex")))
        #expect(untouched["typing_indicator_style"] == nil)
    }
}
