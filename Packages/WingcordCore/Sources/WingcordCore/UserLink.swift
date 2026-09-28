import Foundation

/// A link to somebody's profile, as a message carries it —
/// `discord.com/users/<id>`, which Discord draws as a profile card.
///
/// **Discord's own rule** (module `721779`): a whole path of `/users/<id>` on
/// one of its hosts — `discord.com`, `discordapp.com`, `ptb.` and `canary.` —
/// and at most ten code links a message. A path that goes on past the id is a
/// different page and gets no card.
public enum UserLink {

    /// The people a message's text links to, in order and each once.
    public static func userIDs(in content: String) -> [UserID] {
        guard content.contains("/users/") else { return [] }
        var seen = Set<UInt64>()
        var ids: [UserID] = []
        for match in content.matches(of: pattern) {
            guard let raw = UInt64(match.1), seen.insert(raw).inserted else { continue }
            ids.append(UserID(rawValue: raw))
            if ids.count == 10 { break }
        }
        return ids
    }

    /// The person a link points at, when the whole link is a profile link —
    /// the test for an embed Discord unfurled for one, which the card replaces.
    public static func userID(inURL url: String) -> UserID? {
        guard let match = url.wholeMatch(of: pattern), let raw = UInt64(match.1) else { return nil }
        return UserID(rawValue: raw)
    }

    nonisolated(unsafe) private static let pattern =
        /(?i)(?:https?:\/\/)?(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com\/users\/([0-9]{15,21})\/?(?=$|[\s<>)\]"'?#])/
}
