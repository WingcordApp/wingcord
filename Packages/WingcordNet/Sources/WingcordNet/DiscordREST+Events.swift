import Foundation
import WingcordCore

// MARK: - Scheduled events
//
// The create is captured in full. Two things about it are worth stating here
// because neither is guessable and both are expensive to get wrong:
//
//   1. **The cover goes in the JSON body as a `data:` URI**, exactly as an
//      emoji does and unlike a sticker, which is multipart. The captured
//      request was 3.3 MB.
//   2. **`channel_id` is sent as an explicit null** for an external event,
//      beside a populated `entity_metadata.location`. Omitting the key is not
//      the same as sending null on this route.

extension DiscordREST {

    /// Every event in a guild.
    public func scheduledEvents(in guildID: GuildID) async throws -> [ScheduledEvent] {
        try await get(
            "/guilds/\(guildID.rawValue)/scheduled-events",
            route: "guilds/{id}/scheduled-events",
            query: [URLQueryItem(name: "with_user_count", value: "true")],
            as: [ScheduledEventDTO].self
        ).compactMap { $0.domain(fallbackGuildID: guildID) }
    }

    /// One event — Discord's `fetchGuildEvent`, which its event card sends
    /// for a linked event its store does not hold: `GET
    /// /guilds/{id}/scheduled-events/{event}`, with no query.
    public func scheduledEvent(_ eventID: UInt64, in guildID: GuildID) async throws -> ScheduledEvent {
        let dto = try await get(
            "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{event}",
            as: ScheduledEventDTO.self
        )
        guard let event = dto.domain(fallbackGuildID: guildID) else { throw Failure.notFound }
        return event
    }

    /// The reader's answers to a guild's events — to whole series and to
    /// single dates.
    ///
    /// A separate route because the event object does not carry it. The
    /// answer is a bare list of the same objects the interest PUT answers with
    /// (`scheduled event.har`), a date's carrying its exception id.
    public func scheduledEventRSVPs(in guildID: GuildID) async throws -> [ScheduledEventRSVP] {
        try await get(
            "/users/@me/scheduled-events",
            route: "users/@me/scheduled-events",
            query: [URLQueryItem(name: "guild_ids", value: String(guildID.rawValue))],
            as: [ScheduledEventRSVPDTO].self
        ).compactMap(\.domain)
    }

    /// The events whose WHOLE series the reader said they are interested in.
    ///
    /// **A single date is not the series.** This used to read any entry with
    /// `response: 1` as interest in the event, so a reader who said yes to one
    /// date of a weekly series showed as interested in all of them.
    public func interestedEventIDs(in guildID: GuildID) async throws -> Set<UInt64> {
        Set(try await scheduledEventRSVPs(in: guildID).compactMap {
            $0.occurrence == nil && $0.response == .interested ? $0.eventID : nil
        })
    }

    /// How many people are interested, per event.
    ///
    /// **A 400 is the "no such event" answer here**, not a 404: asking about id
    /// `-1` answered `50035 Invalid Form Body`. A caller that only catches
    /// `notFound` reports a transport failure for a stale id.
    public func interestedCount(for eventID: UInt64, in guildID: GuildID) async throws -> Int {
        try await interestedCounts(for: eventID, in: guildID).series
    }

    /// The series' count and each asked-about date's, in one answer.
    ///
    /// **Repeated keys, not a list**: the capture asks
    /// `?guild_scheduled_event_exception_ids=A&guild_scheduled_event_exception_ids=B`,
    /// and the answer keys each date's count on its id as a string.
    public func interestedCounts(
        for eventID: UInt64,
        in guildID: GuildID,
        occurrences: [UInt64] = []
    ) async throws -> ScheduledEventCounts {
        try await get(
            "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/users/counts",
            route: "guilds/{id}/scheduled-events/{id}/users/counts",
            query: occurrences.map {
                URLQueryItem(name: "guild_scheduled_event_exception_ids", value: String($0))
            },
            as: ScheduledEventCountsDTO.self
        ).domain
    }

