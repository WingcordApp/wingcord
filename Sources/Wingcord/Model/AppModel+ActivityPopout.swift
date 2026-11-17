import Foundation
import WingcordCore

// MARK: - An activity card's popout (docs/ACTIVITY-CARDS.md decisions 8 to 10)

extension AppModel {

    /// The popout for one entry, as Discord's popouts for its kind draw it.
    func activityPopout(for entry: ActivityFeedEntry, inGuild guildID: GuildID?, now: Date) -> ActivityPopoutPresentation {
        let activity = entry.activity
        let author = activity.authorID
        let live = activity.isOngoing(at: now)
        let presence = activity.isLive ? matchingPresence(for: entry) : nil
        let context = activityMarkerContext(for: entry, inGuild: guildID, now: now)

        let people = entry.participants.prefix(3).map { userID in
            ActivityPopoutPresentation.Person(
                userID: userID,
                name: guildID.map { voiceName(of: userID, inGuild: $0) } ?? users[userID]?.preferredName ?? "Somebody",
                style: users[userID].flatMap { cosmetics(of: $0)?.displayNameStyle }.flatMap { $0.isPlain ? nil : $0 },
                avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: 24),
                monogram: users[userID]?.monogram ?? "?"
            )
        }

        var title = activity.subject.title
        var titleDestination: ActivityPopoutPresentation.Destination?
        var subtitle = presence?.details
        var subtitleDestination: ActivityPopoutPresentation.Destination?
        var corner: ActivityPopoutPresentation.Corner?
        var offers: [GameStoreOffer] = []
        var span: ClosedRange<Date>?
        let verb: String

        switch activity.subject {
        case .game(_, let applicationID):
            verb = context.isStreaming ? "is streaming" : live ? "is playing" : "played"
            titleDestination = applicationID.map { .gameProfile($0) }
            offers = applicationID.flatMap { games[$0]?.storeOffers } ?? []
            corner = Self.platformCorner(activity.details.platform)
        case .topGame(_, let applicationID):
            verb = "played"
            titleDestination = applicationID.map { .gameProfile($0) }
            corner = Self.platformCorner(activity.details.platform)
        case .activity:
            verb = live ? "is playing" : "played"
        case .listening(let track, let artist, _):
            // Discord's top artist popout: the album over the artist, both
            // opening Spotify (`up`).
            verb = "listened to"
            title = activity.details.album ?? track
            subtitle = artist
            titleDestination = Self.spotifyLink("album", activity.details.albumExternalID)
            subtitleDestination = Self.spotifyLink("artist", activity.details.artistExternalID)
            corner = activity.details.provider == 1
                ? .init(service: "spotify", label: "Spotify", destination: titleDestination) : nil
        case .listeningSession(let track, let artists, _):
            verb = live ? "is listening to" : "listened to"
            title = presence?.details ?? track
            subtitle = presence?.state?.replacingOccurrences(of: "; ", with: ", ")
                ?? (artists.isEmpty ? nil : artists.joined(separator: ", "))
            let trackLink = presence?.syncID.flatMap { Self.spotifyLink("track", $0) }
            titleDestination = trackLink
            corner = .init(service: "spotify", label: "Play on Spotify", destination: trackLink)
            if let start = presence?.startedAt, let end = presence?.endsAt, end > start { span = start ... end }
        case .watched(_, let episode, _):
            verb = live ? "is watching" : "watched"
            subtitle = episode
            titleDestination = activity.details.url.map { .link($0) }
            corner = .init(service: "crunchyroll", label: "Crunchyroll", destination: titleDestination)
        }

        return ActivityPopoutPresentation(
            entryID: entry.id,
            authorID: author,
            people: Array(people),
            othersCount: max(0, entry.participants.count - 2),
            verb: verb,
            isStreaming: context.isStreaming,
            title: title,
            titleDestination: titleDestination,
            subtitle: subtitle.flatMap { $0.isEmpty ? nil : $0 },
            subtitleDestination: subtitleDestination,
            artURL: activityArtURL(for: entry, side: 72, prefersCover: true),
            artIsCover: activityArtIsCover(for: entry),
            artSymbol: activity.subject.symbolName,
            markers: ActivityMarkers.markers(for: activity, at: .popout, context: context),
            liveSince: live ? presence?.startedAt ?? activity.startedAt ?? entry.snowflakeDate : nil,
            occurredAt: entry.snowflakeDate,
            corner: corner,
            storeOffers: offers,
            songSpan: span,
            voice: activity.isLive ? activityVoiceBar(for: author) : nil,
            applicationID: activity.subject.applicationID,
            liveActivity: presence,
            canListenAlong: presence.map { $0.kind == .listening && SpotifyListening.isSpotifyParty($0.partyID) && $0.syncID != nil } ?? false
        )
    }

    /// The author's voice channel, where the reader may see it — Discord's
    /// voice bar (`cj`): the server, the room, up to three faces.
    private func activityVoiceBar(for userID: UserID) -> ActivityPopoutPresentation.VoiceBar? {
        guard let state = voiceStates[userID], let channelID = state.channelID,
              permissionGate.canView(channelID), let channel = channelIndex[channelID]
        else { return nil }
        let guild = channel.guildID.flatMap { guilds[$0] }
        let here = voiceStates.values.filter { $0.channelID == channelID }.map(\.userID)
        let faces = here.prefix(3).map { person in
            ActivityMarkerFace(
                url: avatarURL(forUserID: person, inGuild: channel.guildID, side: 16),
                monogram: users[person]?.monogram ?? "?"
            )
        }
        return ActivityPopoutPresentation.VoiceBar(
            channelID: channelID,
            guildIconURL: guild.flatMap { guild in
                guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 16) }
            },
            guildMonogram: guild.map { Self.monogram(of: $0.name) } ?? "#",
            channelName: channel.name,
            faces: Array(faces),
            extraCount: max(0, here.count - 3),
            isStreaming: state.isStreaming,
            isReaderHere: currentUserID.flatMap { voiceStates[$0]?.channelID } == channelID
        )
    }

    private static func platformCorner(_ platform: Int?) -> ActivityPopoutPresentation.Corner? {
        switch platform {
        case 1: .init(service: "xbox", label: "Xbox", destination: nil)
        case 2: .init(service: "playstation", label: "PlayStation", destination: nil)
        default: nil
        }
    }

    private static func spotifyLink(_ kind: String, _ id: String?) -> ActivityPopoutPresentation.Destination? {
        guard let id, !id.isEmpty, let url = URL(string: "https://open.spotify.com/\(kind)/\(id)") else { return nil }
        return .link(url)
    }

    /// Five emoji to answer with, Discord's way (`dX.Fj`): the reader's most
    /// used that can be sent here, then its defaults.
    func activityReplyEmoji(limit: Int = 5) -> [ExpressionItem] {
        let table = emojiNameTable
        let offers = emojiOfferRule()
        var picked: [ExpressionItem] = []
        var seen = Set<String>()
        let keys = (expressionUsage?.emojis.ranked ?? [])
            + ["thumbsup", "eyes", "laughing", "watermelon", "fork_and_knife", "yum"]
        for key in keys where picked.count < limit {
            let entry: EmojiNameTable.Entry?
            if let id = UInt64(key) {
                entry = table.name(ofCustom: id).flatMap { table.entry(named: $0) }
            } else if let glyph = UnicodeEmoji.glyph(forDiscordName: key) {
                entry = table.entries.first { $0.glyph == glyph }
            } else {
                entry = nil
            }
            guard let entry, offers(entry), seen.insert(entry.name).inserted else { continue }
            picked.append(completionItem(for: entry))
        }
        return picked
    }
}
