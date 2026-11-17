import Foundation
import WingcordCore

/// One friend doing something, for the Friends page's Active Now column
/// (#18) — Discord's right-hand column on its own Friends page.
struct ActiveNowCard: Identifiable, Hashable, Sendable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var monogram: String
    var status: PresenceStatus
    var client: PresenceClient
    /// What they are doing, in a word or two: the game, "Spotify", the room.
    var headline: String
    /// The line under it: how long, what song, which server.
    var detail: String
    /// The picture at the card's end: the game's mark, the album, the server.
    var artURL: URL?
    /// What stands there when there is no picture.
    var artSymbol: String
    /// When it began, for the order — newest first, as Discord's.
    var since: Date?
    /// The others in their voice room, when they are in one: their faces.
    var roomFaces: [Face] = []
    var roomCount: Int = 0
    /// They're in an embedded activity the reader can reach: Join Activity
    /// (decision 8).
    var canJoinActivity = false

    struct Face: Hashable, Sendable {
        var url: URL?
        var monogram: String
    }
}

extension AppModel {

    /// Every friend doing something right now: playing, listening, watching,
    /// streaming, or sitting in a voice room the reader can see — newest first.
    ///
    /// **From presences and voice states this session already holds**, so the
    /// column is live and asks nothing of Discord. A custom status alone is not
    /// an activity, as Discord's column does not count one.
    func activeNowCards(now: Date = .now) -> [ActiveNowCard] {
        var cards: [ActiveNowCard] = []
        for (userID, relationship) in relationships where relationship == .friend {
            let status = presenceStatus(of: userID)
            guard status != .offline, status != .invisible, status != .unknown else { continue }
            let presence = presences[userID]
            let activity = presence?.primaryActivity
            let voice = voiceStates[userID].flatMap { state -> (Channel, VoiceState)? in
                guard let channelID = state.channelID, let channel = channelIndex[channelID] else { return nil }
                return (channel, state)
            }
            guard activity != nil || voice != nil else { continue }
            let user = users[userID]
            var card = ActiveNowCard(
                id: userID,
                name: friendNicknames[userID] ?? user?.preferredName ?? "Unknown",
                avatarURL: user.flatMap { avatarURL(for: $0, side: 36) },
                monogram: user?.monogram ?? "?",
                status: status,
                client: presence?.client ?? .desktop,
                headline: "",
                detail: "",
                artSymbol: "gamecontroller.fill"
            )
            if let activity {
                card.headline = activity.name
                card.since = activity.startedAt
                card.detail = Self.activeNowDetail(of: activity, now: now)
                card.artURL = activity.largeImageURL ?? activeNowArtURL(for: activity)
                card.artSymbol = switch activity.kind {
                case .listening: "music.note"
                case .watching: "play.rectangle.fill"
                case .streaming: "dot.radiowaves.left.and.right"
                case .competing: "trophy.fill"
                default: "gamecontroller.fill"
                }
            }
            if let (channel, _) = voice {
                let others = voiceStates(in: channel.id).filter { $0.userID != userID }
                card.roomCount = others.count + 1
                card.roomFaces = others.prefix(4).map { state in
                    let person = users[state.userID]
                    return ActiveNowCard.Face(
                        url: person.flatMap { avatarURL(for: $0, side: 20) },
                        monogram: person?.monogram ?? "?"
                    )
                }
                // A room and nothing else is the card's subject; beside a game,
                // it is where they are playing.
                let room = displayName(of: channel)
                let server = channel.guildID.flatMap { guilds[$0]?.name }
                if activity == nil {
                    card.headline = room
                    card.detail = server.map { "In voice · \($0)" } ?? "In a call"
                    card.artSymbol = "speaker.wave.2.fill"
                    card.artURL = channel.guildID.flatMap { guildID in
                        guilds[guildID]?.iconHash.flatMap { CDN.guildIcon(guildID: guildID, hash: $0, side: 40) }
                    }
                } else {
                    card.detail += server.map { " · in \(room), \($0)" } ?? " · in a call"
                }
            }
            if let instance = activityInstances.instance(for: userID),
               channelIndex[instance.location.channelID] != nil,
               runningActivity?.applicationID != instance.applicationID
                || runningActivity?.instance.location.channelID != instance.location.channelID {
                card.canJoinActivity = true
            }
            cards.append(card)
        }
        return cards.sorted {
            switch ($0.since, $1.since) {
            case let (lhs?, rhs?): lhs > rhs
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// The line under an activity: what, and for how long.
    /// Joins the activity a friend's Active Now card offers.
    func joinFriendActivity(_ userID: UserID) {
        guard let instance = activityInstances.instance(for: userID) else { return }
        joinActivityInstance(instance)
    }

    static func activeNowDetail(of activity: Activity, now: Date) -> String {
        let elapsed = activity.startedAt.map { Self.activeNowElapsed(since: $0, now: now) }
        switch activity.kind {
        case .listening:
            let song = [activity.details, activity.state].compactMap(\.self).joined(separator: " — ")
            return song.isEmpty ? "Listening" : song
        case .watching:
            return activity.details ?? "Watching"
        case .streaming:
            return activity.details ?? "Live"
        default:
            return ["Playing", elapsed].compactMap(\.self).joined(separator: " · ")
        }
    }

    /// "1h", "23m", "2d" — Discord's own short form.
    static func activeNowElapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }

    /// A game's mark for its card, when the activity carries no picture of
    /// its own.
    private func activeNowArtURL(for activity: Activity) -> URL? {
        guard let applicationID = activity.applicationID else { return nil }
        if let game = games[applicationID], let url = gameArtURL(game, kind: .mark, side: 40) {
            return url
        }
        return applicationIconURL(applicationID, side: 40)
    }
}
