import Foundation
import Testing
@testable import WingcordCore

/// A message link is the one URL in a transcript that must **not** open a
/// browser, and the test that matters most here is the one that refuses.
@Suite("Message links")
struct MessageLinkTests {

    @Test("A guild link carries all three ids")
    func guildLink() {
        let link = MessageLink.parse(
            "https://discord.com/channels/494376688257372009/1234567890/9876543210"
        )
        #expect(link?.guildID == GuildID(rawValue: 494_376_688_257_372_009))
        #expect(link?.channelID == ChannelID(rawValue: 1_234_567_890))
        #expect(link?.messageID == MessageID(rawValue: 9_876_543_210))
    }

    @Test("@me is a direct message and belongs to no guild")
    func directMessageLink() {
        let link = MessageLink.parse(
            "https://discord.com/channels/@me/1424759145021837325/1542487081703353040"
        )
        #expect(link != nil)
        #expect(link?.guildID == nil)
        #expect(link?.channelID == ChannelID(rawValue: 1_424_759_145_021_837_325))
    }

    /// Every release channel serves the same account, so a link copied from
    /// canary has to resolve exactly as one copied from stable.
    @Test(
        "Discord's own hosts all resolve",
        arguments: [
            "https://canary.discord.com/channels/@me/1/2",
            "https://ptb.discord.com/channels/@me/1/2",
            "https://discordapp.com/channels/@me/1/2",
            "https://www.discord.com/channels/@me/1/2",
        ]
    )
    func hosts(_ url: String) {
        #expect(MessageLink.parse(url) != nil)
    }

    /// **The security case.** A client that navigates on a hostname it did not
    /// check is a client that can be steered by anybody who can send it a
    /// message — `discord.com.evil.test` ends in the right letters and is a
    /// different site.
    @Test(
        "A look-alike host is not a message link",
        arguments: [
            "https://discord.com.evil.test/channels/@me/1/2",
            "https://notdiscord.com/channels/@me/1/2",
            "https://discord.gg/channels/@me/1/2",
            "https://example.com/channels/@me/1/2",
        ]
    )
    func foreignHosts(_ url: String) {
        #expect(MessageLink.parse(url) == nil)
    }

    @Test(
        "Anything that is not the four-segment shape is not a link",
        arguments: [
            "https://discord.com/channels/@me/1",
            "https://discord.com/channels/@me/1/2/3",
            "https://discord.com/invite/abc",
            "https://discord.com/channels/@me/notanid/2",
            "https://discord.com/channels/@me//2",
            "not a url at all",
        ]
    )
    func rejected(_ url: String) {
        #expect(MessageLink.parse(url) == nil)
    }
}