    /// The people interested in an event — in the series, or in one date of it
    /// (`…/{event}/{occurrence}/users`), which answers with the series' people
    /// and the date's own answers together. Discord asks for a hundred with
    /// their member records and does not page.
    public func interestedUsers(
        for eventID: UInt64,
        occurrence: UInt64?,
        in guildID: GuildID
    ) async throws -> [ScheduledEventInterest] {
        let date = occurrence.map { "/\($0)" } ?? ""
        return try await get(
            "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)\(date)/users",
            route: occurrence == nil
                ? "guilds/{id}/scheduled-events/{id}/users"
                : "guilds/{id}/scheduled-events/{id}/{id}/users",
            query: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "with_member", value: "true"),
            ],
            as: [ScheduledEventUserDTO].self
        ).compactMap(\.domain)
    }

    public func createEvent(
        in guildID: GuildID,
        name: String,
        description: String?,
        location: ScheduledEvent.Location,
        startsAt: Date,
        endsAt: Date?,
        recurrence: Recurrence?,
        cover: ImageData?
    ) async throws -> ScheduledEvent? {
        try await request(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/scheduled-events",
            route: "guilds/{id}/scheduled-events",
            body: EventBody(
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover,
                status: nil
            ),
            as: ScheduledEventDTO.self
        ).domain(fallbackGuildID: guildID)
    }

    /// Edits an event.
    ///
    /// Takes the whole event, like every other write on these surfaces — the
    /// create's body carries all nine fields and there is no capture of a
    /// partial edit, so sending the same nine is the shape with evidence behind
    /// it.
    public func updateEvent(
        _ eventID: UInt64,
        in guildID: GuildID,
        name: String,
        description: String?,
        location: ScheduledEvent.Location,
        startsAt: Date,
        endsAt: Date?,
        recurrence: Recurrence?,
        cover: ImageData? = nil
    ) async throws -> ScheduledEvent? {
        try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{id}",
            body: EventBody(
                name: name,
                description: description,
                location: location,
                startsAt: startsAt,
                endsAt: endsAt,
                recurrence: recurrence,
                cover: cover,
                status: nil
            ),
            as: ScheduledEventDTO.self
        ).domain(fallbackGuildID: guildID)
    }

    /// Cancels an event without deleting it — `status: 4`.
    ///
    /// Distinct from `deleteEvent` because they are different acts: cancelling
    /// leaves the event visible with a struck-through date so the people who
    /// said they were coming find out, and deleting removes it from everybody's
    /// list with no trace.
    public func cancelEvent(_ eventID: UInt64, in guildID: GuildID) async throws -> ScheduledEvent? {
        try await setEventStatus(.canceled, for: eventID, in: guildID)
    }

    /// Moves an event to a status by itself — Discord's `startEvent` (active)
    /// and `endEvent` (completed) in `496092`, which send `{"status": n}` and
    /// nothing else.
    public func setEventStatus(
        _ status: ScheduledEvent.Status,
        for eventID: UInt64,
        in guildID: GuildID
    ) async throws -> ScheduledEvent? {
        struct Body: Encodable { var status: Int }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{id}",
            body: Body(status: status.rawValue),
            as: ScheduledEventDTO.self
        ).domain(fallbackGuildID: guildID)
    }

    // MARK: One date of a series
    //
    // Discord's builders in `496092`, not captures: a date is cancelled by
    // creating an exception for it (`POST …/exceptions` with its original
    // start) or by marking the one it has (`PATCH …/exceptions/{date}`), and
    // restored by removing an exception that moved nothing, or unmarking one
    // that did.

    /// Cancels one date that has no exception yet.
    public func cancelEventDate(
        _ occurrence: UInt64,
        of eventID: UInt64,
        in guildID: GuildID
    ) async throws {
        struct Body: Encodable {
            var original_scheduled_start_time: String
            var is_canceled = true
        }
        let start = ScheduledEvent.originalStart(ofOccurrence: occurrence)
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/exceptions",
            route: "guilds/{id}/scheduled-events/{id}/exceptions",
            body: Body(original_scheduled_start_time: ISO8601DateFormatter.eventTimestamp.string(from: start))
        )
    }

    /// Marks a date's existing exception cancelled or not, keeping any move
    /// it carries.
    public func setEventDateCanceled(
        _ isCanceled: Bool,
        _ exception: ScheduledEvent.Exception,
        of eventID: UInt64,
        in guildID: GuildID
    ) async throws {
        struct Body: Encodable {
            var scheduled_start_time: String?
            var scheduled_end_time: String?
            var is_canceled: Bool

            // Discord's body names all three; a move that is not there is null.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(scheduled_start_time, forKey: .scheduled_start_time)
                try container.encode(scheduled_end_time, forKey: .scheduled_end_time)
                try container.encode(is_canceled, forKey: .is_canceled)
            }

            enum Keys: String, CodingKey { case scheduled_start_time, scheduled_end_time, is_canceled }
        }
        let stamp = ISO8601DateFormatter.eventTimestamp
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/exceptions/\(exception.id)",
            route: "guilds/{id}/scheduled-events/{id}/exceptions/{id}",
            body: Body(
                scheduled_start_time: exception.startsAt.map(stamp.string(from:)),
                scheduled_end_time: exception.endsAt.map(stamp.string(from:)),
                is_canceled: isCanceled
            )
        )
    }

    /// Removes a date's exception, which puts the date back as the rule has it.
    public func deleteEventException(
        _ occurrence: UInt64,
        of eventID: UInt64,
        in guildID: GuildID
    ) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/exceptions/\(occurrence)",
            route: "guilds/{id}/scheduled-events/{id}/exceptions/{id}",
            body: Optional<Never>.none
        )
    }

    public func deleteEvent(_ eventID: UInt64, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{id}",
            body: Optional<Never>.none
        )
    }

    /// Gives the reader's answer to a series or to one date of it, or takes
    /// it back with `nil`.
    ///
    /// **Captured both ways** (`scheduled event.har`): `PUT …/users/@me` and
    /// `PUT …/{occurrence}/users/@me` with `{"response":1}`, and `DELETE` of
    /// the same two paths. This used to PUT with no body at all. A date's
    /// `{"response":0}` — "not this one" inside a series the reader is
    /// interested in — is Discord's own builder (`496092`), not a capture.
    public func setEventRSVP(
        _ response: ScheduledEventRSVP.Response?,
        for eventID: UInt64,
        occurrence: UInt64?,
        in guildID: GuildID
    ) async throws {
        struct Body: Encodable { var response: Int }
        let date = occurrence.map { "/\($0)" } ?? ""
        let path = "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)\(date)/users/@me"
        let route = occurrence == nil
            ? "guilds/{id}/scheduled-events/{id}/users/@me"
            : "guilds/{id}/scheduled-events/{id}/{id}/users/@me"
        if let response {
            _ = try await requestData(method: "PUT", path: path, route: route, body: Body(response: response.rawValue))
        } else {
            _ = try await requestData(method: "DELETE", path: path, route: route, body: Optional<Never>.none)
        }
    }
}

