import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /stickers/{id}` and the pack object — what tells one of Discord's own
/// stickers from a server's, which a message's `sticker_items` never do.
///
/// Every payload here is the response body from `stock stickers.har`, escapes
/// and all; the pack is trimmed to its first five stickers, never re-framed.
@Suite("Sticker details")
struct StickerDetailDecodeTests {

    private func decodeSticker(_ json: String) throws -> StickerDetail {
        try JSONDecoder().decode(StickerDTO.self, from: Data(json.utf8)).detail
    }

    /// The Lottie sticker the popout was opened on.
    private let nervous = #"""
    {"id":"796140819577969879","name":"Nervous","tags":"mallow, nervous, nervously, 😰, 😓, :nervous, yikes, anxious, anxiety, sweat, sweats, sweating, :sweat","type":1,"format_type":3,"description":"Mallow's expression becomes anxious","asset":"","pack_id":"796138864937746317","sort_value":100}
    """#

    /// An APNG one, from a different pack.
    private let what = #"""
    {"id":"831571151538844088","name":"What","tags":"melty chihuahua, what, confused, huh, confusion, huh, wut, wot, wat, quê, quê?, 🐶, 🐕, 🐕‍🦺","type":1,"format_type":2,"description":"Melty Chihuahua slides over like a snail, it's confusing","asset":"","pack_id":"831563211708851185","sort_value":100}
    """#

    @Test("A standard sticker names its pack")
    func standardSticker() throws {
        let detail = try decodeSticker(nervous)
        #expect(detail.isStandard)
        #expect(detail.packID == "796138864937746317")
        #expect(detail.guildID == nil)
        #expect(detail.sticker.id == 796_140_819_577_969_879)
        #expect(detail.sticker.name == "Nervous")
        #expect(detail.sticker.format == .lottie)
    }

    @Test("The format comes through for an APNG sticker")
    func apngSticker() throws {
        let detail = try decodeSticker(what)
        #expect(detail.isStandard)
        #expect(detail.packID == "831563211708851185")
        #expect(detail.sticker.format == .apng)
    }

    /// A server's sticker is `type` 2 with a `guild_id` and no pack. Built from
    /// the documented object rather than a capture, and it only has to prove
    /// the one thing the card branches on.
    @Test("A server's sticker is not standard")
    func guildSticker() throws {
        let detail = try decodeSticker(#"""
        {"id":"1107300523452371141","name":"wave","type":2,"format_type":1,"guild_id":"960000000000000001","available":true}
        """#)
        #expect(!detail.isStandard)
        #expect(detail.packID == nil)
        #expect(detail.guildID == GuildID(rawValue: 960_000_000_000_000_001))
    }

    /// The first pack of `GET /sticker-packs`, cut to five stickers.
    private let mallow = #"""
    {"id": "796138864937746317", "sku_id": "796138864936487845", "name": "Mallow The Rascal", "description": "Mallow is a quick-tempered but squishy rabbit who would go to battle for her friends.", "stickers": [{"id": "796140620112597735", "name": "Happy", "tags": "mallow, happy, feliz, grin, smile, smiling, :), :D, :],c:, 😊, 😄, 😅, 😆, 😌, 🤗, 😁, 🙂, 😀, 😃, 😺, 😸, :happy, :feliz, :grin", "type": 1, "format_type": 3, "description": "Mallow dances a joyful jig", "asset": "", "pack_id": "796138864937746317", "sort_value": 4}, {"id": "796140638096360418", "name": "Sad", "tags": "mallow, sad, triste, feelsbad, feels bad man, bummed, bummer, depressed, :<, :(, :[, :c, D:, 😥, 😢, 😭, 🙁, ☹️, :sad, sigh, rip", "type": 1, "format_type": 3, "description": "Mallow sighs downtrodden", "asset": "", "pack_id": "796138864937746317", "sort_value": 100}, {"id": "796140656942494018", "name": "Wink", "tags": "mallow, wink, winking, ;), ;], ;D, 😉, 😜, 😘, :wink, winking, pose", "type": 1, "format_type": 3, "description": "Mallow raises her sunglasses and winks", "asset": "", "pack_id": "796138864937746317", "sort_value": 100}, {"id": "796140687640496565", "name": "Typing", "tags": "mallow, typing, type, :type, :typing, texting, text, 📱", "type": 1, "format_type": 3, "description": "Mallow typing on a phone", "asset": "", "pack_id": "796138864937746317", "sort_value": 100}, {"id": "796140711719820833", "name": "Idea", "tags": "mallow, lightbulb, idea, i got an idea, hmm, i got it, light bulb, eureka, 💡, :lightbulb, :idea", "type": 1, "format_type": 3, "description": "Mallow raises her finger with an idea", "asset": "", "pack_id": "796138864937746317", "sort_value": 100}], "cover_sticker_id": "796140731257499135", "banner_asset_id": "796139192810279397"}
    """#

    @Test("A pack keeps its stickers in the order Discord sent them")
    func pack() throws {
        let pack = try #require(
            try JSONDecoder().decode(StickerPackDTO.self, from: Data(mallow.utf8)).domain
        )
        #expect(pack.id == "796138864937746317")
        #expect(pack.name == "Mallow The Rascal")
        #expect(pack.coverStickerID == 796_140_731_257_499_135)
        #expect(pack.stickers.map(\.name) == ["Happy", "Sad", "Wink", "Typing", "Idea"])
        #expect(pack.stickers.allSatisfy { $0.format == .lottie })
    }
}
