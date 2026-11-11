import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The emoji and sticker halves of the frecency blob — Discord's
/// FrecencyUserSettings fields 3, 4, 5, 6 and 13.
@Suite("Emoji and sticker frecency")
struct ExpressionUsageProtoTests {

    @Test("Favourite emoji go out unpacked and come back in order; an empty list is an empty field")
    func favoriteEmojis() {
        let field = FrecencyProto.favoriteEmojisField(["thumbsup", "1234567890", "eyes"])
        #expect(FrecencyProto.favoriteEmojis(in: field) == ["thumbsup", "1234567890", "eyes"])
        let cleared = FrecencyProto.favoriteEmojisField([])
        #expect(!cleared.isEmpty)
        #expect(FrecencyProto.favoriteEmojis(in: cleared).isEmpty)
    }

    @Test("Favourite stickers go out packed fixed64 and come back")
    func favoriteStickers() {
        let ids: [UInt64] = [749_054_660_769_218_631, 1]
        #expect(FrecencyProto.favoriteStickerIDs(in: FrecencyProto.favoriteStickersField(ids)) == ids)
    }

    @Test("A sticker table keeps its fixed64 keys; an emoji table its strings")
    func useTables() {
        let use = SoundFrecency.Use(totalUses: 3, recentUses: [1_700_000_000_000, 1_700_000_100_000], frecency: 150, score: 200)
        let stickers = FrecencyProto.useField(FrecencyProto.Field.stickerFrecency, ["749054660769218631": use], fixedKeys: true)
        let back = FrecencyProto.useHistory(in: stickers, field: FrecencyProto.Field.stickerFrecency)
        #expect(back["749054660769218631"]?.totalUses == 3)
        #expect(back["749054660769218631"]?.recentUses == use.recentUses)
        let emojis = FrecencyProto.useField(FrecencyProto.Field.emojiReactionFrecency, ["100": use], fixedKeys: false)
        #expect(FrecencyProto.useHistory(in: emojis, field: FrecencyProto.Field.emojiReactionFrecency)["100"]?.totalUses == 3)
        // Another field's table is not this one's.
        #expect(FrecencyProto.useHistory(in: emojis, field: FrecencyProto.Field.emojiFrecency).isEmpty)
    }

    @Test("One blob reads into every list and table")
    func wholeBlob() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let stamp = UInt64(now.timeIntervalSince1970 * 1000) - 60_000
        let use = SoundFrecency.Use(totalUses: 2, recentUses: [stamp])
        var blob = Data()
        blob += FrecencyProto.favoriteStickersField([42])
        blob += FrecencyProto.favoriteEmojisField(["heart"])
        blob += FrecencyProto.useField(FrecencyProto.Field.emojiFrecency, ["fire": use], fixedKeys: false)
        blob += FrecencyProto.useField(FrecencyProto.Field.emojiReactionFrecency, ["eyes": use], fixedKeys: false)
        let usage = DiscordREST.expressionUsage(base64: blob.base64EncodedString(), now: now)
        #expect(usage.favoriteStickerIDs == [42])
        #expect(usage.favoriteEmojis == ["heart"])
        #expect(usage.emojis.ranked == ["fire"])
        #expect(usage.reactions.ranked == ["eyes"])
        #expect(usage.quickReactions(now: now) { _ in true }.first == "eyes")
    }
}
