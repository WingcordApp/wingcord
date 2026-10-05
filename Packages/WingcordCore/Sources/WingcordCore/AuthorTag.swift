import Foundation

/// The tag beside an author's name in the transcript — Discord's (`812299`'s
/// rule over `709066`'s badge).
///
/// **Decided per message, not per person**: one webhook user publishes every
/// crosspost of a followed channel, and the same person is OP in their own
/// post and nobody in particular anywhere else.
public enum AuthorTag: Hashable, Sendable {
    /// Discord's own: a system message in a direct message, or a crosspost
    /// from Discord's own server. Always carries the check.
    case official
    /// A crosspost from a followed announcement channel.
    case server
    /// An app — the check where Discord verified it.
    case app(verified: Bool)
    /// The person who opened the forum post being read.
    case originalPoster

    /// Discord's own server, whose announcements are OFFICIAL rather than
    /// SERVER (`124759`'s `Vi`).
    public static let discordGuildID = GuildID(rawValue: 667_560_445_975_986_187)
    /// The account Discord's own announcements are published by (`hs`).
    public static let discordAnnouncementsUserID = UserID(rawValue: 669_627_189_624_307_712)

    /// Discord's order of questions: a system message, then a crosspost, then
    /// an app, then the post's own author — never in a quoted reply.
    ///
    /// - Parameters:
    ///   - isSystem: the author is Discord's system account.
    ///   - postOwnerID: the forum post being read's author, when it is one.
    public static func resolve(
        message: Message,
        isSystem: Bool,
        isBot: Bool,
        isVerifiedBot: Bool,
        postOwnerID: UserID?
    ) -> AuthorTag? {
        if isSystem { return .official }
        if message.isCrosspost {
            return isOfficialCrosspost(message) ? .official : .server
        }
        if isBot { return .app(verified: isVerifiedBot) }
        if let postOwnerID, message.authorID == postOwnerID { return .originalPoster }
        return nil
    }

    /// Discord's `455207.MZ`: a crosspost out of Discord's own server, or by
    /// its announcements account.
    public static func isOfficialCrosspost(_ message: Message) -> Bool {
        message.reference?.guildID == discordGuildID || message.authorID == discordAnnouncementsUserID
    }

    /// The chip's words — Discord's, with its check where it draws one.
    public var label: String {
        switch self {
        case .official: "✓ OFFICIAL"
        case .server: "SERVER"
        case .app(let verified): verified ? "✓ APP" : "APP"
        case .originalPoster: "OP"
        }
    }

    /// What the chip says on hover and to VoiceOver — Discord's
    /// "Official Discord Message", "Verified App", "Original Poster".
    public var spokenLabel: String {
        switch self {
        case .official: "Official Discord Message"
        case .server: "Server"
        case .app(let verified): verified ? "Verified App" : "App"
        case .originalPoster: "Original Poster"
        }
    }
}
