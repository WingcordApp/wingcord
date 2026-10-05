import Foundation
import Testing
@testable import WingcordCore

/// Discord's tag beside an author's name (`812299`): decided by the message,
/// in Discord's order.
@Suite("Author tags")
struct AuthorTagTests {
    private let author = UserID(rawValue: 5)

    private func message(
        kind: MessageKind = .default,
        flags: MessageFlags = [],
        referenceGuild: GuildID? = nil,
        author: UserID? = nil
    ) -> Message {
        let reference = referenceGuild.map {
            MessageReference(messageID: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 2), guildID: $0)
        }
        return Message(
            id: MessageID(rawValue: 10),
            channelID: ChannelID(rawValue: 3),
            authorID: author ?? self.author,
            kind: kind,
            flags: flags,
            payload: reference.map { MessagePayload(reference: $0) }
        )
    }

    private func tag(_ message: Message, isSystem: Bool = false, isBot: Bool = false,
                     verified: Bool = false, owner: UserID? = nil) -> AuthorTag? {
        AuthorTag.resolve(message: message, isSystem: isSystem, isBot: isBot, isVerifiedBot: verified, postOwnerID: owner)
    }

    @Test("Discord's system account is OFFICIAL, with its check")
    func system() {
        #expect(tag(message(), isSystem: true) == .official)
        #expect(AuthorTag.official.label == "✓ OFFICIAL")
        #expect(AuthorTag.official.spokenLabel == "Official Discord Message")
    }

    @Test("A crosspost is SERVER, or OFFICIAL out of Discord's own server or by its account")
    func crossposts() {
        let other = message(flags: .isCrosspost, referenceGuild: GuildID(rawValue: 77))
        #expect(other.isCrosspost)
        #expect(tag(other, isBot: true) == .server)
        let discord = message(flags: .isCrosspost, referenceGuild: AuthorTag.discordGuildID)
        #expect(tag(discord) == .official)
        let byAccount = message(
            flags: .isCrosspost, referenceGuild: GuildID(rawValue: 77), author: AuthorTag.discordAnnouncementsUserID
        )
        #expect(tag(byAccount) == .official)
        // A reply is not a crosspost, flag or not.
        #expect(!message(kind: .reply, flags: .isCrosspost, referenceGuild: GuildID(rawValue: 77)).isCrosspost)
    }

    @Test("An app is APP, checked where verified; a post's author is OP")
    func appAndOP() {
        #expect(tag(message(), isBot: true, verified: true) == .app(verified: true))
        #expect(AuthorTag.app(verified: false).label == "APP")
        #expect(tag(message(), owner: author) == .originalPoster)
        #expect(tag(message(), owner: UserID(rawValue: 9)) == nil)
    }
}
