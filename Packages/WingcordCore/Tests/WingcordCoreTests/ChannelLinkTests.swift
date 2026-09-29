import Foundation
import Testing
@testable import WingcordCore

/// A link into this account is the one URL in a transcript that must **not**
/// open a browser, and the tests that matter most here are the ones that
/// refuse.
@Suite("Channel links")
struct ChannelLinkTests {

    @Test("A message link carries all three ids")
    func messageLink() {
        let link = ChannelLink.parse(
            "https://discord.com/channels/494376688257372009/1234567890/9876543210"
        )
        #expect(link?.guildID == GuildID(rawValue: 494_376_688_257_372_009))
        #expect(link?.channelID == ChannelID(rawValue: 1_234_567_890))
        #expect(link?.messageID == MessageID(rawValue: 9_876_543_210))
        #expect(link?.threadID == nil)
    }

    /// Discord draws `/channels/{guild}/{channel}` as a channel chip, the same
    /// one a `<#id>` mention draws.
    @Test("A channel link has no message")
    func channelLink() {
        let link = ChannelLink.parse("https://discord.com/channels/494376688257372009/1234567890")
        #expect(link?.channelID == ChannelID(rawValue: 1_234_567_890))
        #expect(link?.messageID == nil)
        #expect(link?.destinationID == ChannelID(rawValue: 1_234_567_890))
    }

    @Test("A trailing slash is not a segment")
    func trailingSlash() {
        let link = ChannelLink.parse("https://discord.com/channels/1/2/3/")
        #expect(link?.messageID == MessageID(rawValue: 3))
    }

    @Test("@me is a direct message and belongs to no guild")
    func directMessageLink() {
        let link = ChannelLink.parse(
            "https://discord.com/channels/@me/1424759145021837325/1542487081703353040"
        )
        #expect(link != nil)
        #expect(link?.guildID == nil)
        #expect(link?.channelID == ChannelID(rawValue: 1_424_759_145_021_837_325))
    }

    /// Discord's `mediaPostLink`: the forum, then the post, then the message.
    /// Following it goes to the post.
    @Test("A forum post link names the forum and goes to the post")
    func postLink() {
        let link = ChannelLink.parse("https://discord.com/channels/1/2/threads/3/4")
        #expect(link?.channelID == ChannelID(rawValue: 2))
        #expect(link?.threadID == ChannelID(rawValue: 3))
        #expect(link?.messageID == MessageID(rawValue: 4))
        #expect(link?.destinationID == ChannelID(rawValue: 3))
    }

    /// Every release channel serves the same account, so a link copied from
    /// canary has to resolve exactly as one copied from stable.
    @Test(
        "Discord's own hosts all resolve",
        arguments: [
            "https://canary.discord.com/channels/@me/1/2",
            "https://ptb.discord.com/channels/@me/1/2",
            "https://discordapp.com/channels/@me/1/2",
            "https://canary.discordapp.com/channels/@me/1/2",
            "https://www.discord.com/channels/@me/1/2",
        ]
    )
    func hosts(_ url: String) {
        #expect(ChannelLink.parse(url) != nil)
    }

    /// **The security case.** A client that navigates on a hostname it did not
    /// check is a client that can be steered by anybody who can send it a
    /// message — `discord.com.evil.test` ends in the right letters and is a
    /// different site.
    @Test(
        "A look-alike host is not a link into the account",
        arguments: [
            "https://discord.com.evil.test/channels/@me/1/2",
            "https://notdiscord.com/channels/@me/1/2",
            "https://discord.gg/channels/@me/1/2",
            "https://example.com/channels/@me/1/2",
            // Discord's pattern is https only.
            "http://discord.com/channels/@me/1/2",
        ]
    )
    func foreignHosts(_ url: String) {
        #expect(ChannelLink.parse(url) == nil)
    }

    @Test(
        "Anything outside Discord's shapes stays a plain link",
        arguments: [
            "https://discord.com/channels/@me",
            "https://discord.com/channels/123",
            "https://discord.com/channels/@me/1/2/3",
            "https://discord.com/channels/1/2/threads/3",
            "https://discord.com/channels/@me/2/threads/3/4",
            "https://discord.com/invite/abc",
            "https://discord.com/channels/@me/notanid/2",
            "https://discord.com/channels/1/shop",
            "https://discord.com/channels/@me//2",
            "not a url at all",
        ]
    )
    func rejected(_ url: String) {
        #expect(ChannelLink.parse(url) == nil)
    }
}
