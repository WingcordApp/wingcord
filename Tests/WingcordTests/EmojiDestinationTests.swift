import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Every picker is held to the rule of where its pick goes — Discord's
/// `getEmojiUnavailableReason`, by intention (Alex, 2026-11-18: "a lot of react
/// flyouts are still not nitro gated properly, for example react to status
/// flyout").
@MainActor
@Suite("Emoji destinations")
struct EmojiDestinationTests {

    private func model() throws -> (AppModel, ChannelID, home: GuildID, other: GuildID) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let channelID = try #require(model.selectedChannelID)
        let home = try #require(model.channelIndex.guildID(of: channelID))
        let other = try #require(model.orderedGuildIDs.first { $0 != home && model.guilds[$0] != nil })
        model.guildEmojis[other] = [EmojiRef(id: EmojiID(rawValue: 9_001), name: "foreign")]
        model.guildEmojis[home] = [
            EmojiRef(id: EmojiID(rawValue: 9_002), name: "homegrown"),
            EmojiRef(id: EmojiID(rawValue: 9_003), name: "spinning", isAnimated: true),
        ]
        model.expressionRevision &+= 1
        return (model, channelID, home, other)
    }

    private func section(_ guildID: GuildID, in catalog: ExpressionCatalog) -> ExpressionSection? {
        catalog.sections.first { $0.id == String(guildID.rawValue) }
    }

    @Test("A status's or an activity's reaction goes to a DM: without Nitro no server's emoji is usable")
    func personalLocksEveryServer() throws {
        let (model, _, home, other) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .none)
        let catalog = model.emojiCatalog(for: .personal)
        // The open server is no home in a DM: Discord's PREMIUM_LOCKED.
        #expect(section(home, in: catalog)?.isLocked == true)
        #expect(section(other, in: catalog)?.isLocked == true)
        // Unicode is everybody's.
        let unicode = try #require(catalog.sections.last)
        #expect(!unicode.isLocked)
        // The composer over the same server still offers its own.
        #expect(section(home, in: model.emojiCatalog)?.isLocked == false)
    }

    @Test("With Nitro, every server's emoji, animated included, can go to a DM")
    func personalWithNitro() throws {
        let (model, _, home, other) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .nitro)
        let catalog = model.emojiCatalog(for: .personal)
        #expect(section(home, in: catalog)?.isLocked == false)
        #expect(section(other, in: catalog)?.isLocked == false)
        let animated = section(home, in: catalog)?.items.first { $0.id == "9003" }
        #expect(animated?.isLocked == false)
    }

    @Test("Fake Nitro can't unlock a DM answer, a status or a bio: nothing there is a message it rewrites")
    func fakeNitroLeavesPersonalLocked() async throws {
        try await withAppSettings(\.fakeNitro, \.fakeNitroEmoji) { settings in
            let (model, _, _, other) = try model()
            settings.fakeNitro = true
            settings.fakeNitroEmoji = true
            model.entitlements = AccountEntitlements(premiumTier: .none)
            #expect(section(other, in: model.emojiCatalog)?.isLocked == false, "the composer sends it as a link")
            #expect(section(other, in: model.emojiCatalog(for: .personal))?.isLocked == true)
        }
    }

    @Test("Frequently Used and Favorites carry a locked server's lock")
    func usageSectionsCarryTheLock() throws {
        let (model, _, _, _) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .none)
        var emojis = ExpressionFrecency(now: .now)
        emojis.track("9001", at: .now)
        emojis.track("thumbsup", at: .now)
        model.expressionUsage = ExpressionUsage(
            favoriteEmojis: ["9001"],
            emojis: emojis,
            reactions: ExpressionFrecency(now: .now),
            stickers: ExpressionFrecency(now: .now)
        )
        let catalog = model.withUsageSections(model.emojiCatalog(for: .personal), stickers: false, reacting: false)
        let frequent = catalog.sections.first { $0.id == "usage.frequent" }
        // The foreign one was used, and can't be sent from here: left out.
        #expect(frequent?.items.contains { $0.id == "9001" } == false)
        #expect(frequent?.items.isEmpty == false)
        // A starred one stays starred, and locked.
        let favorite = catalog.sections.first { $0.id == "usage.favorites" }?.items.first { $0.id == "9001" }
        #expect(favorite?.isLocked == true)
    }

    @Test("A server's own page offers its emoji and no other server's; a trait, Unicode only")
    func communityAndUnicodeOnly() throws {
        let (model, _, home, other) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .none)
        let community = model.emojiCatalog(for: .community(home))
        #expect(section(home, in: community)?.isLocked == false)
        // Its animated emoji too: COMMUNITY_CONTENT asks for no Nitro.
        #expect(section(home, in: community)?.items.first { $0.id == "9003" }?.isLocked == false)
        #expect(section(other, in: community) == nil)
        #expect(!community.sections.contains { $0.id.hasPrefix("pack-") })

        let unicode = model.emojiCatalog(for: .unicodeOnly)
        #expect(section(home, in: unicode) == nil)
        #expect(section(other, in: unicode) == nil)
        #expect(!unicode.sections.isEmpty)
    }

    @Test("An activity's five emoji are ones a DM takes")
    func activityRowIsPersonal() throws {
        let (model, _, _, _) = try model()
        model.entitlements = AccountEntitlements(premiumTier: .none)
        var emojis = ExpressionFrecency(now: .now)
        // The open server's own emoji, used most: fine in its channels, not in a DM.
        for _ in 0..<5 { emojis.track("9002", at: .now) }
        model.expressionUsage = ExpressionUsage(
            emojis: emojis,
            reactions: ExpressionFrecency(now: .now),
            stickers: ExpressionFrecency(now: .now)
        )
        let row = model.activityReplyEmoji()
        #expect(row.count == 5)
        #expect(!row.contains { $0.id == "9002" })
    }
}