// MARK: - The body
//
// Shared by create and edit, and the one place the location's three wire fields
// are derived from the one enum that models them.

private struct EventBody: Encodable {
    var name: String
    var description: String?
    var location: ScheduledEvent.Location
    var startsAt: Date
    var endsAt: Date?
    var recurrence: Recurrence?
    var cover: ImageData?
    var status: Int?

    private enum Keys: String, CodingKey {
        case name, description, image, privacy_level, scheduled_start_time
        case scheduled_end_time, entity_type, channel_id, entity_metadata
        case recurrence_rule, status
    }

    private struct Metadata: Encodable { var location: String }

    private struct RecurrenceBody: Encodable {
        var start: String
        var frequency: Int
        var interval: Int
        var by_weekday: [Int]?
        var by_n_weekday: [NWeekday]?
        var by_month: [Int]?
        var by_month_day: [Int]?

        struct NWeekday: Encodable {
            var n: Int
            var day: Int
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        if let cover { try container.encode(cover.dataURI, forKey: .image) }
        // Always 2 — GUILD_ONLY is the only value the field has ever taken.
        try container.encode(2, forKey: .privacy_level)
        try container.encode(Self.timestamp(startsAt), forKey: .scheduled_start_time)
        try container.encode(endsAt.map(Self.timestamp), forKey: .scheduled_end_time)
        try container.encode(location.entityType, forKey: .entity_type)
        // **Explicitly null**, not omitted. The captured external event sends
        // the key with a null value beside a populated `entity_metadata`.
        try container.encode(location.channelID.map { String($0.rawValue) }, forKey: .channel_id)
        if let place = location.externalLocation {
            try container.encode(Metadata(location: place), forKey: .entity_metadata)
        } else {
            try container.encodeNil(forKey: .entity_metadata)
        }

