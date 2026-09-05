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
        // Seven marks, which is what Discord's own page draws for this game.
        #expect(game.socialLinks.count == 7)
        #expect(!game.socialLinks.contains { $0.category == .steam })
        #expect(!game.socialLinks.contains { $0.category == .discord })
        #expect(!game.socialLinks.contains { $0.category == .wikipedia })
    }

    @Test("Every link in the row has a brand to draw")
    func socialLinksAllHaveMarks() {
        for category in [
            GameLinkCategory.official, .facebook, .twitter, .twitch, .instagram,
            .youtube, .reddit, .bluesky,
        ] {
            #expect(category.isSocialLink)
            #expect(category.brandService != nil)
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

    @Test("Steam rows exist exactly where their counts arrived")
    func steamRows() {
        // The Sims sends all three aggregates.
        let sims = GameReviews.SteamReviews(
            rating: 86, ratingCount: 199_981,
            recentRating: 80, recentRatingCount: 1_717,
            localizedRating: 86, localizedRatingCount: 106_026
        )
        #expect(sims.rows.map(\.title) == ["Recent Reviews", "English Reviews", "Overall"])

        // Beat Saber sends only the all-time pair, and its one row is named for
        // being the only one.
        let beatSaber = GameReviews.SteamReviews(rating: 96, ratingCount: 69_711)
        #expect(beatSaber.rows.map(\.title) == ["All Reviews"])
    }

    @Test("Steam's wording matches its own thresholds")
    func steamVerdicts() {
        #expect(SteamVerdict(rating: 96, count: 69_711) == .overwhelminglyPositive)
        #expect(SteamVerdict(rating: 86, count: 106_026) == .veryPositive)
        #expect(SteamVerdict(rating: 80, count: 1_717) == .veryPositive)
        // The same share with too few reviews is a weaker claim.
        #expect(SteamVerdict(rating: 96, count: 40) == .veryPositive)
        #expect(SteamVerdict(rating: 82, count: 12) == .positive)
        #expect(SteamVerdict(rating: 55, count: 900) == .mixed)
        #expect(SteamVerdict(rating: 10, count: 900) == .overwhelminglyNegative)
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
}
