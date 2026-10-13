import Foundation
import WingcordCore
import WingcordNet

// MARK: - Scheduled events, from a member's side
//
// The routes are captured in `scheduled event.har` and
// `scheduled event tower defense simulator.har`; what is asked when follows
// Discord's own modals — the list asks for every event's count and the
// reader's answers as it opens, the detail asks for its date's count.

extension SessionController {

    /// What the events list asks for as it opens (`318104`): the reader's
    /// answers, every event's count, and the members who made them.
    func eventsPanelDidOpen(_ guildID: GuildID) {
        loadEventAnswers(inGuild: guildID)
        let events = model.upcomingEvents(inGuild: guildID)
        for event in events {
            loadEventCounts(event, occurrences: event.currentOccurrenceID.map { [$0] } ?? [])
        }
        // The event carries its maker; the store is where every surface
        // looks a face and a name up.
        for creator in events.compactMap(\.creator) where model.users[creator.id] == nil {
            model.users[creator.id] = creator
        }
        let makers = events.compactMap(\.creatorID).filter { model.members[guildID]?[$0] == nil }
        if !makers.isEmpty, let socket {
            Task { await socket.requestGuildMembers(guildID: guildID, userIDs: Array(Set(makers))) }
        }
    }

    /// The reader's answers to a server's events. Replaces what was held for
    /// that server's events, so an answer withdrawn in another client goes.
    func loadEventAnswers(inGuild guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let answers = try await rest.scheduledEventRSVPs(in: guildID)
                let eventIDs = Set((model.scheduledEvents[guildID] ?? []).map(\.id))
                var table = model.eventAnswers.filter { !eventIDs.contains($0.key) }
                for answer in answers {
                    if let date = answer.occurrence {
                        table[answer.eventID, default: EventAnswers()].dates[date] = answer.response
                    } else {
                        table[answer.eventID, default: EventAnswers()].series = answer.response
                    }
                }
                if table != model.eventAnswers { model.eventAnswers = table }
            } catch {
                Self.trace("event answers in \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// An event's counts: the series', and the dates asked about — merged into
    /// what is held, so asking about a new date keeps the others.
    func loadEventCounts(_ event: ScheduledEvent, occurrences: [UInt64]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await rest.interestedCounts(
                    for: event.id, in: event.guildID, occurrences: occurrences
                )
                var counts = model.eventCounts[event.id] ?? ScheduledEventCounts(series: fetched.series)
                counts.series = fetched.series
                counts.occurrences.merge(fetched.occurrences) { _, new in new }
                if model.eventCounts[event.id] != counts { model.eventCounts[event.id] = counts }
            } catch {
                Self.trace("event \(event.id) counts failed: \(Self.describe(error))")
            }
        }
    }

