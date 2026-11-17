import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Which tabs the full profile's content column offers.
///
/// **Two of the three are unconditional and one is not**, and the difference is
/// what a tab's absence would mean: everybody has an answer to "what are they
/// doing" and "what do we share", often "nothing", while a board is a thing
/// somebody made and a tab for one they never made promises a surface that does
/// not exist. The decision is invisible in a rendered view, so it is tested here
/// rather than by opening a profile and counting.
@Suite("Profile tabs")
@MainActor
struct ProfileTabTests {

    private func profile(
        activity: Activity? = nil,
        mutualServers: [MutualServer] = [],
        mutualFriends: [MutualFriend] = []
    ) -> ProfilePresentation {
        ProfilePresentation(
            userID: UserID(rawValue: 1),
            displayName: "Blåhaj",
            handle: "blahaj",
            monogram: "B",
            status: .online,
            activities: activity.map { [$0] } ?? [],
            isBot: false,
            badges: [],
            roles: [],
            accountCreated: .now,
            isSelf: false,
            connections: [],
            premiumTier: .none,
            mutualServers: mutualServers,
            mutualFriends: mutualFriends,
            isProfilePrivate: false,
            note: "",
            isLoading: false
        )
    }

    private var board: BoardPresentation {
        BoardPresentation(
            tiles: [BoardTile(id: "w", title: "Favourite Game", content: .grid([]))],
            isLoadingGames: false
        )
    }

    private var recent: ProfileActivityPresentation {
        ProfileActivityPresentation(recent: [
            RecentActivity(
                id: "1",
                authorID: UserID(rawValue: 1),
                subject: .game(name: "The Sims 4", applicationID: nil)
            ),
        ])
    }

    @Test("An account with everything gets all three")
    func everything() {
        let tabs = ProfileTab.available(
            profile: profile(
                activity: Activity(kind: .playing, name: "Xcode"),
                mutualServers: [
                    MutualServer(id: GuildID(rawValue: 1), name: "Lumen Club", monogram: "L"),
                ]
            ),
            board: board,
            activity: recent
        )
        #expect(tabs == [.board, .activity, .mutuals])
    }

    /// Your own profile has nothing "in common" with you: no Mutuals tab.
    @Test("Your own profile draws no Mutuals tab")
    func ownProfile() {
        var own = profile()
        own.isSelf = true
        let tabs = ProfileTab.available(profile: own, board: nil, activity: recent)
        #expect(!tabs.contains(.mutuals))
        #expect(tabs.contains(.activity))
    }

    /// **An empty board is not a Board tab.** The presentation exists — the
    /// widgets route answered — and it answered with nothing on it.
    @Test("An empty board draws no Board tab")
    func emptyBoard() {
        let tabs = ProfileTab.available(
            profile: profile(activity: Activity(kind: .playing, name: "Xcode")),
            board: BoardPresentation(tiles: [], isLoadingGames: false),
            activity: ProfileActivityPresentation()
        )
        #expect(tabs == [.activity, .mutuals])
    }

    /// A board that never arrived is the same answer as an empty one: the
    /// difference between "no widgets" and "the route has not answered yet" is
    /// not something a picker can express.
    @Test("No board at all draws no Board tab")
    func noBoard() {
        let tabs = ProfileTab.available(profile: profile(), board: nil, activity: recent)
        #expect(tabs == [.activity, .mutuals])
    }

    /// **The blank case, and the whole of what changed.** An account with no
    /// board, nothing to say about what they are doing and no server in common
    /// still offers both tabs; each answers with one honest line. Hiding them
    /// made the picker a different shape for every person.
    @Test("An account with nothing shared still offers Activity and Mutuals")
    func nothing() {
        let tabs = ProfileTab.available(
            profile: profile(),
            board: nil,
            activity: ProfileActivityPresentation()
        )
        #expect(tabs == [.activity, .mutuals])
    }

    /// The picker is drawn from two segments up, so it is always drawn — which
    /// is the point. A one-segment picker is a label that looks pressable, and
    /// there is no longer any profile that produces one.
    @Test("There is never fewer than one choice to make")
    func alwaysAPicker() {
        let tabs = ProfileTab.available(
            profile: profile(),
            board: nil,
            activity: ProfileActivityPresentation()
        )
        #expect(tabs.count >= 2)
    }

    // MARK: An app's

    @Test("An app's tabs are Discord's: its servers in common, counted, and Data Access")
    func application() {
        var app = profile()
        app.isBot = true
        let tabs = ProfileTab.available(profile: app, board: board, activity: recent)
        #expect(tabs == [.mutuals, .dataAccess])
        #expect(ProfileTab.mutuals.title(for: app) == "No Mutual Servers")
        #expect(ProfileTab.dataAccess.title(for: app) == "Data Access")
        app.isLoading = true
        #expect(ProfileTab.mutuals.title(for: app) == "Mutual Servers")
        // A person's tab keeps its own word.
        #expect(ProfileTab.mutuals.title(for: profile()) == "Mutuals")
    }

    @Test("Discord's own authorize link for the app stays in the app; any other address leaves it")
    func customInstallAddress() throws {
        let id = ApplicationID(rawValue: 42)
        let discord = try #require(URL(string: "https://discord.com/oauth2/authorize?client_id=42&scope=bot"))
        let other = try #require(URL(string: "https://discord.com/oauth2/authorize?client_id=7&scope=bot"))
        let site = try #require(URL(string: "https://helper.test/invite"))
        #expect(AppModel.isDiscordAuthorize(discord, for: id))
        #expect(!AppModel.isDiscordAuthorize(other, for: id))
        #expect(!AppModel.isDiscordAuthorize(site, for: id))
    }
}
