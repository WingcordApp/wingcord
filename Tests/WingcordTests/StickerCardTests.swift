import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The card a sticker in a message opens, through the projection its presenter
/// reads — `AppModel.expressionInfo(for:)`.
///
/// **A stock sticker is not a server's.** Before Discord's packs were filed on
/// the store, clicking one before ever opening the picker fell through to the
/// source route and read "a custom sticker from a server you are not in".
@MainActor
@Suite("Stock sticker card")
struct StickerCardTests {

    /// Discord's Mallow pack as `GET /sticker-packs` sent it in
    /// `stock stickers.har`: its first eight stickers, then Nervous, which sits
    /// tenth — the one the capture's popout was opened on.
    private static let mallow = StickerPack(
        id: "796138864937746317",
        name: "Mallow The Rascal",
        coverStickerID: 796_140_731_257_499_135,
        stickers: [
            StickerRef(id: 796_140_620_112_597_735, name: "Happy", format: .lottie),
            StickerRef(id: 796_140_638_096_360_418, name: "Sad", format: .lottie),
            StickerRef(id: 796_140_656_942_494_018, name: "Wink", format: .lottie),
            StickerRef(id: 796_140_687_640_496_565, name: "Typing", format: .lottie),
            StickerRef(id: 796_140_711_719_820_833, name: "Idea", format: .lottie),
            StickerRef(id: 796_140_731_257_499_135, name: "Eyebrows", format: .lottie),
            StickerRef(id: 796_140_753_146_201_133, name: "Frustrated", format: .lottie),
            StickerRef(id: 796_140_775_899_495_844, name: "Excited", format: .lottie),
            StickerRef(id: 796_140_819_577_969_879, name: "Nervous", format: .lottie),
        ]
    )

    private static let nervous = StickerRef(
        id: 796_140_819_577_969_879, name: "Nervous", format: .lottie
    )

    private func card(_ sticker: StickerRef, in model: AppModel) -> ExpressionInfo {
        model.expressionInfo(for: ExpressionInfoRequest(subject: .sticker(sticker), anchor: .zero))
    }

    @Test("A stock sticker names its pack, with no server behind it")
    func stockSticker() throws {
        let model = AppModel()
        model.installStandardStickerPacks([Self.mallow])

        let info = card(Self.nervous, in: model)
        let pack = try #require(info.pack)
        #expect(pack.name == "Mallow The Rascal")
        #expect(pack.isOffered)
        #expect(pack.sectionID == ExpressionSection.stickerPackID(Self.mallow.id))
        #expect(info.source == nil)
        #expect(!info.detail.contains("server"))
        #expect(info.sticker == Self.nervous)
    }

    /// Discord's pick, and what its popout showed in the capture: the pack's
    /// first four, less the one clicked, three at most.
    @Test("The samples are the pack's first three that are not the clicked one")
    func samples() {
        let model = AppModel()
        model.installStandardStickerPacks([Self.mallow])

        #expect(card(Self.nervous, in: model).pack?.samples.map(\.name) == ["Happy", "Sad", "Wink"])
        let sad = Self.mallow.stickers[1]
        #expect(card(sad, in: model).pack?.samples.map(\.name) == ["Happy", "Wink", "Typing"])
    }

    @Test("A pack Discord no longer offers is named and not offered")
    func retiredPack() {
        let model = AppModel()
        model.stickerLookups[Self.nervous.id] = .standard(Self.mallow, isOffered: false)

        let pack = card(Self.nervous, in: model).pack
        #expect(pack?.name == "Mallow The Rascal")
        #expect(pack?.isOffered == false)
    }

    @Test("While the lookup runs, the card says so rather than guessing")
    func resolving() {
        let model = AppModel()
        model.stickerLookups[Self.nervous.id] = .resolving

        let info = card(Self.nervous, in: model)
        #expect(info.pack == nil)
        #expect(info.detail == "Finding out where this came from…")
    }

    @Test("One of the reader's own servers' stickers is theirs, not a pack's")
    func residentGuildSticker() {
        let model = AppModel()
        model.installStandardStickerPacks([Self.mallow])
        let wave = StickerRef(id: 1_107_300_523_452_371_141, name: "wave", format: .png)
        model.guildStickers[GuildID(rawValue: 960_000_000_000_000_001)] = [wave]

        let info = card(wave, in: model)
        #expect(info.pack == nil)
        #expect(info.detail == "A custom sticker from one of your servers.")
    }

    /// Every sticker in every pack is filed under its pack, once.
    @Test("The pack index covers every sticker")
    func index() {
        let model = AppModel()
        model.installStandardStickerPacks([Self.mallow])
        #expect(model.standardPackIDByStickerID.count == Self.mallow.stickers.count)
        #expect(Set(model.standardPackIDByStickerID.values) == [Self.mallow.id])
        #expect(model.defaultStickerPacks.map(\.id) == [ExpressionSection.stickerPackID(Self.mallow.id)])
    }
}
