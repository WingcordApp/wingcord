import Foundation
import WingcordCore
import WingcordNet

// MARK: - Hosted cards in messages

extension SessionController {

    /// Readies the hosted cards these messages carry: a profile card for every
    /// profile link, an event card for every event link, the card a stage
    /// start wears for the event it started, and a text file's preview.
    func resolveHostedCards(in messages: [Message], inGuild guildID: GuildID?) {
        for message in messages {
            resolveUserCards(in: message, inGuild: guildID)
            resolvePlaintextCards(in: message)
            for link in EventLink.links(in: message.content) {
                resolveEventCard(EventCardKey(guildID: link.guildID, eventID: link.eventID, occurrence: link.occurrence))
            }
            for link in ActivityLink.links(in: message.content) {
                resolveActivityCard(ActivityCardKey(applicationID: link.applicationID, channelID: message.channelID))
            }
            if message.kind == .stageStart, let event = model.liveEvent(in: message.channelID),
               event.name == message.content
            {
                resolveEventCard(EventCardKey(guildID: event.guildID, eventID: event.id))
            }
        }
    }

    /// Fetches the profile behind every profile link in a message and measures
    /// its card — Discord's user profile embed, which asks for the profile as
    /// the message is drawn.
    ///
    /// **Once per person and server a session**, like an invite: the card is
    /// the app's own profile card, so it stays current from the store after
    /// that, and a card that later changes size says so itself — see
    /// `UserLinkCard`.
    private func resolveUserCards(in message: Message, inGuild guildID: GuildID?) {
        for userID in UserLink.userIDs(in: message.content) {
            let key = HostedCardKey.user(UserCardKey(userID: userID, guildID: guildID))
            guard model.hostedCardSizes[key] == nil, hostedCardFetches.insert(key).inserted else { continue }
            Task { [weak self] in
                guard let self else { return }
                await fetchProfile(of: userID, inGuild: guildID)
                // Nothing to draw a card from: the link stays a link.
                guard model.users[userID] != nil else { return }
                model.noteHostedCardSize(HostedCardHosts.measure(key, model: model), for: key)
            }
        }
    }

    /// Measures each text file's preview before its row is first drawn, so it
    /// never draws as a file card first. **Nothing is fetched here**: folded,
    /// a preview is the same height whatever the file says, and the file is
    /// asked for when the card comes into view, as Discord's asks as it
    /// mounts.
    private func resolvePlaintextCards(in message: Message) {
        for attachment in message.attachments
        where !TimelineLayoutEngine.isVisualMedia(attachment)
            && PlaintextPreview.isPreviewable(filename: attachment.filename)
        {
            let key = HostedCardKey.plaintext(PlaintextCardKey(attachment))
            guard model.hostedCardSizes[key] == nil, hostedCardFetches.insert(key).inserted else { continue }
            model.noteHostedCardSize(HostedCardHosts.measure(key, model: model), for: key)
        }
    }

    /// Readies one activity link's card: the app's page (its tags and how many
    /// can play), the shelf for its cover, then the card's size. A link to an
    /// app Discord won't describe stays a link.
    func resolveActivityCard(_ card: ActivityCardKey) {
        let key = HostedCardKey.activity(card)
        guard model.hostedCardSizes[key] == nil, hostedCardFetches.insert(key).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            await loadActivityDirectory()
            await loadActivityApp(card.applicationID)
            guard model.activityApp(card.applicationID) != nil else { return }
            model.noteHostedCardSize(HostedCardHosts.measure(key, model: model), for: key)
        }
    }

    /// Readies one event card — Discord's `484724` as it mounts: the event
    /// where the store lacks it, the date's count, the reader's answers, and
    /// then the card's size.
    ///
    /// **Measured at once when the event is already held**, so an invite that
    /// turns into an event card never draws as an invite first.
    func resolveEventCard(_ card: EventCardKey) {
        let key = HostedCardKey.event(card)
        guard model.hostedCardSizes[key] == nil, hostedCardFetches.insert(key).inserted else { return }
        if let event = model.knownEvent(for: card) {
            prepareEventCard(card, event: event)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let event = try await rest.scheduledEvent(card.eventID, in: card.guildID)
                model.linkedEvents[event.id] = event
                prepareEventCard(card, event: event)
            } catch {
                // Not there, or not the reader's to see: the link stays a link.
                Self.trace("event card \(card.eventID) failed: \(Self.describe(error))")
            }
        }
    }

    private func prepareEventCard(_ card: EventCardKey, event: ScheduledEvent) {
        // The event carries its maker; the store is where the mark looks a
        // face up, and a member's server face is a member fetch away.
        if let creator = event.creator, model.users[creator.id] == nil { model.users[creator.id] = creator }
        let isMember = model.guilds[card.guildID] != nil
        if isMember, let creatorID = event.creatorID, model.members[card.guildID]?[creatorID] == nil, let socket {
            Task { await socket.requestGuildMembers(guildID: card.guildID, userIDs: [creatorID]) }
        }
        loadEventCounts(event, occurrences: model.cardOccurrence(for: card, of: event).map { [$0] } ?? [])
        if isMember, eventCardAnswerFetches.insert(card.guildID).inserted {
            loadEventAnswers(inGuild: card.guildID)
        }
        let key = HostedCardKey.event(card)
        model.noteHostedCardSize(HostedCardHosts.measure(key, model: model), for: key)
    }

    /// An event went live: the stage start that announced it, if the reader
    /// has it loaded, wears its card from now — Discord reads the live event
    /// as the line draws, and the line may have landed first.
    func noteEventWentLive(_ event: ScheduledEvent) {
        guard event.status == .active, let channelID = event.location.channelID,
              model.messages(in: channelID)?.messages.contains(where: {
                  $0.kind == .stageStart && $0.content == event.name
              }) == true
        else { return }
        resolveEventCard(EventCardKey(guildID: event.guildID, eventID: event.id))
    }

    /// Join on an event card for a server the reader is not in, with no invite
    /// behind it — Discord's `joinGuild` from the embed (source "Guild Event
    /// Embed"), which only a server open to the public lets through.
    func joinServer(fromEventCard guildID: GuildID) {
        guard eventCardJoins.insert(guildID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { eventCardJoins.remove(guildID) }
            do {
                _ = try await rest.joinGuild(guildID, source: "Guild Event Embed")
            } catch {
                Self.trace("join \(guildID.rawValue) from event card failed: \(Self.describe(error))")
                // Discord's own words for a server the reader cannot reach.
                model.reportActionFailure(
                    error.isUnknownGuild
                        ? "This link is to a server or channel you don't have access to."
                        : Self.joinFailure(error)
                )
                return
            }
            GuildArrangement.placeJoined(guildID, in: &model.folders)
            model.permissionGate.invalidate()
            model.railRevision &+= 1
        }
    }
}

private extension Error {
    /// Discord's 10004, Unknown Guild — its embed's cue for "you don't have
    /// access to this link".
    var isUnknownGuild: Bool {
        switch self as? DiscordREST.Failure {
        case .notFound: true
        case .api(_, 10004?, _): true
        default: false
        }
    }
}
