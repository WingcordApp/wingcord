import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A reaction is held to Discord's own emoji rule, which Fake Nitro cannot
/// bend: Fake Nitro sends a message's emoji as a link, but a reaction names
/// the emoji itself (Alex, 2026-10-26: it let him react with external emoji
/// he could not use).
@MainActor
@Suite("Reaction emoji gate")
struct ReactionEmojiGateTests {

    private func model() throws -> (AppModel, ChannelID, home: GuildID, other: GuildID) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let channelID = try #require(model.selectedChannelID)
        let home = try #require(model.channelIndex.guildID(of: channelID))
        // Another server the reader is in, with an emoji of its own and one of
        // the home server's — the demo gives emoji to its opening server only.
        let other = try #require(model.orderedGuildIDs.first { $0 != home && model.guilds[$0] != nil })
        model.guildEmojis[other] = [EmojiRef(id: EmojiID(rawValue: 9_001), name: "foreign")]
        if model.guildEmojis[home]?.isEmpty != false {
            model.guildEmojis[home] = [EmojiRef(id: EmojiID(rawValue: 9_002), name: "homegrown")]
        }
        model.expressionRevision &+= 1
        return (model, channelID, home, other)
    }

    @Test("Without Nitro, Fake Nitro unlocks the composer's emoji but never a reaction's")
    func fakeNitroDoesNotUnlockReactions() throws {
        let (model, channelID, home, other) = try model()
        let saved = (AppSettings.shared.fakeNitro, AppSettings.shared.fakeNitroEmoji)
        defer { (AppSettings.shared.fakeNitro, AppSettings.shared.fakeNitroEmoji) = saved }
        AppSettings.shared.fakeNitro = true
        AppSettings.shared.fakeNitroEmoji = true
        model.entitlements = AccountEntitlements(premiumTier: .none)

        let compose = model.emojiCatalog.sections.first { $0.id == String(other.rawValue) }
        #expect(compose?.isLocked == false, "the composer sends it as a link")
        let reaction = model.reactionEmojiCatalog(in: channelID).sections
        #expect(reaction.first { $0.id == String(other.rawValue) }?.isLocked == true)
        #expect(reaction.first { $0.id == String(home.rawValue) }?.isLocked == false)

        let foreign = try #require(model.guildEmojis[other]?.first { !$0.isAnimated })
        #expect(!model.canReact(with: foreign, in: channelID))
        if let own = model.guildEmojis[home]?.first(where: { !$0.isAnimated }) {
            #expect(model.canReact(with: own, in: channelID))
        }
        #expect(model.canReact(with: EmojiRef(name: "👍"), in: channelID))
    }

    @Test("With Nitro, another server's emoji is a reaction like any other")
    func nitroReacts() throws {
        let (model, channelID, _, other) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .nitro)
        let foreign = try #require(model.guildEmojis[other]?.first)
        // The channel's own bit still has a say; where it allows external
        // emoji, Nitro is all a reaction needs.
        if model.permissionGate.permissions(in: channelID).contains(.useExternalEmojis) {
            #expect(model.canReact(with: foreign, in: channelID))
        }
    }
}
