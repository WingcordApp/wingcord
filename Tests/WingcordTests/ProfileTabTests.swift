import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Which tabs the full profile's content column offers.
///
/// **The gating is the whole of the blank case.** A tab with nothing behind it
/// is an empty state — a client apologising for somebody's own choices — and the
/// picker exists only where there is a choice to make. Neither decision is
/// visible in a rendered view, so both are tested here rather than by opening a
/// profile and counting.
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
            activity: activity,
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
                    MutualServer(id: GuildID(rawValue: 1), name: "Lumen Club", monogram: "S"),
                ]
            ),
            board: board,
            activity: recent
        )
        #expect(tabs == [.board, .activity, .mutuals])
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
        #expect(tabs == [.activity])
    }

    /// Recent activity alone earns the tab: somebody offline who played
    /// yesterday has something to show and no presence.
    @Test("Recent activity alone earns the Activity tab")
    func recentAlone() {
        let tabs = ProfileTab.available(profile: profile(), board: nil, activity: recent)
        #expect(tabs == [.activity])
    }

    /// Mutual friends with no mutual servers still earn the tab — the two are
    /// separate lists and either one is content.
    @Test("Mutual friends alone earn the Mutuals tab")
    func friendsAlone() {
        let tabs = ProfileTab.available(
            profile: profile(mutualFriends: [
                MutualFriend(
                    id: UserID(rawValue: 2), name: "alex", avatarHash: nil, monogram: "A"
                ),
            ]),
            board: nil,
            activity: ProfileActivityPresentation()
        )
        #expect(tabs == [.mutuals])
    }

    /// **The blank case, and it has to be a real answer rather than a crash or a
    /// default.** An account with no board, nothing to say about what they are
    /// doing and no server in common draws no picker at all and one honest line.
    @Test("An account with nothing shared gets no tabs")
    func nothing() {
        let tabs = ProfileTab.available(
            profile: profile(),
            board: nil,
            activity: ProfileActivityPresentation()
        )
        #expect(tabs.isEmpty)
    }

    /// One surviving tab draws no picker: a segmented control with a single
    /// segment is a label that looks pressable.
    @Test("One tab is not a picker")
    func onePicker() {
        let tabs = ProfileTab.available(
            profile: profile(activity: Activity(kind: .playing, name: "Xcode")),
            board: nil,
            activity: ProfileActivityPresentation()
        )
        #expect(tabs.count == 1)
    }
}
