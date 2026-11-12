import Foundation
import WingcordCore

/// Whose Spotify the reader is following, and where it was when they joined —
/// Discord's `SpotifyStore` `r`.
struct ListeningAlong: Hashable, Sendable {
    var hostID: UserID
    var partyID: String
    var trackID: String
    var startedAt: Date
}

/// What a listen-along card paints, from the host's presence — the parts that
/// move without the row being measured again.
struct ListenAlongCard: Hashable, Sendable {
    /// "Alberto Balsalm by Aphex Twin".
    var title: String
    var artworkURL: URL?
    var startedAt: Date?
    /// When the track runs out, for the card's progress line. Nil where the
    /// host's presence carries no end.
    var endsAt: Date?
    /// Up to three of the people in the party, the host first; nil draws a
    /// face's placeholder.
    var faces: [URL?]
    var listenerCount: Int
    /// "Join", "Joined", or "Connect Spotify" where there is no account —
    /// Discord's embed button (`160768`).
    var buttonTitle: String
    var isButtonEnabled: Bool
}

extension AppModel {

    /// The parties invited to in a channel's loaded messages, painted.
    ///
    /// **A party is live while its host's presence still shows it** — the
    /// Listening activity with that `spotify:` party. One that has gone draws
    /// Discord's "The listening party is over!", which is why the keys of this
    /// table are also what the layout is told is live.
    func listenAlongCards(in channelID: ChannelID) -> [String: ListenAlongCard] {
        guard let box = messages(in: channelID) else { return [:] }
        var parties: Set<String> = []
        for message in box.messages { if let invite = message.listenAlong { parties.insert(invite.partyID) } }
        for entry in box.outbox { if let invite = entry.request.listenAlong { parties.insert(invite.partyID) } }
        guard !parties.isEmpty else { return [:] }

        // Who is in each party: one pass over the presences, for all of them.
        var members: [String: [UserID]] = [:]
        for (userID, presence) in presences {
            for activity in presence.activities?.list ?? [] {
                if let party = activity.partyID, parties.contains(party) { members[party, default: []].append(userID) }
            }
        }
        let ownParty = spotifyActivity?.party?.id
        let hasAccount = connections?.contains { $0.type == "spotify" && !$0.isRevoked } ?? false

        var cards: [String: ListenAlongCard] = [:]
        for party in parties {
            guard let host = listenAlongHost(of: party) else { continue }
            var listeners = members[party] ?? []
            if ownParty == party, let reader = currentUserID, !listeners.contains(reader) { listeners.append(reader) }
            // The host's face first, as the party is theirs.
            listeners.sort { lhs, _ in lhs == host.userID }
            let isJoined = ownParty == party
            cards[party] = ListenAlongCard(
                title: host.title,
                artworkURL: host.artworkURL,
                startedAt: host.startedAt,
                endsAt: host.endsAt,
                faces: listeners.prefix(3).map { userID in
                    users[userID].flatMap { avatarURL(for: $0, side: ListenAlongLayoutEngine.faceSide) }
                },
                listenerCount: max(host.partySize ?? 0, listeners.count),
                buttonTitle: !hasAccount ? "Connect Spotify" : isJoined ? "Joined" : "Join",
                isButtonEnabled: !hasAccount || !(isJoined || host.userID == currentUserID)
            )
        }
        return cards
    }

    /// The host's live session for a party, read off their presence — or off
    /// the reader's own Spotify, when the party is theirs.
    private func listenAlongHost(of party: String) -> (
        userID: UserID, title: String, artworkURL: URL?, startedAt: Date?, endsAt: Date?, partySize: Int?
    )? {
        guard let hostID = UInt64(party.dropFirst(SpotifyListening.partyPrefix.count)).map(UserID.init(rawValue:))
        else { return nil }
        if hostID == currentUserID {
            guard let own = spotifyActivity, own.party?.id == party else { return nil }
            return (
                hostID,
                Self.listenAlongTitle(track: own.details, artist: own.state),
                SpotifyListening.imageURL(forAsset: own.assets?.largeImage),
                own.timestamps?.start.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                own.timestamps?.end.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                nil
            )
        }
        guard let activity = presences[hostID]?.activities?.list.first(where: {
            $0.kind == .listening && $0.partyID == party
        }) else { return nil }
        return (
            hostID,
            Self.listenAlongTitle(track: activity.details, artist: activity.state),
            activity.largeImageURL ?? SpotifyListening.imageURL(forAsset: activity.largeImageKey),
            activity.startedAt,
            activity.endsAt,
            activity.partySize?.first
        )
    }

    /// Discord's "{track} by {artist}" (`JCvHtx`), or the platform's name when
    /// either half is missing.
    static func listenAlongTitle(track: String?, artist: String?) -> String {
        guard let track, let artist else { return track ?? "Spotify" }
        return "\(track) by \(artist)"
    }

    /// The card's button: Join, or link an account first.
    func pressListenAlong(_ invite: ListenAlongInvite) {
        guard connections?.contains(where: { $0.type == "spotify" && !$0.isRevoked }) == true else {
            sessionController.beginLinkingConnection(type: "spotify")
            return
        }
        guard let hostID = UInt64(invite.partyID.dropFirst(SpotifyListening.partyPrefix.count)).map(UserID.init(rawValue:))
        else { return }
        sessionController.listenAlong(with: hostID)
    }
}

/// A profile's Listen Along, as Discord words and gates it (`341335`,
/// `USER_ACTIVITY_SYNC`).
struct ListenAlongOffer {
    var help: String
    var isEnabled: Bool
    var join: () -> Void
}

extension AppModel {

    /// Listen Along on somebody's Spotify session, or nil where it offers none.
    func listenAlongOffer(for userID: UserID, activity: Activity) -> ListenAlongOffer? {
        guard activity.offersSync, SpotifyListening.isSpotifyParty(activity.partyID) else { return nil }
        let name = users[userID]?.preferredName ?? "them"
        let isAlong = listeningAlong?.hostID == userID
            || (activity.partyID != nil && spotifyActivity?.party?.id == activity.partyID)
        let help = if userID == currentUserID {
            "Listen along with someone else, not yourself."
        } else if isAlong {
            "You're already along for this ride."
        } else {
            "Listen along with \(name)"
        }
        return ListenAlongOffer(
            help: help,
            isEnabled: userID != currentUserID && !isAlong,
            join: { [weak self] in
                guard let self, let partyID = activity.partyID else { return }
                pressListenAlong(ListenAlongInvite(partyID: partyID))
            }
        )
    }
}