        if let recurrence, recurrence != .unrecognised {
            try container.encode(
                RecurrenceBody(
                    // The rule's own start is the event's start. Discord
                    // rejects a rule that begins before the event it governs.
                    start: Self.timestamp(startsAt),
                    frequency: recurrence.frequency,
                    interval: recurrence.interval,
                    by_weekday: recurrence.byWeekday,
                    by_n_weekday: recurrence.byNWeekday?.map {
                        RecurrenceBody.NWeekday(n: $0.n, day: $0.day)
                    },
                    by_month: recurrence.byMonth,
                    by_month_day: recurrence.byMonthDay
                ),
                forKey: .recurrence_rule
            )
        } else {
            try container.encodeNil(forKey: .recurrence_rule)
        }

        try container.encodeIfPresent(status, forKey: .status)
    }

    /// The exact form the capture sends: ISO-8601 in UTC with milliseconds and
    /// a `Z`. The response comes back as `+00:00` instead, which the shared
    /// decoder already handles — but the *request* is written by hand here
    /// rather than by `JSONEncoder`'s date strategy, because that strategy is
    /// configured per encoder and this client builds one per request.
    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.eventTimestamp.string(from: date)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let eventTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// MARK: - Wire

struct ScheduledEventDTO: Decodable, Sendable {
    var id: WireID?
    var guild_id: GuildID?
    var name: String?
    var description: String?
    var creator_id: UserID?
    var image: String?
    var scheduled_start_time: Date?
    var scheduled_end_time: Date?
    var status: Int?
    var entity_type: Int?
    var channel_id: ChannelID?
    var entity_metadata: MetadataDTO?
    var recurrence_rule: RecurrenceDTO?
    var user_count: Int?
    /// The dates an organiser moved or cancelled. Lossy, so one malformed
    /// entry costs that entry rather than the event.
    var guild_scheduled_event_exceptions: LossyList<ScheduledEventExceptionDTO>?
    var creator: UserDTO?

    struct MetadataDTO: Decodable, Sendable {
        var location: String?
    }

    struct RecurrenceDTO: Decodable, Sendable {
        var start: Date?
        var end: Date?
        var count: Int?
        var frequency: Int?
        var interval: Int?
        var by_weekday: [Int]?
        var by_n_weekday: [NWeekdayDTO]?
        var by_month: [Int]?
        var by_month_day: [Int]?

        struct NWeekdayDTO: Decodable, Sendable {
            var n: Int?
            var day: Int?
        }

        var domain: Recurrence? {
            Recurrence(
                frequency: frequency ?? -1,
                interval: interval ?? 1,
                byWeekday: by_weekday,
                byNWeekday: by_n_weekday?.compactMap { entry in
                    guard let n = entry.n, let day = entry.day else { return nil }
                    return (n, day)
                },
                byMonth: by_month,
                byMonthDay: by_month_day
            )
        }

        /// The rule whole, for the series' dates — nil without a start or a
        /// frequency this client knows, which leaves the event a single date
        /// rather than a guessed series.
        func rule(fallbackStart: Date) -> RecurrenceRule? {
            guard let frequency = frequency.flatMap(RecurrenceRule.Frequency.init(rawValue:)) else {
                return nil
            }
            return RecurrenceRule(
                start: start ?? fallbackStart,
                end: end,
                frequency: frequency,
                interval: interval ?? 1,
                byWeekday: by_weekday,
                byNWeekday: by_n_weekday?.compactMap { entry in
                    guard let n = entry.n, let day = entry.day else { return nil }
                    return RecurrenceRule.NWeekday(n: n, day: day)
                },
                byMonth: by_month,
                byMonthDay: by_month_day,
                count: count
            )
        }
    }

