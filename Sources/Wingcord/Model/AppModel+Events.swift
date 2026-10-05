import AppKit
import Foundation
import WingcordCore

// MARK: - Scheduled events, from a member's side
//
// Everything here is Discord's own rule, read out of its web bundle: the store
// (`698441`), the list's selectors (`508654`), the RSVP decision (`929267`) and
// the action creators (`496092`). The organiser's side — creating, editing,
// cancelling — has lived in Server Settings since before this file.

/// The reader's answers to one event.
struct EventAnswers: Hashable, Sendable {
    /// The whole series', or nil where they have not answered it.
    var series: ScheduledEventRSVP.Response?
    /// Single dates', by occurrence id.
    var dates: [UInt64: ScheduledEventRSVP.Response] = [:]
}

/// The open events panel, and which page of it.
struct EventsPanelRequest: Equatable {
    enum Page: Equatable {
        case list
        /// One event, at one date of it where it repeats.
        case event(UInt64, occurrence: UInt64?)
    }

    var guildID: GuildID
    var page: Page
    /// The events cursor as it stood when the panel opened, which is what
    /// marks an event NEW — read once, so opening the panel (which moves the
    /// cursor) does not take the marks away while they are on screen.
    var newSince: UInt64?
}

/// What pressing Interested comes to — Discord's `QC`.
enum EventInterestStep: Equatable {
    /// Write this answer at this level: a series' when `occurrence` is nil.
    /// `nil` answer is a take-back.
    case write(ScheduledEventRSVP.Response?, occurrence: UInt64?)
    /// A date of a series nobody has answered yet: ask which they mean.
    case ask(occurrence: UInt64)
}

extension AppModel {

    // MARK: Which events

    /// The server's events that are on or still to come, in Discord's order:
    /// happening now first, then by start, then by id — and only those whose
    /// channel the reader can see (`508654`'s `G`).
    func upcomingEvents(inGuild guildID: GuildID) -> [ScheduledEvent] {
        (scheduledEvents[guildID] ?? [])
            .filter { $0.status.isLive && canSeeEventPlace($0) }
            .sorted(by: Self.eventOrder)
    }

    /// The first event happening now that the reader can see — what the rail
    /// marks and the sidebar's live card shows (`508654`'s `y`). An entity
    /// type this client does not know is no live place to show.
    func activeEvent(inGuild guildID: GuildID) -> ScheduledEvent? {
        (scheduledEvents[guildID] ?? [])
            .filter { $0.status == .active && $0.location.isEditable && canSeeEventPlace($0) }
            .min(by: Self.eventOrder)
    }

    /// An event in no channel is everybody's; one in a channel is the
    /// channel's audience's.
    func canSeeEventPlace(_ event: ScheduledEvent) -> Bool {
        guard let channelID = event.location.channelID else { return true }
        return permissionGate.canView(channelID)
    }

    /// Discord's sort key: `"\0"` for an active event and `"\x01"` otherwise,
    /// then the start in milliseconds, then the id.
    nonisolated static func eventOrder(_ lhs: ScheduledEvent, _ rhs: ScheduledEvent) -> Bool {
        let lhsActive = lhs.status == .active, rhsActive = rhs.status == .active
        if lhsActive != rhsActive { return lhsActive }
        if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
        return lhs.id < rhs.id
    }

    /// Whether the sidebar offers its Events row: there is something coming,
    /// or the reader may make something (`useGuildActionRows`).
    func offersEventsRow(inGuild guildID: GuildID) -> Bool {
        !upcomingEvents(inGuild: guildID).isEmpty || canManageEvents(inGuild: guildID)
    }

    /// The live card for a server's event happening now, unless the reader
    /// closed it this session.
    func liveEventNotice(for guildID: GuildID) -> LiveEventNotice? {
        guard let event = activeEvent(inGuild: guildID),
              !dismissedEventNotices.contains(event.id)
        else { return nil }
        switch event.location {
        case .external(let place):
            return LiveEventNotice(
                eventID: event.id, guildID: guildID, name: event.name,
                heading: "Happening Now", place: place, placeSymbol: "mappin.and.ellipse",
                joinChannelID: nil
            )
        case .voice(let channelID), .stage(let channelID):
            guard let channel = channelIndex[channelID] else { return nil }
            return LiveEventNotice(
                eventID: event.id, guildID: guildID, name: event.name,
                heading: "Live Now", place: displayName(of: channel),
                placeSymbol: channel.kind.symbolName,
                joinChannelID: permissionGate.canJoinVoice(channelID) ? channelID : nil,
                isJoined: connectedVoiceChannelID == channelID,
                isStage: channel.kind == .stage
            )
        case .unrecognised:
            return nil
        }
    }

