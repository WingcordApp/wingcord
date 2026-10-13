import Foundation

/// A link to a server's event — `https://discord.com/events/{guild}/{event}`,
/// with the date on the end for one date of a series. Discord's
/// `GUILD_EVENT_DETAILS` route, which is what its Copy Event Link writes.
///
/// Parsed on `ChannelLink`'s terms: Discord's own hosts and nothing that
/// merely looks like one.
public struct EventLink: Hashable, Sendable {
    public var guildID: GuildID
    public var eventID: UInt64
    /// One date of a series, or nil for the event as a whole.
    public var occurrence: UInt64?

    public init(guildID: GuildID, eventID: UInt64, occurrence: UInt64? = nil) {
        self.guildID = guildID
        self.eventID = eventID
        self.occurrence = occurrence
    }

    public static func parse(_ url: String) -> EventLink? {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ChannelLink.hosts.contains(host)
        else { return nil }
        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
        if segments.last?.isEmpty == true { segments = segments.dropLast() }
        let parts = Array(segments)
        guard (3...4).contains(parts.count), parts[0] == "events",
              let guild = UInt64(parts[1]), let event = UInt64(parts[2])
        else { return nil }
        var occurrence: UInt64?
        if parts.count == 4 {
            guard let date = UInt64(parts[3]) else { return nil }
            occurrence = date
        }
        return EventLink(guildID: GuildID(rawValue: guild), eventID: event, occurrence: occurrence)
    }

    /// The events a message's text links to, in order and each once — what
    /// Discord draws its event card under a message for (`721779`'s `EVENT`
    /// code, `guild-event[-date]`), at most ten a message, as every code link.
    ///
    /// **Discord's own hosts only.** Discord's rule takes any address whose
    /// path starts `/events/`; a card under a stranger's site would be a card
    /// for an event nobody linked.
    public static func links(in content: String) -> [EventLink] {
        guard content.contains("/events/") else { return [] }
        var links: [EventLink] = []
        for match in content.matches(of: pattern) {
            guard let guild = UInt64(match.1), let event = UInt64(match.2) else { continue }
            let link = EventLink(
                guildID: GuildID(rawValue: guild),
                eventID: event,
                occurrence: match.3.flatMap { UInt64($0) }
            )
            guard !links.contains(link) else { continue }
            links.append(link)
            if links.count == 10 { break }
        }
        return links
    }

    nonisolated(unsafe) private static let pattern =
        /(?i)(?:https?:\/\/)?(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com\/events\/([0-9]{15,21})\/([0-9]{15,21})(?:\/([0-9]{15,21}))?\/?(?=$|[\s<>)\]"'?#])/
}
