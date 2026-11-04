import Foundation

// MARK: - Messaging permissions
//
// What the account lets other people send it, and what it does with flagged
// media when they do.
//
// **Every number in here is Discord's own, read out of the compiled descriptor
// in its app bundle on 2026-09-22 and pinned a second time by
// `messaging permissions.har`** — eighteen `PATCH /users/@me/settings-proto/1`
// bodies with one control moved at a time. The method is the one
// `ActivityPrivacyProto` documents, and it matters for the same reason: a
// protobuf read with the wrong numbering does not fail, it yields plausible
// nonsense.

/// What Discord does with a picture its own filters flagged.
///
/// `discord_protos.discord_users.v1.ExplicitContentRedaction`, verbatim.
public enum ContentRedaction: UInt64, Hashable, Sendable, CaseIterable, Identifiable {
    /// The account has never answered. Discord's own client treats this as
    /// `.blur` for direct messages and `.show` in servers; it is kept as its own
    /// case rather than folded, because **writing a default back is a change**
    /// — §1's rule about a bitfield carrying bits this client cannot draw,
    /// arriving from the other side.
    case unset = 0
    case show = 1
    case blur = 2
    case block = 3

    public var id: Self { self }

    public var title: String {
        switch self {
        case .unset, .show: "Show"
        case .blur: "Blur"
        case .block: "Block"
        }
    }

    public var symbolName: String {
        switch self {
        case .unset, .show: "eye"
        case .blur: "photo.badge.exclamationmark"
        case .block: "nosign"
        }
    }
}

/// Which kind of flagged media a filter is about.
///
/// Three separate messages on the wire rather than one with a category field —
/// `explicit_content_settings` (29), `gore_content_settings` (32) and
/// `self_harm_content_settings` (35) — each with the same three fields inside.
public enum ContentFilterCategory: String, Hashable, Sendable, CaseIterable, Identifiable {
    case explicit
    case gore
    case selfHarm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explicit: "Mature Sexual Media"
        case .gore: "Graphic Media"
        case .selfHarm: "Self-harm Content"
        }
    }

    public var summary: String {
        switch self {
        case .explicit:
            "Image-based media that may contain sexually explicit or suggestive material."
        case .gore:
            "Image-based media that may contain graphic violence or gore."
        case .selfHarm:
            "Image-based media that may depict self-harm."
        }
    }
}

/// Where a filter applies.
public enum ContentFilterSurface: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// `*_content_guilds` — field 1 inside each category's message, and **not**
    /// the last one, however naturally the page reads top to bottom. That
    /// ordering trap is the whole reason this enum exists rather than three
    /// bare integers.
    case serverChannels
    /// `*_content_friend_dm` — field 2.
    case friendDirectMessages
    /// `*_content_non_friend_dm` — field 3.
    case otherDirectMessages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .friendDirectMessages: "Direct messages from friends"
        case .otherDirectMessages: "Direct messages from others"
        case .serverChannels: "Messages in server channels"
        }
    }

    /// What may be chosen here.
    ///
    /// **A server channel cannot be blocked, only blurred**, and that is a rule
    /// about the *surface* rather than about the category. It is sourced to two
    /// things and neither is a guess: Alex reported it from the running client,
    /// and across eighteen captured PATCHes the guild field never left `SHOW`
    /// while both direct-message fields were driven through all three values.
    /// The panel's own chunk is lazily loaded and is not in the entry bundle, so
    /// it could not be read out of the descriptor the way the numbers were.
    public var options: [ContentRedaction] {
        switch self {
        case .serverChannels: [.show, .blur]
        case .friendDirectMessages, .otherDirectMessages: [.show, .blur, .block]
        }
    }
}

/// One category's three answers.
public struct ContentFilter: Hashable, Sendable {
    public var serverChannels: ContentRedaction
    public var friendDirectMessages: ContentRedaction
    public var otherDirectMessages: ContentRedaction

    public init(
        serverChannels: ContentRedaction = .unset,
        friendDirectMessages: ContentRedaction = .unset,
        otherDirectMessages: ContentRedaction = .unset
    ) {
        self.serverChannels = serverChannels
        self.friendDirectMessages = friendDirectMessages
        self.otherDirectMessages = otherDirectMessages
    }

    public subscript(surface: ContentFilterSurface) -> ContentRedaction {
        get {
            switch surface {
            case .serverChannels: serverChannels
            case .friendDirectMessages: friendDirectMessages
            case .otherDirectMessages: otherDirectMessages
            }
        }
        set {
            switch surface {
            case .serverChannels: serverChannels = newValue
            case .friendDirectMessages: friendDirectMessages = newValue
            case .otherDirectMessages: otherDirectMessages = newValue
            }
        }
    }
}

/// How much of the spam Discord holds back.
///
/// `discord_protos.discord_users.v1.DmSpamFilterV2`, verbatim. The names are
/// Discord's and they describe **whose** messages are filtered, which is why
/// `.everyone` is the strictest rather than the loosest.
public enum DMSpamFilter: UInt64, Hashable, Sendable, CaseIterable, Identifiable {
    case unset = 0
    /// `DISABLED` — "Don't filter spam".
    case off = 1
    /// `NON_FRIENDS` — Discord's own recommendation.
    case nonFriends = 2
    /// `FRIENDS_AND_NON_FRIENDS` — "Filter all spam".
    case everyone = 3

