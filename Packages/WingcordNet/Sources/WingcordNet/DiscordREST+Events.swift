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

    /// Which of a guild's events the reader has said they are interested in.
    ///
    /// A separate route because the event object does not carry it — the
    /// captured answer is a bare list of `{response, user_id, event_id}` and
    /// `response: 1` is the whole of "interested".
    public func interestedEventIDs(in guildID: GuildID) async throws -> Set<UInt64> {
        struct Entry: Decodable, Sendable {
            var response: Int?
            // A snowflake, so a string on the wire. Typed `UInt64` it accepted
            // only the form Discord does not send, and threw the whole list
            // away — see `StageInstanceDTO`, where the same mistake took READY
            // down.
            var guild_scheduled_event_id: ScheduledEventID?
        }
        let entries = try await get(
            "/users/@me/scheduled-events",
            route: "users/@me/scheduled-events",
            query: [URLQueryItem(name: "guild_ids", value: String(guildID.rawValue))],
            as: [Entry].self
        )
        return Set(
            entries.compactMap { $0.response == 1 ? $0.guild_scheduled_event_id?.rawValue : nil }
        )
    }

    /// How many people are interested, per event.
    ///
    /// **A 400 is the "no such event" answer here**, not a 404: asking about id
    /// `-1` answered `50035 Invalid Form Body`. A caller that only catches
    /// `notFound` reports a transport failure for a stale id.
    public func interestedCount(for eventID: UInt64, in guildID: GuildID) async throws -> Int {
        struct Counts: Decodable, Sendable { var guild_scheduled_event_count: Int? }
        return try await get(
            "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/users/counts",
            route: "guilds/{id}/scheduled-events/{id}/users/counts",
            as: Counts.self
        ).guild_scheduled_event_count ?? 0
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
        struct Body: Encodable { var status = 4 }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{id}",
            body: Body(),
            as: ScheduledEventDTO.self
        ).domain(fallbackGuildID: guildID)
    }

    public func deleteEvent(_ eventID: UInt64, in guildID: GuildID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)",
            route: "guilds/{id}/scheduled-events/{id}",
            body: Optional<Never>.none
        )
    }

    /// Says the reader is, or is no longer, interested.
    public func setEventInterest(
        _ eventID: UInt64,
        in guildID: GuildID,
        isInterested: Bool
    ) async throws {
        _ = try await requestData(
            method: isInterested ? "PUT" : "DELETE",
            path: "/guilds/\(guildID.rawValue)/scheduled-events/\(eventID)/users/@me",
            route: "guilds/{id}/scheduled-events/{id}/users/@me",
            body: Optional<Never>.none
        )
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

    struct MetadataDTO: Decodable, Sendable {
        var location: String?
    }

    struct RecurrenceDTO: Decodable, Sendable {
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
            interestedCount: user_count
        )
    }
}
