import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The card a Nitro Emoji Pack's emoji opens, through the projection its
/// presenter reads — `AppModel.expressionInfo(for:)`.
///
/// **A pack's emoji is not a server's** (Alex, 2026-11-18). The packs used to
/// arrive only with the emoji picker, so one clicked before the picker had ever
/// opened read "an emoji from a server you're not in" until it was.
@MainActor
@Suite("Nitro Emoji Pack card")
struct EmojiPackCardTests {
    private static let thinking = EmojiRef(
        id: EmojiID(rawValue: 1_300_000_000_000_000_001), name: "cattos_thinking", isAnimated: false
    )
    private static let cattos = EmojiPack(
        id: 1_300_000_000_000_000_000,
        name: "Cattos",
        emojis: [EmojiPack.Emoji(id: 1_300_000_000_000_000_001, name: "cattos_thinking", isAnimated: false)]
    )

    private func card(_ emoji: EmojiRef, in model: AppModel) -> ExpressionInfo {
        model.expressionInfo(for: ExpressionInfoRequest(subject: .emoji(emoji), anchor: .zero))
    }

    @Test("Before the packs are in, the card finds out instead of naming a server")
    func beforePacks() {
        let model = AppModel()
        for state in [EmojiPacksLoad.idle, .loading] {
            model.emojiPacksLoad = state
            let info = card(Self.thinking, in: model)
            #expect(info.emojiPack == nil)
            #expect(info.source == nil)
            #expect(!info.detail.contains("server"), "\(state)")
        }
    }

    @Test("Once the packs are in, the card names the pack")
    func afterPacks() throws {
        let model = AppModel()
        model.emojiPacks = [Self.cattos]
        model.emojiPacksLoad = .loaded
        let info = card(Self.thinking, in: model)
        let pack = try #require(info.emojiPack)
        #expect(pack.name == "Cattos")
        #expect(info.detail.contains("Nitro Emoji Pack"))
    }

    @Test("An emoji in no pack still goes to the server route once the packs are in")
    func notAPacksEmoji() {
        let model = AppModel()
        model.emojiPacks = [Self.cattos]
        model.emojiPacksLoad = .loaded
        let stranger = EmojiRef(id: EmojiID(rawValue: 42), name: "stranger", isAnimated: false)
        let info = card(stranger, in: model)
        #expect(info.emojiPack == nil)
        #expect(info.detail.contains("server"))
    }
}
