import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A game profile's media, opened in the viewer (Alex, 2026-11-18), and
/// Discord's marks it and the store buttons draw.
@MainActor
@Suite("Game profile media and marks")
struct GameProfileMediaTests {

    @Test("Clicking a game's still opens the viewer on it, with the rest as its gallery")
    func opensAsGallery() throws {
        let model = AppModel()
        let trailer = try #require(URL(string: "https://cdn.discordapp.com/app-assets/1/store/2.mp4"))
        let poster = try #require(URL(string: "https://cdn.discordapp.com/app-assets/1/store/2.webp"))
        let first = try #require(URL(string: "https://images.igdb.com/igdb/image/upload/t_1080p/a.jpg"))
        let second = try #require(URL(string: "https://images.igdb.com/igdb/image/upload/t_1080p/b.jpg"))
        model.openGameMedia(
            [.trailer(video: trailer, poster: poster), .still(first), .still(second)],
            index: 2,
            gameName: "A Game"
        )
        let request = try #require(model.mediaViewer)
        #expect(request.items.count == 3)
        #expect(request.index == 2)
        #expect(request.items[0].isVideo)
        #expect(request.items[0].posterURL == poster)
        #expect(request.items[2].kind == .image)
        // Not Discord's proxy's: shown as served, never re-asked at a width.
        #expect(request.items[2].renditionURL(forPixelWidth: 640) == second)
        #expect(request.hasSiblings)
        // Drawn above the game profile that raised it, not under the sheets.
        #expect(request.isAboveSheets)
    }

    @Test("Every one of Discord's marks parses, and every store and link has one")
    func marksParse() {
        for icon in DiscordBrandIcon.allCases {
            #expect(!icon.parts.isEmpty, "\(icon) drew nothing")
            for part in icon.parts {
                let box = part.path.boundingBoxOfPath
                #expect(box.minX >= -0.5 && box.maxX <= 24.5 && box.minY >= -0.5 && box.maxY <= 24.5)
            }
        }
        #expect(GameStore.steam.discordIcon == .steam)
        #expect(GameLinkCategory.wikia.discordIcon == .fandom)
        #expect(GameLinkCategory.itch.discordIcon == .itch)
        #expect(GameLinkCategory.android.discordIcon == .googlePlay)
    }
}