    /// The sidebar's events row, or nil where Discord would draw none.
    func sidebarEventsRow(for guildID: GuildID) -> SidebarEventsRow? {
        guard offersEventsRow(inGuild: guildID) else { return nil }
        let events = upcomingEvents(inGuild: guildID)
        // The events cursor, as the inbox reads it — or, with none, the day
        // the reader joined: nothing made before they came is new to them.
        let cursor = guildEventAcks[guildID]?.rawValue
            ?? guilds[guildID]?.joinedAt.map { MessageID(before: $0).rawValue }
        let muted = guildUserSettings[guildID]?.muteScheduledEvents == true
        let hasUnread = !muted && cursor.map { cursor in events.contains { $0.id > cursor } } == true
        return SidebarEventsRow(guildID: guildID, count: events.count, hasUnread: hasUnread)
    }

    func canManageEvents(inGuild guildID: GuildID) -> Bool {
        let permissions = permissionGate.permissions(inGuild: guildID)
        return permissions.contains(.manageEvents) || permissions.contains(.createEvents)
    }

    // MARK: Interest

    /// Discord's `isInterestedInEventRecurrence`: interested in the series and
    /// not out of this date, or in this date on its own.
    func isInterested(in eventID: UInt64, at occurrence: UInt64?) -> Bool {
        let answers = eventAnswers[eventID]
        let date = occurrence.flatMap { answers?.dates[$0] }
        return (answers?.series == .interested && date != .uninterested) || date == .interested
    }

    /// How many are interested in an event, or in one date of it — a date's
    /// own count where it has been asked about, the series' otherwise.
    func interestedCount(for event: ScheduledEvent, at occurrence: UInt64?) -> Int? {
        guard let counts = eventCounts[event.id] else { return event.interestedCount }
        return occurrence.flatMap { counts.occurrences[$0] } ?? counts.series
    }

    /// What pressing Interested on this event, at this date, comes to.
    ///
    /// Discord's `QC`, rule for rule: a single event toggles the series'
    /// answer; a date that is over or cancelled answers for the series; a
    /// date the reader already answered has that answer taken back; and a date
    /// nobody answered asks whether they mean the whole series or that date.
    func interestStep(for event: ScheduledEvent, at requested: UInt64?) -> EventInterestStep {
        let answers = eventAnswers[event.id] ?? EventAnswers()
        var occurrence = event.rule == nil ? nil : (requested ?? event.currentOccurrenceID)
        if let date = occurrence, [.completed, .canceled].contains(event.status(of: date)) {
            occurrence = nil
        }
        guard let occurrence else {
            return .write(answers.series == nil ? .interested : nil, occurrence: nil)
        }
        if answers.dates[occurrence] != nil {
            return .write(nil, occurrence: occurrence)
        }
        return .ask(occurrence: occurrence)
    }

    /// The answer the series picker writes — Discord's dialog: "not
    /// interested" when the reader is in the whole series, "interested"
    /// otherwise, for the series or for the one date.
    func pickedInterest(for event: ScheduledEvent, occurrence: UInt64, wholeSeries: Bool) -> EventInterestStep {
        let answers = eventAnswers[event.id] ?? EventAnswers()
        let response: ScheduledEventRSVP.Response =
            answers.series == .interested ? .uninterested : .interested
        if wholeSeries {
            // `updateRsvp` at the series' level: an answer there is taken back.
            return .write(answers.series == nil ? response : nil, occurrence: nil)
        }
        return .write(answers.dates[occurrence] == nil ? response : nil, occurrence: occurrence)
    }

    /// Writes an answer, optimistically — see `SessionController.answerEvent`.
    func apply(_ step: EventInterestStep, to event: ScheduledEvent) {
        guard case .write(let response, let occurrence) = step else { return }
        sessionController.answerEvent(event, response: response, occurrence: occurrence)
    }

    // MARK: The panel

    /// Opens the server's events, on the list or straight onto one event.
    func openEvents(inGuild guildID: GuildID, event: UInt64? = nil, occurrence: UInt64? = nil) {
        eventsPanel = EventsPanelRequest(
            guildID: guildID,
            page: event.map { .event($0, occurrence: occurrence) } ?? .list,
            newSince: guildEventAcks[guildID]?.rawValue
                ?? guilds[guildID]?.joinedAt.map { MessageID(before: $0).rawValue }
        )
        sessionController.eventsPanelDidOpen(guildID)
        // Opening the list is reading it — Discord acks the guild's events as
        // its modal mounts.
        markInboxEventsRead(guildID)
    }

