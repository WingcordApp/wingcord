import Foundation
import WingcordCore

// MARK: - A rich presence and a recent-activity list, for `--demo`
//
// **Both are shapes out of a live capture**, not invented ones. The presence is
// Medal's — two custom buttons whose links come from a route of their own — and
// the inventory entries are `GET /content-inventory/users/{id}/outbox`'s own,
// with the traits it actually sends: a live session, a day streak, a marathon
// sitting, a first time, a trending game.
//
// A demo launch makes no requests, so the metadata route's answer is written
// straight into the slot it would have filled. Without it the buttons carry
// labels and no addresses, and a button with no address is not drawn — which is
// correct behaviour and would leave the demo unable to show a button at all.

extension DemoFixtures {

    // The ids below are `DemoBoard`'s own — the same games the board already
    // names — so a row's click opens a page the demo actually holds rather than
    // a spinner that never resolves.

    /// Everything the Activity tab and the card's activity block draw.
    ///
    /// - Parameter owner: the person the board already belongs to. The same
    ///   person carries the activity, so one profile shows every surface at
    ///   once rather than three fixtures showing one each.
    static func populatePresence(_ model: AppModel, owner: UserID, others: [UserID]) {
        let session = "demo-endfield-session"
        model.presences[owner] = Presence(
            userID: owner,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(
                    kind: .playing,
                    name: "Arknights: Endfield",
                    state: "Authority Level 60",
                    details: "Valley IV · Reclamation",
                    applicationID: Self.endfield,
                    // **Two different key FORMS on one activity, deliberately.**
                    // `Activity.assetURL` has one branch per prefix and a fixture
                    // that uses one leaves the others unexercised — so the large
                    // image is a proxied external asset (`mp:`) and the badge is
                    // a Spotify one. Both addresses below are public and were
                    // taken from live payloads; a real presence's small image is
                    // the publisher's mark rather than an album cover.
                    largeImageKey: "mp:external/5262anvBGiUJ9zGLGQwj1gTcwYxnZXbLFMvm_mfQGQg"
                        + "/https/web-static-pub.hg-cdn.com/biz_toolset/upload"
                        + "/260623/97w2QnvxOdfxwyc5.png",
                    smallImageKey: "spotify:ab67616d0000b273ec01dac86206cd6b43ec5879",
                    largeText: "Arknights: Endfield",
                    smallText: "Gryphline",
                    startedAt: Date.now.addingTimeInterval(-4_326),
                    sessionID: session,
                    buttons: ["Follow on Medal", "Download Medal"]
                ),
            ])
        )
        // What `/users/{id}/sessions/{sid}/activities/{app}/metadata` answered,
        // verbatim.
        model.activityButtonURLs[session] = [
            URL(string: "https://medal.tv/u/Browhiskey?ref=discordrpc")!,
            URL(string: "https://medal.tv/?ref=discordrpc")!,
        ]

        // A second presence with the OTHER clock. An activity that knows when it
        // ends counts toward it and prints the pair — `2:14 / 4:03` — where one
        // that does not counts up. Two shapes, and only a listening session has
        // the first.
        if let listener = others.first(where: { $0 != owner }) {
            model.presences[listener] = Presence(
                userID: listener,
                status: .idle,
                activities: PresenceActivities(list: [
                    Activity(
                        kind: .listening,
                        name: "Spotify",
                        state: "Devon Hendryx",
                        details: "God & Earrings",
                        largeImageKey: "spotify:ab67616d0000b2737905832361a25be8d74a5c65",
                        largeText: "The Rockwood Escape Plan",
                        startedAt: Date.now.addingTimeInterval(-134),
                        endsAt: Date.now.addingTimeInterval(109)
                    ),
                ])
            )
        }

        model.recentActivity[owner] = recentActivity(of: owner)
        model.presenceRevision &+= 1
    }

    /// The outbox, as the capture's own entries.
    ///
    /// **Every game here is one the demo already holds**, so the rows draw real
    /// box art and a click opens a real page rather than a spinner that never
    /// resolves.
    private static func recentActivity(of owner: UserID) -> [RecentActivity] {
        let hour: TimeInterval = 3_600
        return [
            RecentActivity(
                id: "d-ra-1",
                authorID: owner,
                subject: .game(name: "Arknights: Endfield", applicationID: Self.endfield),
                traits: [.duration(4_326), .live, .streak(days: 8)],
                startedAt: Date.now.addingTimeInterval(-4_326)
            ),
            RecentActivity(
                id: "d-ra-2",
                authorID: owner,
                subject: .game(name: "The Sims 4", applicationID: Self.sims),
                traits: [.duration(18_405), .marathon, .streak(days: 2)],
                startedAt: Date.now.addingTimeInterval(-30 * hour),
                endedAt: Date.now.addingTimeInterval(-25 * hour)
            ),
            RecentActivity(
                id: "d-ra-3",
                authorID: owner,
                subject: .listening(
                    track: "God & Earrings",
                    artist: "Devon Hendryx",
                    artworkURL: URL(
                        string: "https://i.scdn.co/image"
                            + "/ab67616d0000b2737905832361a25be8d74a5c65"
                    )
                ),
                traits: [],
                startedAt: Date.now.addingTimeInterval(-52 * hour),
                endedAt: Date.now.addingTimeInterval(-52 * hour)
            ),
            RecentActivity(
                id: "d-ra-4",
                authorID: owner,
                subject: .game(name: "Beat Saber", applicationID: Self.beatSaber),
                traits: [.duration(1_988), .newPlayer, .trending],
                startedAt: Date.now.addingTimeInterval(-4 * 24 * hour),
                endedAt: Date.now.addingTimeInterval(-4 * 24 * hour + 1_988)
            ),
            RecentActivity(
                id: "d-ra-5",
                authorID: owner,
                subject: .activity(name: "Wordle", applicationID: nil),
                traits: [.duration(809), .streak(days: 44)],
                startedAt: Date.now.addingTimeInterval(-9 * 24 * hour),
                endedAt: Date.now.addingTimeInterval(-9 * 24 * hour + 809)
            ),
            RecentActivity(
                id: "d-ra-6",
                authorID: owner,
                subject: .game(name: "Battlefield 6", applicationID: Self.battlefield),
                traits: [.duration(3_626), .streak(days: 4)],
                startedAt: Date.now.addingTimeInterval(-16 * 24 * hour),
                endedAt: Date.now.addingTimeInterval(-16 * 24 * hour + 3_626)
            ),
        ]
    }
}
