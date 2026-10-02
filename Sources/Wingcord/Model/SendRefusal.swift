import Foundation
import WingcordNet

/// What a refused send owes the reader, decided as Discord's client decides it.
///
/// **Ported from `_sendMessage`'s failure branch (module `148494`), not
/// inferred from what a refusal looks like.** Every refusal turns the message
/// red; past that there are exactly three answers:
///
/// - a dropped connection, a server error, and AutoMod — which explains itself
///   in a notice of its own — say nothing more;
/// - slowmode sets the channel's wait;
/// - **every other refusal with a body gets Clyde**: the explanation in
///   `sendClydeError`'s table where the code has one, and its default sentence
///   where it does not — including a code nobody has seen yet.
enum SendRefusal: Equatable, Sendable {
    case silent
    case slowmode(retryAfter: TimeInterval?)
    case explained(String)

    /// What the reader is told about one refusal.
    ///
    /// - Parameters:
    ///   - isBotDirectMessage: a one-to-one conversation with an app, which
    ///     Discord answers differently when there is no server in common.
    ///   - isForumLike: a forum or media channel, or a post in one — its thread
    ///     cap is worded as posts.
    ///   - isPrivate: a direct or group message, where explicit media is
    ///     refused for "this conversation" rather than "this server".
    static func of(
        _ error: Error,
        isBotDirectMessage: Bool = false,
        isForumLike: Bool = false,
        isPrivate: Bool = false
    ) -> SendRefusal {
        switch error {
        case DiscordREST.Failure.slowmode(let retryAfter):
            return .slowmode(retryAfter: retryAfter)
        case DiscordREST.Failure.api(let status, let code, _) where (400..<500).contains(status):
            return explaining(code, isBotDirectMessage: isBotDirectMessage, isForumLike: isForumLike, isPrivate: isPrivate)
        case DiscordREST.Failure.forbidden(let code):
            return explaining(code, isBotDirectMessage: isBotDirectMessage, isForumLike: isForumLike, isPrivate: isPrivate)
        case DiscordREST.Failure.notFound:
            return explaining(nil, isBotDirectMessage: isBotDirectMessage, isForumLike: isForumLike, isPrivate: isPrivate)
        default:
            return .silent
        }
    }

    private static func explaining(
        _ code: Int?,
        isBotDirectMessage: Bool,
        isForumLike: Bool,
        isPrivate: Bool
    ) -> SendRefusal {
        switch code {
        // AutoMod's three: Discord raises its own notice for these, which this
        // client does not draw yet — and Clyde is not it.
        case 200_000, 200_001, 200_002: return .silent
        // POGGERMODE_TEMPORARILY_DISABLED.
        case 170_008: return .silent
        case 20016: return .slowmode(retryAfter: nil)
        // EXPLICIT_CONTENT: `sendExplicitMediaClydeError`, not the table.
        case 20009:
            return .explained(isPrivate
                ? "Your message could not be sent. Discord detected that it may contain sensitive content, which is not allowed in this conversation."
                : "Your message could not be sent. Discord detected that it may contain sensitive content, which is not allowed in this server.")
        case 50278 where !isBotDirectMessage:
            return .explained("""
                Your message could not be delivered. Send a friend request first and start the conversation once they've accepted.

                Here is the full list of reasons why your message could not be delivered: \(Self.undeliverableArticle)
                """)
        case 160_006:
            return .explained(isForumLike
                ? "Your message could not be sent because this server has reached the maximum number of posts. Free up space by archiving a post."
                : "Your message could not be sent because this server has reached the maximum number of threads. Free up space by archiving a thread.")
        case 160_007:
            return .explained("Your message could not be sent because this server has reached the maximum number of announcement threads. Free up space by archiving a thread.")
        case 240_000:
            return .explained("Your message could not be delivered because this message contains a link blocked by Discord. You can learn more here: https://dis.gd/phish.")
        case 240_001:
            return .explained("Your message could not be delivered because this message contains a link blocked by Discord.")
        case 40002:
            return .explained("You need to verify your email or phone before you can send messages here.")
        case 400_005:
            return .explained("Server is too busy, please try again later.")
        case 40003:
            return .explained("You are sending too many new direct messages. Hold off for a few minutes before trying to message this person again.")
        case 40004:
            return .explained("Sending messages to this channel has been temporarily disabled. Try again in a bit.")
        case 50251:
            return .explained("This user does not allow messages from Game Friends in Discord, try sending them a message in-game instead!")
        case 50252:
            return .explained("This user cannot receive messages while offline.")
        case 30053:
            return .explained("Your attachment(s) are too large. Maximum total size is 500 MB.")
        case 50146:
            return .explained("We couldn't find your file upload. Try removing the attachment and adding it again.")
        case 50013:
            return .explained("You don't have permission to do that here.")
        // INVALID_MESSAGE_SEND_USER, a bot with no server in common, and every
        // code the table does not name.
        default:
            return .explained("""
                Your message could not be delivered.

                You can see the full list of reasons here: \(Self.undeliverableArticle)
                """)
        }
    }

    /// `DM_COULD_NOT_BE_DELIVERED`, the article both of Discord's undelivered
    /// sentences end on.
    static let undeliverableArticle = "https://support.discord.com/hc/en-us/articles/360060145013"
}
