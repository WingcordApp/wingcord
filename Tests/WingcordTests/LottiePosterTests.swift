import AppKit
import Foundation
import Lottie
import Testing
import WingcordCore
@testable import Wingcord

/// A Lottie sticker's still, which the CDN doesn't have (Alex, 2026-11-18:
/// Chaos Cat and Robo Nelly drew empty in the picker).
@MainActor
@Suite("Lottie posters")
struct LottiePosterTests {

    /// A red square, 320 points a side.
    private static let square = Data("""
    {"v":"5.6.2","fr":60,"ip":0,"op":60,"w":320,"h":320,"nm":"square","ddd":0,"assets":[],
     "layers":[{"ddd":0,"ind":1,"ty":1,"nm":"solid","sr":1,
      "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[160,160,0]},
            "a":{"a":0,"k":[160,160,0]},"s":{"a":0,"k":[100,100,100]}},
      "ao":0,"sw":320,"sh":320,"sc":"#ff0000","ip":0,"op":60,"st":0,"bm":0}]}
    """.utf8)

    /// The same square, there only in the loop's second half: frame 0 is empty.
    private static let latecomer = Data("""
    {"v":"5.6.2","fr":60,"ip":0,"op":60,"w":320,"h":320,"nm":"late","ddd":0,"assets":[],
     "layers":[{"ddd":0,"ind":1,"ty":1,"nm":"solid","sr":1,
      "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[160,160,0]},
            "a":{"a":0,"k":[160,160,0]},"s":{"a":0,"k":[100,100,100]}},
      "ao":0,"sw":320,"sh":320,"sc":"#ff0000","ip":24,"op":60,"st":0,"bm":0}]}
    """.utf8)

    /// Nothing drawn at any frame.
    private static let empty = Data("""
    {"v":"5.6.2","fr":60,"ip":0,"op":60,"w":320,"h":320,"nm":"empty","ddd":0,"assets":[],"layers":[]}
    """.utf8)

    @Test("A poster is one frame at the asked size, the sticker's own shape")
    func drawsAtSize() async throws {
        let animation = try LottieAnimation.from(data: Self.square)
        let poster = try #require(await LottiePosters.render(animation, pixels: 96))
        #expect(poster.width == 96)
        #expect(poster.height == 96)
    }

    @Test("A sticker that enters from nothing is drawn from the middle of its loop")
    func skipsAnEmptyFirstFrame() async throws {
        let animation = try LottieAnimation.from(data: Self.latecomer)
        #expect(await LottiePosters.render(animation, pixels: 64) != nil)
    }

    @Test("A document that draws nothing anywhere has no poster")
    func emptyHasNone() async throws {
        let animation = try LottieAnimation.from(data: Self.empty)
        #expect(await LottiePosters.render(animation, pixels: 64) == nil)
    }

    @Test("A poster's file name never carries the CDN path")
    func fileNameIsHashed() {
        let key = LottiePosters.Key(url: URL(string: "https://cdn.discordapp.com/stickers/823974203929526292.json")!, pixels: 192)
        #expect(key.fileName.hasSuffix("-192.png"))
        #expect(!key.fileName.contains("823974203929526292"))
    }
}

/// Discord's own sticker packs, kept on disk so the picker has them at once.
@Suite("Standard sticker pack cache")
struct StandardStickerPackCacheTests {

    @Test("What was written reads back, and a day later it is stale")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "wingcord-packs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cache = StandardStickerPackCache()
        cache.file = folder.appending(path: "sticker-packs.json")
        let pack = StickerPack(
            id: "847199849233514549",
            name: "Chaos Cat",
            coverStickerID: 823_974_203_929_526_292,
            stickers: [StickerRef(id: 823_974_203_929_526_292, name: "Chaos", format: .lottie)]
        )
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        cache.write([pack], now: written)
        let stored = try #require(cache.read())
        #expect(stored.packs == [pack])
        #expect(!cache.isStale(stored, now: written.addingTimeInterval(3_600)))
        #expect(cache.isStale(stored, now: written.addingTimeInterval(25 * 3_600)))
    }
}