    /// Gives an answer, at once on screen and then on the wire — Discord's
    /// `updateRsvp`, which dispatches the change before the request and takes
    /// it back if the request fails.
    func answerEvent(_ event: ScheduledEvent, response: ScheduledEventRSVP.Response?, occurrence: UInt64?) {
        let before = model.eventAnswers[event.id] ?? EventAnswers()
        var after = before
        if let occurrence {
            after.dates[occurrence] = response
        } else {
            after.series = response
        }
        model.eventAnswers[event.id] = after
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setEventRSVP(response, for: event.id, occurrence: occurrence, in: event.guildID)
                // The counts are the server's to say: one answer moves the
                // series and every date differently.
                let asked = model.eventCounts[event.id].map { Array($0.occurrences.keys) } ?? []
                loadEventCounts(event, occurrences: asked + (occurrence.map { [$0] } ?? []))
            } catch {
                if model.eventAnswers[event.id] == after { model.eventAnswers[event.id] = before }
                Self.trace("answer to event \(event.id) failed: \(Self.describe(error))")
            }
        }
    }

    /// The people interested in an event or one date of it, harvested into
    /// the store so their names and faces resolve. Nil when the route refuses.
    func interestedPeople(in event: ScheduledEvent, at occurrence: UInt64?) async -> [ScheduledEventInterest]? {
        do {
            let rows = try await rest.interestedUsers(for: event.id, occurrence: occurrence, in: event.guildID)
            model.users.merge(rows.map { ($0.user.id, $0.user) }) { existing, new in new.merged(over: existing) }
            for row in rows {
                guard let member = row.member, model.members[event.guildID]?[row.user.id] == nil else { continue }
                model.members[event.guildID, default: [:]][row.user.id] = member
            }
            return rows
        } catch {
            Self.trace("interested in event \(event.id) failed: \(Self.describe(error))")
            return nil
        }
    }

    // MARK: Running one
    //
    // An organiser's acts from the panel. Each stores what the route answers
    // with as soon as it does; the gateway's own copy follows and lands on top.

    /// Starts or ends an event — `PATCH {"status": n}`. Starting one in a room
    /// also takes the reader into it, as Discord's start does.
    func setEventStatus(_ event: ScheduledEvent, to status: ScheduledEvent.Status) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let updated = try await rest.setEventStatus(status, for: event.id, in: event.guildID) {
                    storeScheduledEvent(updated)
                }
                if status == .active, case .voice(let channelID) = event.location,
                   model.connectedVoiceChannelID != channelID
                {
                    model.joinVoice(channelID)
                }
            } catch {
                Self.trace("event \(event.id) status \(status.rawValue) failed: \(Self.describe(error))")
            }
        }
    }

    /// Deletes an event — Discord's Cancel Event, which is a `DELETE`.
    func deleteScheduledEvent(_ event: ScheduledEvent) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.deleteEvent(event.id, in: event.guildID)
                model.scheduledEvents[event.guildID]?.removeAll { $0.id == event.id }
                model.inbox.revision &+= 1
                if case .event(event.id, _) = model.eventsPanel?.page { model.showEventsList() }
            } catch {
                Self.trace("deleting event \(event.id) failed: \(Self.describe(error))")
            }
        }
    }

    /// Cancels one date of a series, or puts a cancelled one back — Discord's
    /// `deleteRecurrence` and its Restore Event.
    func setEventDate(_ occurrence: UInt64, of event: ScheduledEvent, canceled: Bool) {
        let existing = event.exception(for: occurrence)
        Task { [weak self] in
            guard let self else { return }
            do {
                var stored: ScheduledEvent.Exception?
                switch (canceled, existing) {
                case (true, let exception?):
                    try await rest.setEventDateCanceled(true, exception, of: event.id, in: event.guildID)
                    stored = ScheduledEvent.Exception(
                        id: occurrence, startsAt: exception.startsAt, endsAt: exception.endsAt, isCanceled: true
                    )
                case (true, nil):
                    try await rest.cancelEventDate(occurrence, of: event.id, in: event.guildID)
                    stored = ScheduledEvent.Exception(id: occurrence, isCanceled: true)
                case (false, let exception?) where exception.startsAt != nil || exception.endsAt != nil:
                    // A moved date keeps its move.
                    try await rest.setEventDateCanceled(false, exception, of: event.id, in: event.guildID)
                    stored = ScheduledEvent.Exception(
                        id: occurrence, startsAt: exception.startsAt, endsAt: exception.endsAt, isCanceled: false
                    )
                case (false, _):
                    try await rest.deleteEventException(occurrence, of: event.id, in: event.guildID)
                }
                applyEventException(eventID: event.id, stored, occurrence: occurrence)
            } catch {
                Self.trace("event \(event.id) date \(occurrence) failed: \(Self.describe(error))")
            }
        }
    }

    /// Puts an event the server sent into the store, replacing what was held.
    func storeScheduledEvent(_ event: ScheduledEvent) {
        var events = model.scheduledEvents[event.guildID] ?? []
        let wasActive = events.first { $0.id == event.id }?.status == .active
        events.removeAll { $0.id == event.id }
        events.append(event)
        model.scheduledEvents[event.guildID] = events
        // The inbox's Events group is drawn from these.
        model.inbox.revision &+= 1
        if !wasActive { noteEventWentLive(event) }
    }

    // MARK: The gateway

    /// Somebody's answer arrived. The reader's own is their answer, from
    /// another client; anybody's moves the counts held — Discord's store
    /// adjusts its counts the same way rather than asking again.
    func applyEventAnswer(_ rsvp: ScheduledEventRSVP, added: Bool) {
        if rsvp.userID == model.currentUserID {
            var answers = model.eventAnswers[rsvp.eventID] ?? EventAnswers()
            let value = added ? rsvp.response : nil
            if let date = rsvp.occurrence { answers.dates[date] = value } else { answers.series = value }
            if model.eventAnswers[rsvp.eventID] != answers { model.eventAnswers[rsvp.eventID] = answers }
        }
        guard var counts = model.eventCounts[rsvp.eventID] else { return }
        let step = added ? 1 : -1
        if let date = rsvp.occurrence {
            // A date's yes adds to that date; its "not this one" takes away.
            if counts.occurrences[date] != nil {
                counts.occurrences[date]! += rsvp.response == .interested ? step : -step
            }
        } else if rsvp.response == .interested {
            counts.series += step
            for date in counts.occurrences.keys { counts.occurrences[date]! += step }
        }
        model.eventCounts[rsvp.eventID] = counts
    }

    /// A date of a series moved, was cancelled or restored.
    func applyEventException(eventID: UInt64, _ exception: ScheduledEvent.Exception?, occurrence: UInt64?) {
        for (guildID, events) in model.scheduledEvents {
            guard let index = events.firstIndex(where: { $0.id == eventID }) else { continue }
            var event = events[index]
            if let exception {
                event.exceptions.removeAll { $0.id == exception.id }
                event.exceptions.append(exception)
            } else if let occurrence {
                event.exceptions.removeAll { $0.id == occurrence }
            } else {
                event.exceptions = []
            }
            model.scheduledEvents[guildID]?[index] = event
            return
        }
    }
}
