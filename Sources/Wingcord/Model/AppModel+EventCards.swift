import Foundation
import WingcordCore

// MARK: - Event cards in messages
//
// Discord's event embed (`427080`, under `484724` for a link and `230797`'s
// invite card for an invite with `?event=`), read rule for rule: what the
// card is about, the server its footer names, and the one button it shows.

/// The server an event card's footer names: the reader's own where they are in
/// it, and otherwise what the invite said about it.
struct EventCardServer: Equatable {
    var id: GuildID
    var name: String
    var iconURL: URL?
    var monogram: String
    var mark: GuildMark?
}

/// The one button on an event card — Discord's `$` in `427080`, in its order.
enum EventCardAction: Equatable {
    /// A server the reader is not in: join it — through the invite, where the
    /// card came from one.
    case joinServer
    /// On now somewhere other than a room: the card's own click, named.
    case viewDetails
    /// On now in a room the reader is already in.
    case goToChannel
    /// On now in a room.
    case join
    /// Over, or cancelled.
    case over
    /// Not on yet: Discord's bell, a check once the reader is in.
    case interested(Bool)

    var title: String {
        switch self {
        case .joinServer, .join: "Join"
        case .viewDetails: "View Details"
        case .goToChannel: "Go To Channel"
        case .over: "Event is over"
        case .interested: "Interested"
        }
    }

    /// Discord's "active" face — the green one — or the grey "secondary".
    var isProminent: Bool {
        switch self {
        case .joinServer, .join, .goToChannel, .interested(true): true
        case .viewDetails, .over, .interested(false): false
        }
    }
}

extension AppModel {

    /// The event on now in a room — Discord's `getActiveEventByChannel`,
    /// which decides whether a stage start wears its event's card.
    func liveEvent(in channelID: ChannelID) -> ScheduledEvent? {
        guard let guildID = channelIndex.guildID(of: channelID) else { return nil }
        return scheduledEvents[guildID]?.first { $0.status == .active && $0.location.channelID == channelID }
    }

    /// The event a card is about — the store's, which the gateway keeps
    /// current, then the invite's, then one fetched for the card. Nil while
    /// none has arrived.
    func knownEvent(for key: EventCardKey) -> ScheduledEvent? {
        scheduledEvents[key.guildID]?.first { $0.id == key.eventID }
            ?? key.invite.flatMap(inviteEvent(forKey:))
            ?? linkedEvents[key.eventID]
    }

    /// What the card draws, or nil for no card: no event yet, or a date the
    /// series cannot have — Discord's `p$`, which draws nothing for it.
    func cardEvent(for key: EventCardKey) -> ScheduledEvent? {
        guard let event = knownEvent(for: key) else { return nil }
        if let occurrence = key.occurrence, let rule = event.rule, !rule.admits(occurrence: occurrence) {
            return nil
        }
        return event
    }

    /// The date a card shows: the one linked, or the series' current one.
    func cardOccurrence(for key: EventCardKey, of event: ScheduledEvent) -> UInt64? {
        key.occurrence ?? event.currentOccurrenceID
    }

    /// The server the footer names. Nil for a server the reader is not in that
    /// no invite described — Discord's footer has no server then.
    func cardServer(for key: EventCardKey) -> EventCardServer? {
        if let guild = guilds[key.guildID] {
            return EventCardServer(
                id: guild.id,
                name: guild.name,
                iconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 96) },
                monogram: guild.monogram,
                mark: guild.mark
            )
        }
        guard let invite = key.invite.flatMap(inviteCard(forKey:)), let guildID = invite.guildID else { return nil }
        return EventCardServer(
            id: guildID,
            name: invite.name,
            iconURL: invite.iconHash.flatMap { CDN.guildIcon(guildID: guildID, hash: $0, side: 96) },
            monogram: Guild.monogram(of: invite.name),
            mark: invite.mark
        )
    }

    /// The room's name for the footer's place line: the store's where the
    /// reader can see it, the invite's channel otherwise.
    func cardChannelName(for key: EventCardKey, channelID: ChannelID) -> String? {
        if let channel = channelIndex[channelID] { return displayName(of: channel) }
        guard let invite = key.invite.flatMap(inviteCard(forKey:)), invite.channelID == channelID else { return nil }
        return invite.channelName
    }

    /// Discord's button for this card, rule for rule.
    func cardAction(for key: EventCardKey, event: ScheduledEvent) -> EventCardAction {
        guard guilds[key.guildID] != nil else { return .joinServer }
        switch event.status {
        case .active:
            guard let channelID = event.location.channelID else { return .viewDetails }
            return connectedVoiceChannelID == channelID ? .goToChannel : .join
        case .completed, .canceled:
            return .over
        case .scheduled, .unrecognised:
            return .interested(isInterested(in: event.id, at: cardOccurrence(for: key, of: event)))
        }
    }

    /// The card's click: the event's details, for a reader in its server.
    func openCardEvent(_ key: EventCardKey, event: ScheduledEvent) {
        guard guilds[key.guildID] != nil else { return }
        openEvents(inGuild: key.guildID, event: event.id, occurrence: cardOccurrence(for: key, of: event))
    }

    /// The footer's server: the room an event is on in, else the server —
    /// Discord's `rq`.
    func openCardServer(_ key: EventCardKey, event: ScheduledEvent) {
        guard guilds[key.guildID] != nil else { return }
        if event.status == .active, let channelID = event.location.channelID, canOpen(channelID) {
            selectGuild(key.guildID)
            selectChannel(channelID)
        } else {
            selectGuild(key.guildID)
        }
    }

    /// The footer's room, which a click joins — Discord's `GI`: a stage is
    /// joined and shown, a voice room only joined.
    func joinCardPlace(_ event: ScheduledEvent) {
        switch event.location {
        case .stage: joinEventRoom(event)
        case .voice(let channelID): joinVoice(channelID)
        case .external, .unrecognised: break
        }
    }

    /// Join for a server the reader is not in: the invite the card came from,
    /// or the server's own door — Discord's `joinGuild` from the event embed,
    /// which a server that is not open to the public refuses.
    func joinCardServer(_ key: EventCardKey) {
        if let invite = key.invite.flatMap(inviteCard(forKey:)) {
            openInvite(invite)
        } else {
            sessionController.joinServer(fromEventCard: key.guildID)
        }
    }

    private func inviteCard(forKey key: String) -> InviteCard? {
        guard case .resolved(let card)? = inviteLookups[key] else { return nil }
        return card
    }

    private func inviteEvent(forKey key: String) -> ScheduledEvent? {
        inviteCard(forKey: key)?.event
    }
}
