import Foundation

// MARK: - The account's own notification preferences
//
// **These follow the account, not the Mac.** `AppSettings` holds what *this*
// client does with a notification — whether it posts a banner, whether it plays
// a sound — and those are properties of a machine. Everything here is a fact
// Discord keeps and every client honours, so a reader who turns friend
// anniversaries off on their phone finds them off here.
//
// **Every switch defaults ON except quiet mode**, and that is not a guess: each
// one is read in Discord's own bundle as `e?.value ?? true`, one accessor per
// field. An absent `BoolValue` here therefore means *on* — the opposite of what
// the same absence means for the age-restricted switches in `MessagingPrivacy`,
// which is exactly the kind of thing that cannot be assumed once and reused.

/// When Discord notifies about somebody reacting.
///
/// `discord_protos.discord_users.v1.ReactionNotificationType`, verbatim.
public enum ReactionNotifications: UInt64, Hashable, Sendable, CaseIterable, Identifiable {
    case all = 0
    case directMessagesOnly = 1
    case never = 2

    public var id: Self { self }

    public var title: String {
        switch self {
        case .all: "All messages"
        case .directMessagesOnly: "Only direct messages"
        case .never: "Never"
        }
    }

    public var symbolName: String {
        switch self {
        case .all: "bell"
        case .directMessagesOnly: "bubble.left"
        case .never: "bell.slash"
        }
    }
}

/// One switch on the page.
///
/// **An enum rather than a property per switch**, because the page is a list of
/// eleven identical rows and the only thing that differs between them is a field
/// number and a sentence. A struct with eleven `Bool`s would be eleven bindings
/// to write and eleven chances to bind a row to its neighbour's field.
public enum NotificationSwitch: String, Hashable, Sendable, CaseIterable, Identifiable {
    // Things other people do.
    case friendsComeOnline
    case friendAnniversary
    case profileUpdates
    case friendGamingActivity
    case voiceActivity
    case upcomingServerEvents
    case serverTrending
    case summaryReminders
    // Things this account does, which its friends are told about.
    case letFriendsKnowIGoLive
    case letFriendsKnowIComeOnline
    case letFriendsKnowIUpdateMyProfile

    public var id: String { rawValue }

    /// Discord's field number inside `NotificationSettings`.
    public var field: Int {
        switch self {
        case .letFriendsKnowIGoLive: 2
        case .voiceActivity: 11
        case .friendsComeOnline: 12
        case .friendAnniversary: 14
        case .profileUpdates: 16
        case .serverTrending: 17
        case .summaryReminders: 19
        case .friendGamingActivity: 21
        case .upcomingServerEvents: 22
        case .letFriendsKnowIUpdateMyProfile: 24
        case .letFriendsKnowIComeOnline: 25
        }
    }

    public var title: String {
        switch self {
        case .friendsComeOnline: "Friends come online"
        case .friendAnniversary: "A friend and I reach a friendship anniversary"
        case .profileUpdates: "Friends update their profile"
        case .friendGamingActivity: "Friends start playing something"
        case .voiceActivity: "People I know start streaming or join a call"
        case .upcomingServerEvents: "A server has an upcoming event"
        case .serverTrending: "A server I am in is trending"
        case .summaryReminders: "There is a summary of what I missed"
        case .letFriendsKnowIGoLive: "I go live"
        case .letFriendsKnowIComeOnline: "I come online"
        case .letFriendsKnowIUpdateMyProfile: "I update my profile"
        }
    }

    /// Whether the switch is about being told, or about telling.
    public var isOutgoing: Bool {
        switch self {
        case .letFriendsKnowIGoLive,
             .letFriendsKnowIComeOnline,
             .letFriendsKnowIUpdateMyProfile:
            true
        default:
            false
        }
    }

    public static let incoming = allCases.filter { !$0.isOutgoing }
    public static let outgoing = allCases.filter(\.isOutgoing)
}

/// What the account's notification settings say.
///
/// **`NotificationPreferences` is already taken** — by the per-server and
/// per-channel mute table, which is a different thing entirely: that one is
/// *where* notifications come from, this one is *which kinds* the account wants
/// at all. Two names rather than one type holding both, because they arrive from
/// different places and are written through different routes.
public struct NotificationSubscriptions: Hashable, Sendable {
    /// Which of the switches are OFF.
    ///
    /// **The off set, not the on set.** Every one of them defaults on, so an
    /// account that has never touched the page has an empty set here — and a
    /// build that adds a switch gets the right answer for it without a
    /// migration.
    public var off: Set<NotificationSwitch>
    public var reactions: ReactionNotifications
    /// `show_in_app_notifications`.
    public var showsInApp: Bool
    /// `quiet_mode` — the one that defaults off.
    public var isQuiet: Bool

    public init(
        off: Set<NotificationSwitch> = [],
        reactions: ReactionNotifications = .all,
        showsInApp: Bool = true,
        isQuiet: Bool = false
    ) {
        self.off = off
        self.reactions = reactions
        self.showsInApp = showsInApp
        self.isQuiet = isQuiet
    }

    public subscript(item: NotificationSwitch) -> Bool {
        get { !off.contains(item) }
        set { if newValue { off.remove(item) } else { off.insert(item) } }
    }
}
