import Foundation
import Testing
import WingcordCore

/// The game profile's buttons — Discord's `lU`, which draws every store it
/// knows rather than the activity card's two.
///
/// **The report**: Roblox's page had no Roblox button and Valorant's no Riot
/// Play, only ever Steam and Xbox. Both stores come from `websites` rows, and
/// the SKUs never name either.
@Suite("Game launch offers")
struct GameLaunchOfferTests {

    private func website(_ url: String, _ category: GameLinkCategory) -> GameWebsite {
        GameWebsite(url: URL(string: url)!, category: category)
    }

    /// Roblox's own record, `games and non games.har`: its official site sits
    /// under category 22, and no SKU is a store with a button.
    @Test("Roblox is offered from its ROBLOX website")
    func roblox() {
        let game = Game(
            id: ApplicationID(rawValue: 363_445_589_251_008_817), name: "ROBLOX",
            websites: [
                website("https://www.roblox.com", .roblox),
                website("https://en.wikipedia.org/wiki/Roblox", .wikipedia),
                website("https://www.roblox.com/", .official),
            ],
            thirdPartySkus: [
                GameSKU(distributor: "google_play", id: "com.roblox.client"),
                GameSKU(distributor: "playstation", id: "PPSA10990_00"),
                GameSKU(distributor: "xbox", id: "9PMF91N3LZ3M"),
            ]
        )
        #expect(game.launchOffers.map(\.store) == [.roblox])
        #expect(game.launchOffers.first?.store.profileLabel == "Roblox")
    }

    @Test("Riot's website is its Play button")
    func riot() {
        let game = Game(
            id: ApplicationID(rawValue: 700_136_079_565_753_140), name: "VALORANT",
            websites: [website("https://playvalorant.com/", .riot)]
        )
        #expect(game.launchOffers.map(\.store) == [.riot])
        #expect(game.launchOffers.first?.store.profileLabel == "Play")
        #expect(game.launchOffers.first?.store.profileAccessibilityLabel == "Play on Riot")
    }

    @Test("Game Pass leads, Steam comes next, the rest keep their order; Epic only where Discord allows it")
    func order() {
        let game = Game(
            id: ApplicationID(rawValue: 1), name: "Something",
            websites: [
                website("https://example.test/battle", .battleNet),
                website("https://store.epicgames.com/x", .epicGames),
                website("https://store.steampowered.com/app/10", .steam),
                website("https://minecraft.net", .minecraft),
            ],
            thirdPartySkus: [GameSKU(distributor: "xbox_game_pass", id: "9N8KMNW6942X")]
        )
        #expect(game.launchOffers.map(\.store) == [.xboxGamePass, .steam, .battleNet, .minecraft])
    }

    @Test("A Steam SKU with no website still gets its button, and a retired game gets none")
    func steam() {
        let fromSKU = Game(
            id: ApplicationID(rawValue: 2), name: "Stardew Valley",
            thirdPartySkus: [GameSKU(distributor: "steam", id: "413150")]
        )
        #expect(fromSKU.launchOffers.map(\.url.absoluteString) == ["https://store.steampowered.com/app/413150"])

        let retired = Game(
            id: ApplicationID(rawValue: 3), name: "Gone",
            websites: [website("https://store.steampowered.com/app/9", .steam)],
            thirdPartySkus: [GameSKU(distributor: "steam", id: "9")],
            steamReleaseStatus: .retiredAbandoned
        )
        #expect(retired.launchOffers.isEmpty)
    }
}
