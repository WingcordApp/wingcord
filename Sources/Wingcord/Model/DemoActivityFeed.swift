import Foundation
import WingcordCore

/// The member list's Activity section in `--demo` (docs/ACTIVITY-CARDS.md):
/// one entry of every kind Discord draws, on people whose names wear
/// display-name styles, with the live ones backed by a presence (a party, a
/// voice room, a Spotify session) so every marker and popout part shows.
extension DemoFixtures {

    static func populateActivityFeed(_ model: AppModel, in guildID: GuildID) {
        guard let me = model.currentUserID else { return }
        // Discord offers the section below ten thousand members, or where the
        // members chose it: the demo server says so outright.
        model.guilds[guildID]?.features.insert("ACTIVITY_FEED_ENABLED_BY_USER")
        // People in the server, styled names first, the reader left out.
        let members = (model.members[guildID]?.keys.map { $0 } ?? [])
            .filter { $0 != me && model.users[$0]?.isBot != true }
            .sorted { lhs, rhs in
                let left = model.users[lhs]?.decoration?.displayNameStyle != nil
                let right = model.users[rhs]?.decoration?.displayNameStyle != nil
                return left != right ? left : lhs.rawValue < rhs.rawValue
            }
        // The live ones need their people online, doing it, and this runs last,
        // so it takes nobody another fixture already placed: the gamer is
        // somebody already sitting in a room the reader isn't in (the popout's
        // voice bar) and not playing anything, the listener somebody in no
        // room and doing nothing. Moving a person out of the reader's call cost
        // the call its fifth face and its stream (DemoFixtureTests).
        let readerRoom = model.voiceStates[me]?.channelID
        let isIdle = { (id: UserID) in model.presences[id]?.activities?.list.isEmpty ?? true }
        func company(_ id: UserID) -> Int {
            let room = model.voiceStates[id]?.channelID
            return model.voiceStates.values.filter { $0.channelID == room }.count
        }
        // The fullest such room, so the bar has faces in it.
        let seated = members.filter { id in
            guard let room = model.voiceStates[id]?.channelID else { return false }
            return room != readerRoom && isIdle(id)
        }
        guard let gamer = seated.max(by: { company($0) < company($1) }),
              let listener = members.first(where: { id in
            id != gamer && model.voiceStates[id] == nil && isIdle(id)
        }) else { return }
        let authors = members.filter { $0 != gamer && $0 != listener }
        guard authors.count >= 5 else { return }
        let now = Date.now
        func id(_ ago: TimeInterval) -> String {
            String((UInt64((now.timeIntervalSince1970 - ago) * 1000) - 1_420_070_400_000) << 22)
        }
        let musicArt = DemoGameArt.tile(symbol: "music.note", top: (0.95, 0.42, 0.62), bottom: (0.36, 0.20, 0.72), name: "demo-album")
        let sessionArt = DemoGameArt.tile(symbol: "waveform", top: (0.20, 0.72, 0.62), bottom: (0.10, 0.25, 0.45), name: "demo-single")

        model.presences[gamer] = Presence(
            userID: gamer,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(
                    kind: .playing, name: "Battlefield 6", state: "In a Match", details: "Conquest · Mirak Valley",
                    applicationID: battlefield, startedAt: now.addingTimeInterval(-1_520), partySize: [2, 4]
                ),
            ])
        )
        model.presences[listener] = Presence(
            userID: listener,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(
                    kind: .listening, name: "Spotify", state: "Night Swim", details: "Moonlight Drive",
                    largeText: "Tides", startedAt: now.addingTimeInterval(-74), endsAt: now.addingTimeInterval(141),
                    partyID: "spotify:demo-feed"
                ),
            ])
        )

        let entries: [(RecentActivity, [UserID])] = [
            (RecentActivity(
                id: id(3_600 * 20), authorID: authors[0],
                subject: .listening(track: "Moonlight Drive", artist: "Night Swim", artworkURL: musicArt),
                traits: [.week, .weeklyCount(14)],
                details: .init(album: "Tides", provider: 1)
            ), [authors[0]]),
            (RecentActivity(
                id: id(1_520), authorID: gamer,
                subject: .game(name: "Battlefield 6", applicationID: battlefield),
                traits: [.live, .newPlayer],
                startedAt: now.addingTimeInterval(-1_520), expiresAt: now.addingTimeInterval(3_600)
            ), [gamer] + authors.dropFirst(1).prefix(4)),
            (RecentActivity(
                id: id(3_600 * 30), authorID: authors[1],
                subject: .topGame(name: "The Sims 4", applicationID: sims),
                traits: [.week, .duration(12.4 * 3_600)]
            ), [authors[1]]),
            (RecentActivity(
                id: id(3_600 * 3), authorID: authors[2],
                subject: .game(name: "Wuthering Waves", applicationID: wuthering),
                traits: [.returning(lastPlayed: now.addingTimeInterval(-86_400 * 70)), .streak(days: 5), .marathon,
                         .duration(4.2 * 3_600)]
            ), [authors[2]]),
            (RecentActivity(
                id: id(3_600 * 26), authorID: authors[3],
                subject: .watched(title: "Frieren", subtitle: "The Journey's End", applicationID: nil),
                details: .init(episodeText: "Season 1, Episode 3")
            ), [authors[3]]),
            (RecentActivity(
                id: id(3_600 * 5), authorID: authors[4],
                subject: .activity(name: "Wordle", applicationID: nil),
                traits: [.trending]
            ), [authors[4]]),
            (RecentActivity(
                id: id(74), authorID: listener,
                subject: .listeningSession(track: "Moonlight Drive", artists: ["Night Swim"], artworkURL: sessionArt),
                traits: [.live],
                startedAt: now.addingTimeInterval(-74), expiresAt: now.addingTimeInterval(600)
            ), [listener]),
        ]
        model.activityFeed.inbox = ActivityInbox(
            entries: entries.enumerated().map { rank, pair in
                ActivityFeedEntry(activity: pair.0, rank: rank, participants: pair.1, raw: Data("{}".utf8))
            },
            refreshToken: nil,
            expiresAt: .distantFuture,
            announcesStaleness: false
        )
    }
}