    /// `https://discord.com/events/{guild}/{event}`, with the date for one
    /// date of a series — Discord's `GUILD_EVENT_DETAILS`.
    nonisolated static func eventLink(guildID: GuildID, eventID: UInt64, occurrence: UInt64?) -> String {
        let date = occurrence.map { "/\($0)" } ?? ""
        return "https://discord.com/events/\(guildID.rawValue)/\(eventID)\(date)"
    }

    /// Whether an event is newer than the cursor the panel opened with.
    func isNew(_ event: ScheduledEvent, since cursor: UInt64?) -> Bool {
        guard let cursor else { return false }
        return event.id > cursor && event.status == .scheduled
    }

    /// Turns the open panel to one event, at one date of it.
    func showEvent(_ eventID: UInt64, occurrence: UInt64?) {
        eventsPanel?.page = .event(eventID, occurrence: occurrence)
    }

    func showEventsList() {
        eventsPanel?.page = .list
    }

    /// An event link followed inside the app: the panel, for a server the
    /// reader is in. Nil — so the link opens in a browser — for any other. An
    /// event this client does not hold is over or gone, and Discord's own
    /// details close on a missing event, so the server's list opens instead.
    func openEventLink(_ link: EventLink) -> Bool {
        guard guilds[link.guildID] != nil else { return false }
        let isKnown = scheduledEvents[link.guildID]?.contains { $0.id == link.eventID } == true
        openEvents(
            inGuild: link.guildID,
            event: isKnown ? link.eventID : nil,
            occurrence: isKnown ? link.occurrence : nil
        )
        return true
    }

    // MARK: Acting on one

    /// The id of the date an event's surfaces are showing: the one asked for,
    /// or the series' current one — Discord's `T ?? G3(D)`.
    func shownOccurrence(of event: ScheduledEvent, requested: UInt64?) -> UInt64? {
        event.rule == nil ? nil : (requested ?? event.currentOccurrenceID)
    }

    /// Copies the event's link — for one date when `occurrence` is given.
    func copyEventLink(_ event: ScheduledEvent, occurrence: UInt64?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            Self.eventLink(guildID: event.guildID, eventID: event.id, occurrence: occurrence),
            forType: .string
        )
    }

    /// Opens the event in the reader's calendar, as a file — Discord's
    /// "Download ICS file".
    func addEventToCalendar(_ event: ScheduledEvent) {
        let channelName = event.location.channelID.flatMap { channelIndex[$0] }.map(displayName(of:))
        let contents = EventCalendarFile.contents(
            of: event,
            description: event.description ?? "",
            location: EventCalendarFile.location(
                of: event, guildName: guilds[event.guildID]?.name, channelName: channelName
            ),
            stamp: .now
        )
        EventCalendarFile.open(contents)
    }

    /// Joins the room an event is in and goes to it — Discord's
    /// `joinVoiceEvent`, which selects the channel and then shows it.
    func joinEventRoom(_ event: ScheduledEvent) {
        guard let channelID = event.location.channelID else { return }
        eventsPanel = nil
        if connectedVoiceChannelID != channelID { joinVoice(channelID) }
        selectGuild(event.guildID)
        selectChannel(channelID)
    }

    /// Whether the reader may run this event — start, end, cancel or edit it.
    /// Discord's `canManageGuildEvent` (`931991`): managing every event, or
    /// having made this one and holding Create Events — in the event's room
    /// where it has one.
    func canManage(_ event: ScheduledEvent) -> Bool {
        let permissions = event.location.channelID.map(permissionGate.permissions(in:))
            ?? permissionGate.permissions(inGuild: event.guildID)
        if permissions.contains(.manageEvents) { return true }
        return permissions.contains(.createEvents) && event.creatorID == currentUserID
    }
}

// MARK: - Creating and editing

/// An event to create, or one to edit — Discord's Create Event, raised from the
/// server's events.
struct EventEditorRequest: Identifiable, Hashable {
    var guildID: GuildID
    var event: ScheduledEvent?

    var id: String { "\(guildID.rawValue)-\(event?.id ?? 0)" }
}

extension AppModel {
    /// Opens the event editor over the main window, where Discord's lives.
    func openEventEditor(inGuild guildID: GuildID, event: ScheduledEvent? = nil) {
        eventsPanel = nil
        eventEditor = EventEditorRequest(guildID: guildID, event: event)
    }
}
