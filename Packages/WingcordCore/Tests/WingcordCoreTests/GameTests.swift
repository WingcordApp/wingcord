import Foundation
import Testing
@testable import WingcordCore

/// The game profile's derivations.
///
/// Every expectation here is measured off one of the three captured game pages
/// — The Sims 4, Beat Saber and Arknights: Endfield — and they were chosen
/// because they disagree: one has a rank and two do not, one has a Discord
/// server and one does not, one has three review rows and one has one.
@Suite("Games")
struct GameTests {

    private let sims = ApplicationID(rawValue: 359_509_007_423_242_240)

    private func website(_ url: String, _ category: GameLinkCategory) -> GameWebsite {
        GameWebsite(url: URL(string: url)!, category: category)
    }

    // MARK: The community invite

    @Test("The community card is gated on a Discord website and nothing else")
    func communityGate() {
        let withServer = Game(
            id: sims, name: "The Sims 4",
            websites: [website("https://discord.com/invite/thesims", .discord)]
        )
        let withoutServer = Game(
            id: sims, name: "Beat Saber",
            websites: [website("https://beatsaber.com/", .official)]
        )
        #expect(withServer.communityInviteCode == "thesims")
        #expect(withoutServer.communityInviteCode == nil)
    }

    @Test("An invite code survives both spellings and a proof query")
    func inviteCodeForms() {
        #expect(website("https://discord.gg/AKEndfield", .discord).inviteCode == "AKEndfield")
        #expect(website("https://discord.com/invite/thesims", .discord).inviteCode == "thesims")
        #expect(
            website("https://discord.com/invite/wutheringwaves?proof=e8eb", .discord)
                .inviteCode == "wutheringwaves"
        )
    }

    @Test("Only a Discord link yields a code")
    func nonDiscordLinkHasNoCode() {
        #expect(website("https://twitch.tv/thesims", .twitch).inviteCode == nil)
    }

    // MARK: The links row

    @Test("The links row carries the socials and drops the stores and wikis")
    func socialLinks() {
        // The Sims 4's own set, verbatim.
        let game = Game(
            id: sims, name: "The Sims 4",
            websites: [
                website("https://www.twitch.tv/directory/game/x", .twitch),
                website("https://discord.com/invite/thesims", .discord),
                website("https://store.steampowered.com/app/1222670", .steam),
                website("https://www.youtube.com/user/TheSims", .youtube),
                website("https://en.wikipedia.org/wiki/The_Sims_4", .wikipedia),
                website("https://www.ea.com/games/the-sims", .official),
                website("https://store.epicgames.com/p/the-sims-4", .epicGames),
                website("https://twitter.com/TheSims", .twitter),
                website("https://www.reddit.com/r/Sims4", .reddit),
                website("https://www.facebook.com/TheSims", .facebook),
                website("http://sims.wikia.com/wiki/The_Sims_4", .wikia),
                website("https://www.instagram.com/thesims", .instagram),
            ]
        )
        // Discord's row (its `pF`, read 2026-11-18): its order, not the
        // response's, with Fandom in it and the stores and Wikipedia out.
        #expect(game.socialLinks.map(\.category) == [
            .official, .facebook, .twitter, .instagram, .youtube, .reddit, .twitch, .wikia,
        ])
    }

    @Test("The phone stores close the row: one each, on the store's own host or built from its id")
    func socialLinksPhoneStores() {
        let game = Game(
            id: sims, name: "Phone game",
            websites: [
                website("https://example.com/not-the-app-store", .iphone),
                website("https://itch.io/game", .itch),
                website("https://apps.apple.com/app/id123", .ipad),
                website("https://www.roblox.com/games/1", .roblox),
            ],
            thirdPartySkus: [GameSKU(distributor: "google_play", id: "com.example.game")]
        )
        let row = game.socialLinks
        #expect(row.map(\.category) == [.roblox, .itch, .iphone, .android])
        // An iPhone link off Apple's host is no store page; the iPad one is.
        #expect(row[2].url.absoluteString == "https://apps.apple.com/app/id123")
        #expect(row[3].url.absoluteString == "https://play.google.com/store/apps/details?id=com.example.game")
    }

    @Test("Every kind Discord's row shows is in it")
    func socialLinkKinds() {
        for category in [
            GameLinkCategory.official, .facebook, .twitter, .instagram, .youtube, .bluesky,
            .reddit, .twitch, .roblox, .itch, .wikia, .iphone, .ipad, .android,
        ] {
            #expect(category.isSocialLink)
        }
        for category in [GameLinkCategory.steam, .epicGames, .gog, .discord, .wikipedia, .battleNet, .riot, .minecraft] {
            #expect(!category.isSocialLink)
        }
    }

    // MARK: Companies

    @Test("A company can publish and develop, and both rows are drawn")
    func dualRoleCompany() {
        // Beat Saber's own credits.
        let game = Game(
            id: sims, name: "Beat Saber",
            companies: [
                GameCompany(name: "Beat Games", roles: [.publisher, .developer]),
                GameCompany(name: "Hyperbolic Magnetism", roles: [.publisher, .developer]),
            ]
        )
        #expect(game.publishers == ["Beat Games", "Hyperbolic Magnetism"])
        #expect(game.developers == ["Beat Games", "Hyperbolic Magnetism"])
    }

    @Test("The Sims' roles split")
    func splitRoles() {
        let game = Game(
            id: sims, name: "The Sims 4",
            companies: [
                GameCompany(name: "Electronic Arts", roles: [.publisher]),
                GameCompany(name: "The Sims Studio", roles: [.developer]),
                GameCompany(name: "Maxis", roles: [.developer]),
            ]
        )
        #expect(game.publishers == ["Electronic Arts"])
        #expect(game.developers == ["The Sims Studio", "Maxis"])
    }

    @Test("A role outside the documented pair is credited nowhere")
    func unknownRole() {
        let company = GameCompany(name: "Somebody", roles: [GameCompanyRole(rawValue: 9)])
        let game = Game(id: sims, name: "x", companies: [company])
        #expect(game.publishers.isEmpty)
        #expect(game.developers.isEmpty)
    }

    // MARK: Platforms

    @Test("Desktop, Linux and macOS are one mark")
    func platformsCollapse() {
        // The Sims 4 carries [0, 1, 2, 7] and Discord draws three marks.
        let groups = GamePlatform.displayGroups(of: [.desktop, .xbox, .playStation, .macOS])
        #expect(groups == [.desktop, .xbox, .playStation])
    }

    @Test("Mobile platforms draw nothing")
    func mobileDrawsNothing() {
        // Arknights carries [0, 2, 3, 4] and Discord draws two marks.
        let groups = GamePlatform.displayGroups(of: [.desktop, .playStation, .iOS, .android])
        #expect(groups == [.desktop, .playStation])
    }

    @Test("One platform stays one")
    func singlePlatform() {
        #expect(GamePlatform.displayGroups(of: [.playStation]) == [.playStation])
    }

    // MARK: Reviews

    @Test("Steam lines are Discord's: Recent, then English or All, and no Overall")
    func steamRows() {
        // The Sims sends all three aggregates, and Discord draws two lines: a
        // Recent with a real verdict, and English because 106,026 English
        // reviews out of 199,981 clear its 200-of-2,000 bar.
        let sims = GameReviews(steam: GameReviews.SteamReviews(
            rating: 86, ratingCount: 199_981,
            recentRating: 80, recentRatingCount: 1_717,
            localizedRating: 86, localizedRatingCount: 106_026
        ))
        #expect(sims.steamRows(hasStorePage: true).map(\.title) == ["Recent", "English"])

        // Beat Saber sends only the all-time pair: no Recent, and All.
        let beatSaber = GameReviews(steam: GameReviews.SteamReviews(rating: 96, ratingCount: 69_711))
        #expect(beatSaber.steamRows(hasStorePage: true).map(\.title) == ["All"])

        // Too few English reviews to stand for the whole: All instead.
        let small = GameReviews(steam: GameReviews.SteamReviews(
            rating: 90, ratingCount: 1_500, localizedRating: 91, localizedRatingCount: 300
        ))
        #expect(small.steamRows(hasStorePage: true).map(\.title) == ["All"])

        // The lines open the store page, so without one there are none — and
        // with one and nothing to say, All says "No User Reviews".
        #expect(sims.steamRows(hasStorePage: false).isEmpty)
        let silent = GameReviews().steamRows(hasStorePage: true)
        #expect(silent.map(\.title) == ["All"])
        #expect(silent.first?.verdict == .noUserReviews)
        #expect(silent.first?.sentence == "No User Reviews")
    }

    @Test("Verdicts follow Discord's derivation, including the recent window's floors")
    func steamVerdicts() {
        #expect(SteamVerdict(rating: 96, count: 69_711, isRecent: false) == .overwhelminglyPositive)
        #expect(SteamVerdict(rating: 86, count: 106_026, isRecent: false) == .veryPositive)
        #expect(SteamVerdict(rating: 80, count: 1_717, isRecent: true) == .veryPositive)
        // Under fifty reviews is plain Positive outside the recent window…
        #expect(SteamVerdict(rating: 96, count: 40, isRecent: false) == .positive)
        // …and the recent window never says it.
        #expect(SteamVerdict(rating: 96, count: 40, isRecent: true) == .veryPositive)
        // Overwhelmingly at a hundred recent reviews, at five hundred otherwise.
        #expect(SteamVerdict(rating: 96, count: 150, isRecent: true) == .overwhelminglyPositive)
        #expect(SteamVerdict(rating: 96, count: 150, isRecent: false) == .veryPositive)
        #expect(SteamVerdict(rating: 55, count: 900, isRecent: false) == .mixed)
        #expect(SteamVerdict(rating: 10, count: 900, isRecent: false) == .overwhelminglyNegative)
        #expect(SteamVerdict(rating: 10, count: 30, isRecent: false) == .negative)
        #expect(SteamVerdict(rating: 10, count: 30, isRecent: true) == .veryNegative)
        // Under ten there is nothing to say.
        #expect(SteamVerdict(rating: 96, count: 9, isRecent: false) == .noUserReviews)
        #expect(SteamVerdict(rating: nil, count: nil, isRecent: false) == .noUserReviews)
    }

    @Test("A Steam line's tooltip is Discord's sentence for its window")
    func steamSentences() {
        let row = GameReviews.SteamRow(window: .recent, rating: 80, count: 1_717)
        #expect(row.sentence.hasPrefix("80% of "))
        #expect(row.sentence.hasSuffix(" user reviews in the last 30 days are positive"))
    }

    @Test("OpenCritic draws a ring only for a tiered average with critics behind it")
    func openCriticStates() {
        let full = GameReviews.OpenCriticReviews(topCriticRating: 89.4, topCriticRatingCount: 120, tier: .mighty)
        #expect(full.showsRing)
        #expect(!full.lacksCritics)
        let tierOnly = GameReviews.OpenCriticReviews(tier: .strong)
        #expect(!tierOnly.showsRing)
        #expect(!tierOnly.lacksCritics)
        let nothing = GameReviews.OpenCriticReviews(topCriticRating: 0, topCriticRatingCount: 0)
        #expect(!nothing.showsRing)
        #expect(nothing.lacksCritics)
        #expect(OpenCriticTier.mighty.badgeURL?.host == "cdn.discordapp.com")
    }

    @Test("An OpenCritic score is truncated, never rounded")
    func openCriticTruncates() {
        // Discord shows 69 for The Sims' 69.969 and 85 for Beat Saber's 85.926.
        #expect(GameReviews.OpenCriticReviews(topCriticRating: 69.969).score == 69)
        #expect(GameReviews.OpenCriticReviews(topCriticRating: 85.926).score == 85)
        #expect(GameReviews.OpenCriticReviews(topCriticRating: 79.286).score == 79)
    }

    @Test("Reviews with neither service are absent rather than empty")
    func emptyReviews() {
        #expect(GameReviews().isEmpty)
        #expect(!GameReviews(openCritic: GameReviews.OpenCriticReviews(tier: .strong)).isEmpty)
    }

    // MARK: Genres

    @Test("Genres print as their names, in the order they arrived")
    func genreLine() {
        // The Sims 4's [20, 28] and Beat Saber's [33, 67, 68, 62].
        let sims = Game(id: sims, name: "x", genres: [GameGenre(rawValue: 20), GameGenre(rawValue: 28)])
        #expect(sims.genreLine == "Role-Playing, Simulation")

        let beatSaber = Game(
            id: self.sims, name: "y",
            genres: [33, 67, 68, 62].map(GameGenre.init(rawValue:))
        )
        #expect(beatSaber.genreLine == "Sports, Indie, Arcade, Music / Rhythm")
    }

    @Test("A genre added after this was written keeps its number")
    func unknownGenre() {
        #expect(GameGenre(rawValue: 999).title == "Genre 999")
    }

    // MARK: Where the game is sold
    //
    // Every SKU list below is a real one, lifted whole out of a capture. The
    // rule it exercises is Discord's `useSteamStoreURL`, which its own store
    // button does not call — see `Game.storeOffers` for why this client sides
    // with the hook rather than with the button.

    private func sku(_ distributor: String, _ id: String) -> GameSKU {
        GameSKU(distributor: distributor, id: id)
    }

    @Test("One Steam SKU is the address, slug and all ignored")
    func singleSteamSKU() {
        // The Sims 4. The website names the same app with a title slug on the
        // end; the SKU is the shorter, equivalent address and it is what
        // Discord builds.
        let game = Game(
            id: sims, name: "The Sims 4",
            websites: [website("https://store.steampowered.com/app/1222670/The_Sims_4", .steam)],
            thirdPartySkus: [
                sku("igdb", "3212"), sku("opencritic", "572"),
                sku("epic", "2A14CF8A83B149919A2399504E5686A6"),
                sku("steam", "1222670"), sku("gop", "21009"),
            ],
            steamReleaseStatus: .postRelease
        )
        #expect(game.storeOffers.map(\.store) == [.steam])
        #expect(
            game.storeOffers.first?.url.absoluteString
                == "https://store.steampowered.com/app/1222670"
        )
    }

    @Test("Several Steam SKUs are ambiguous, so the website breaks the tie")
    func severalSteamSKUs() {
        // Beat Saber, verbatim. Its first Steam SKU is 38598 and the game is
        // 620980 — taking the first, which is what Discord's own button does,
        // opens something else entirely. Twenty games in the captures on disk
        // carry more than one Steam SKU, all twenty carry the website that
        // settles it, and nine of them need it.
        let game = Game(
            id: sims, name: "Beat Saber",
            websites: [website("https://store.steampowered.com/app/620980", .steam)],
            thirdPartySkus: [
                sku("playstation", "PPSA15035_00"), sku("playstation", "CUSA14143_00"),
                sku("steam", "38598"), sku("gop", "60240"), sku("opencritic", "6151"),
                sku("igdb", "83731"), sku("steam", "37124"),
                sku("gdco", "8380"), sku("steam", "620980"),
            ],
            steamReleaseStatus: .postRelease
        )
        #expect(
            game.storeOffers.first?.url.absoluteString
                == "https://store.steampowered.com/app/620980"
        )
    }

    @Test("Several SKUs and no website leaves the first, which is all there is")
    func severalSteamSKUsWithNoWebsite() {
        let game = Game(
            id: sims, name: "x",
            thirdPartySkus: [sku("steam", "38598"), sku("steam", "620980")]
        )
        #expect(
            game.storeOffers.first?.url.absoluteString
                == "https://store.steampowered.com/app/38598"
        )
    }

    @Test("A Steam SKU with no website is a button this page never used to draw")
    func skuWithoutWebsite() {
        // Battlefield 6 and Stardew Valley are both this shape: a Steam SKU and
        // no STEAM website at all. Read from `websites` alone — which is what
        // the game profile did — neither had a store button.
        let game = Game(
            id: sims, name: "Battlefield 6",
            thirdPartySkus: [
                sku("epic", "A14A02AA3C8143729605EAF7C93D7501"),
                sku("xbox", "9P4BB02MWDZK"), sku("steam", "2807960"),
                sku("playstation", "PPSA19534_00"), sku("igdb", "317407"),
            ]
        )
        #expect(
            game.storeOffers.map(\.url.absoluteString)
                == ["https://store.steampowered.com/app/2807960"]
        )
    }

    @Test("A website with no SKU is still an address")
    func websiteWithoutSKU() {
        let game = Game(
            id: sims, name: "x",
            websites: [website("https://store.steampowered.com/app/620980", .steam)]
        )
        #expect(
            game.storeOffers.first?.url.absoluteString
                == "https://store.steampowered.com/app/620980"
        )
    }

    @Test("A retired game is offered no Steam page, whatever else it carries")
    func retiredGame() {
        let game = Game(
            id: sims, name: "x",
            websites: [website("https://store.steampowered.com/app/620980", .steam)],
            thirdPartySkus: [sku("steam", "620980")],
            steamReleaseStatus: .retiredAbandoned
        )
        #expect(game.storeOffers.isEmpty)
    }

    @Test("A status nobody has seen does not take the link away")
    func unknownReleaseStatus() {
        // Erring toward showing: only `retiredAbandoned` says a page has gone,
        // and a number outside the enum says nothing at all.
        #expect(SteamReleaseStatus(rawValue: 99) == nil)
        let game = Game(
            id: sims, name: "x",
            thirdPartySkus: [sku("steam", "620980")],
            steamReleaseStatus: nil
        )
        #expect(game.storeOffers.count == 1)
    }

    @Test("Game Pass comes first, and only these two are stores at all")
    func storeOrderAndMembership() {
        // Stardew Valley's own list: two Game Pass SKUs, one Steam, and six
        // other distributors that are catalogues or storefronts Discord does
        // not link. PlayStation is the commonest value in every capture and has
        // no button anywhere.
        let game = Game(
            id: sims, name: "Stardew Valley",
            thirdPartySkus: [
                sku("playstation", "CUSA26625_00"), sku("xbox_title", "2080211397"),
                sku("xbox_game_pass", "9MWR1NC6VQ6L"), sku("gop", "21095"),
                sku("xbox_game_pass", "C3D891Z6TNQM"), sku("opencritic", "2242"),
                sku("xbox", "9MWR1NC6VQ6L"), sku("igdb", "17000"),
                sku("steam", "413150"), sku("gdco", "84015"),
            ],
            steamReleaseStatus: .postRelease
        )
        #expect(game.storeOffers.map(\.store) == [.xboxGamePass, .steam])
        #expect(
            game.storeOffers.map(\.url.absoluteString) == [
                "https://www.xbox.com/games/store/title/9MWR1NC6VQ6L",
                "https://store.steampowered.com/app/413150",
            ]
        )
    }

    @Test("An empty SKU id is never turned into an address")
    func emptySKUID() {
        // Minecraft ships `{"distributor": "microsoft", "id": ""}`, and origin
        // and battlenet do the same elsewhere. An empty id pasted onto a store
        // path is a 404 rather than a page.
        let game = Game(
            id: sims, name: "x",
            thirdPartySkus: [sku("xbox_game_pass", ""), sku("steam", "")]
        )
        #expect(game.storeOffers.isEmpty)
    }

    @Test("A game with no store at all offers nothing")
    func noStore() {
        // Arknights: Endfield. Epic, Google Play and the App Store are real
        // places to get it and none of them is a button in Discord either.
        let game = Game(
            id: sims, name: "ARKNIGHTS: ENDFIELD",
            thirdPartySkus: [
                sku("igdb", "194558"), sku("opencritic", "19963"),
                sku("epic", "14D53B5D3FCB4526A69D59F35C9DD28F"),
                sku("google_play", "com.gryphline.endfield.gp"),
                sku("apple_app_store", "6752642477"),
            ]
        )
        #expect(game.storeOffers.isEmpty)
    }

    @Test("A SKU with characters a path cannot hold is encoded")
    func skuEncoding() {
        #expect(
            GameStore.xboxGamePass.url(sku: "a b")?.absoluteString
                == "https://www.xbox.com/games/store/title/a%20b"
        )
    }

    @Test("Both buttons say what they do, and neither promises to play anything")
    func callsToAction() {
        // Discord's Steam string, measured; its Game Pass string is "Play with
        // Xbox Game Pass" and this client will not say it — nothing here plays
        // a game, it opens a store page in a browser.
        #expect(GameStore.steam.callToAction == "Get on Steam")
        #expect(GameStore.xboxGamePass.callToAction == "Get on Xbox Game Pass")
    }
}