    func domain(fallbackGuildID: GuildID) -> ScheduledEvent? {
        // No id or no start is not an event; there is nothing to draw and
        // nothing to act on.
        guard let id = id?.value, let start = scheduled_start_time else { return nil }
        return ScheduledEvent(
            id: id,
            guildID: guild_id ?? fallbackGuildID,
            name: name ?? "",
            description: description.nonEmpty,
            creatorID: creator_id,
            imageHash: image,
            startsAt: start,
            endsAt: scheduled_end_time,
            status: ScheduledEvent.Status(rawValue: status ?? 1),
            location: ScheduledEvent.Location(
                entityType: entity_type ?? 0,
                channelID: channel_id,
                location: entity_metadata?.location
            ),
            recurrence: recurrence_rule?.domain,
            rule: recurrence_rule?.rule(fallbackStart: start),
            exceptions: (guild_scheduled_event_exceptions?.elements ?? []).compactMap(\.domain),
            creator: creator?.domain,
            interestedCount: user_count
        )
    }
}

/// One moved or cancelled date — an element of the event's
/// `guild_scheduled_event_exceptions`, and the payload of the gateway's
/// `GUILD_SCHEDULED_EVENT_EXCEPTION_*`.
struct ScheduledEventExceptionDTO: Decodable, Sendable {
    var event_exception_id: WireID?
    var event_id: WireID?
    var guild_id: GuildID?
    var scheduled_start_time: Date?
    var scheduled_end_time: Date?
    var is_canceled: Bool?

    var domain: ScheduledEvent.Exception? {
        guard let id = event_exception_id?.value else { return nil }
        return ScheduledEvent.Exception(
            id: id,
            startsAt: scheduled_start_time,
            endsAt: scheduled_end_time,
            isCanceled: is_canceled ?? false
        )
    }
}

/// One answer — the user route's element, the PUT's reply, and the gateway's
/// `GUILD_SCHEDULED_EVENT_USER_ADD` and `_REMOVE`.
struct ScheduledEventRSVPDTO: Decodable, Sendable {
    var guild_scheduled_event_id: WireID?
    var guild_scheduled_event_exception_id: WireID?
    var user_id: UserID?
    var guild_id: GuildID?
    var response: Int?

    var domain: ScheduledEventRSVP? {
        guard let eventID = guild_scheduled_event_id?.value, let user_id else { return nil }
        return ScheduledEventRSVP(
            eventID: eventID,
            occurrence: guild_scheduled_event_exception_id?.value,
            userID: user_id,
            // An absent response is the series' yes: the gateway's add for a
            // series has been seen without one.
            response: ScheduledEventRSVP.Response(rawValue: response ?? 1) ?? .interested
        )
    }
}

/// An interested person, with their user and member records.
struct ScheduledEventUserDTO: Decodable, Sendable {
    var guild_scheduled_event_id: WireID?
    var guild_scheduled_event_exception_id: WireID?
    var user_id: UserID?
    var user: UserDTO?
    var member: MemberDTO?
    var response: Int?

    var domain: ScheduledEventInterest? {
        guard let eventID = guild_scheduled_event_id?.value, let user else { return nil }
        let userID = user_id ?? user.id
        return ScheduledEventInterest(
            rsvp: ScheduledEventRSVP(
                eventID: eventID,
                occurrence: guild_scheduled_event_exception_id?.value,
                userID: userID,
                response: ScheduledEventRSVP.Response(rawValue: response ?? 1) ?? .interested
            ),
            user: user.domain,
            member: member?.domain(userID: userID)
        )
    }
}

struct ScheduledEventCountsDTO: Decodable, Sendable {
    var guild_scheduled_event_count: Int?
    var guild_scheduled_event_exception_counts: [String: Int]?

    var domain: ScheduledEventCounts {
        var occurrences: [UInt64: Int] = [:]
        for (key, count) in guild_scheduled_event_exception_counts ?? [:] {
            if let id = UInt64(key) { occurrences[id] = count }
        }
        return ScheduledEventCounts(series: guild_scheduled_event_count ?? 0, occurrences: occurrences)
    }
}