    public var id: Self { self }

    /// The three the page offers. `.unset` is a state, not a choice.
    public static let choices: [Self] = [.everyone, .nonFriends, .off]

    public var title: String {
        switch self {
        case .everyone: "Filter all spam"
        case .unset, .nonFriends: "Filter messages from non-friends"
        case .off: "Don't filter spam"
        }
    }

    public var detail: String? {
        switch self {
        case .unset, .nonFriends: "Recommended"
        default: nil
        }
    }
}

/// Who may send a friend request.
///
/// **A bitmask, and the bits are not 1, 2, 4.** Read out of the bundle:
/// `MUTUAL_FRIENDS = 2`, `MUTUAL_GUILDS = 4`, `NO_RELATION = 8`, and the client's
/// own "everything" constant is `14`. A client that assumed the low bit was in
/// use would turn on a source nobody asked for.
public struct FriendSourceFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// "Friend of friends".
    public static let mutualFriends = Self(rawValue: 2)
    /// "Server members".
    public static let mutualGuilds = Self(rawValue: 4)
    /// "Everyone" — Discord calls it `NO_RELATION`, because it is the bit that
    /// admits somebody you share nothing with.
    public static let everyone = Self(rawValue: 8)

    public static let all: Self = [.mutualFriends, .mutualGuilds, .everyone]

    /// The three switches, in the order the page shows them: widest first.
    public static let sources: [(flag: Self, title: String, detail: String?)] = [
        (.everyone, "Everyone", nil),
        (.mutualFriends, "Friend of friends", nil),
        (
            .mutualGuilds,
            "Server members",
            "Server members can only send you friend requests from servers where "
                + "you also allow direct messages."
        ),
    ]
}

/// Everything the Messaging Permissions page reads and writes.
///
/// One value rather than a field per control: every one of these comes out of
/// the same two protobuf messages in the same blob, and a page that fetched them
/// separately would be four round trips and four chances to disagree.
public struct MessagingPrivacy: Hashable, Sendable {
    public var explicit: ContentFilter
    public var gore: ContentFilter
    public var selfHarm: ContentFilter
    /// "Allow access to age-restricted commands from apps in DMs".
    public var allowsAgeRestrictedCommands: Bool
    /// "Allow access to age-restricted servers on iOS".
    public var allowsAgeRestrictedGuilds: Bool
    public var spamFilter: DMSpamFilter
    /// The default for a server the reader has not touched — Discord's
    /// `default_guilds_restricted_v2`, and **inverted on the wire**: the field
    /// is a restriction, so `true` there means direct messages are OFF.
    public var allowsDirectMessagesByDefault: Bool
    /// `default_message_request_restricted`, inverted for the same reason.
    public var filtersMessageRequestsByDefault: Bool
    public var friendSources: FriendSourceFlags
    /// "Show personalized messages" — `hide_friend_request_notes`, inverted.
    public var showsFriendRequestNotes: Bool
    /// Whether the account has ever said. **Unset isn't "on"**: Discord falls back
    /// to hiding them from an account not cleared for age-restricted content
    /// (`420825`, `840387`), so an absent field isn't the same answer as a
    /// present one. See `resolvedShowsFriendRequestNotes(isNSFWAllowed:)`.
    public var hasFriendRequestNotesSetting = false
    /// "Messaging in Connected Games".
    public var allowsGameFriendDirectMessages: Bool

    /// Discord's `s()` (`420825`): what the account said, else hidden only for an
    /// account known not to be cleared for age-restricted content.
    public func resolvedShowsFriendRequestNotes(isNSFWAllowed: Bool?) -> Bool {
        hasFriendRequestNotesSetting ? showsFriendRequestNotes : isNSFWAllowed != false
    }

    public init(
        explicit: ContentFilter = ContentFilter(),
        gore: ContentFilter = ContentFilter(),
        selfHarm: ContentFilter = ContentFilter(),
        allowsAgeRestrictedCommands: Bool = false,
        allowsAgeRestrictedGuilds: Bool = false,
        spamFilter: DMSpamFilter = .unset,
        allowsDirectMessagesByDefault: Bool = true,
        filtersMessageRequestsByDefault: Bool = true,
        friendSources: FriendSourceFlags = .all,
        showsFriendRequestNotes: Bool = true,
        allowsGameFriendDirectMessages: Bool = true
    ) {
        self.explicit = explicit
        self.gore = gore
        self.selfHarm = selfHarm
        self.allowsAgeRestrictedCommands = allowsAgeRestrictedCommands
        self.allowsAgeRestrictedGuilds = allowsAgeRestrictedGuilds
        self.spamFilter = spamFilter
        self.allowsDirectMessagesByDefault = allowsDirectMessagesByDefault
        self.filtersMessageRequestsByDefault = filtersMessageRequestsByDefault
        self.friendSources = friendSources
        self.showsFriendRequestNotes = showsFriendRequestNotes
        self.allowsGameFriendDirectMessages = allowsGameFriendDirectMessages
    }

    public subscript(category: ContentFilterCategory) -> ContentFilter {
        get {
            switch category {
            case .explicit: explicit
            case .gore: gore
            case .selfHarm: selfHarm
            }
        }
        set {
            switch category {
            case .explicit: explicit = newValue
            case .gore: gore = newValue
            case .selfHarm: selfHarm = newValue
            }
        }
    }
}
