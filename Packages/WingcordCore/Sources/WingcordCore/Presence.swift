import Foundation

/// A person's availability.
public enum PresenceStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case online
    case idle
    case doNotDisturb = "dnd"
    case invisible
    case offline

    /// What the roster sorts and groups by. Invisible is only ever *your own*
    /// status — everyone else's invisible arrives as offline — and it groups
    /// with online because that is where you are.
    public var isOnline: Bool {
        self != .offline
    }

    public var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .invisible: "Invisible"
        case .offline: "Offline"
        }
    }
}

/// One person's presence, as the gateway last reported it.
///
/// Small and copied often — one per visible roster row, replaced on every
/// presence flush — so the activity list is behind an optional box on the same
/// argument as `MessagePayload`. Most people online are not doing anything the
/// client can show.
public struct Presence: Hashable, Sendable {
    public var userID: UserID
    public var status: PresenceStatus
    /// Whether any of the person's sessions is a phone. Drawn as the phone glyph
    /// instead of a dot.
    public var isOnMobile: Bool
    public var activities: PresenceActivities?

    public init(
        userID: UserID,
        status: PresenceStatus,
        isOnMobile: Bool = false,
        activities: PresenceActivities? = nil
    ) {
        self.userID = userID
        self.status = status
        self.isOnMobile = isOnMobile
        self.activities = activities
    }

    /// The custom status line, if the person has set one.
    public var customStatus: Activity? {
        activities?.list.first { $0.kind == .custom }
    }

    /// The activity worth showing in a row: the first that is not a custom
    /// status. A person can be playing a game *and* have a custom status, and
    /// the row shows the game.
    public var primaryActivity: Activity? {
        activities?.list.first { $0.kind != .custom }
    }
}

/// The activity list, boxed.
public final class PresenceActivities: Hashable, Sendable {
    public let list: [Activity]
    public init(list: [Activity]) { self.list = list }

    public static func == (lhs: PresenceActivities, rhs: PresenceActivities) -> Bool {
        lhs === rhs || lhs.list == rhs.list
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(list) }
}

public struct Activity: Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable {
        case playing = 0
        case streaming = 1
        case listening = 2
        case watching = 3
        case custom = 4
        case competing = 5
        case unknown = -1

        public init(rawValue: Int) {
            self = switch rawValue {
            case 0: .playing
            case 1: .streaming
            case 2: .listening
            case 3: .watching
            case 4: .custom
            case 5: .competing
            default: .unknown
            }
        }
    }

    public var kind: Kind
    public var name: String
    public var state: String?
    public var details: String?
    public var applicationID: ApplicationID?
    public var largeImageKey: String?
    public var smallImageKey: String?
    /// A custom status' emoji.
    public var emoji: EmojiRef?
    public var startedAt: Date?
    /// `[current, maximum]`. **This is where "1 Playing" comes from** on an
    /// activity invitation, and it is the only count on the wire — an app that
    /// sends no party is one this client cannot count for.
    public var partySize: [Int]?

    public init(
        kind: Kind,
        name: String,
        state: String? = nil,
        details: String? = nil,
        applicationID: ApplicationID? = nil,
        largeImageKey: String? = nil,
        smallImageKey: String? = nil,
        emoji: EmojiRef? = nil,
        startedAt: Date? = nil,
        partySize: [Int]? = nil
    ) {
        self.partySize = partySize
        self.kind = kind
        self.name = name
        self.state = state
        self.details = details
        self.applicationID = applicationID
        self.largeImageKey = largeImageKey
        self.smallImageKey = smallImageKey
        self.emoji = emoji
        self.startedAt = startedAt
    }

    /// The single line a roster row shows beneath the name.
    ///
    /// A custom status is its own `state` and nothing else; every other kind
    /// gets a verb, because "Wingcord" alone under a name says nothing about
    /// whether the person is playing it, streaming it or listening to it.
    public var rowSubtitle: String? {
        switch kind {
        case .custom:
            state
        case .playing:
            "Playing \(name)"
        case .streaming:
            "Streaming \(name)"
        case .listening:
            state.map { "Listening to \($0)" } ?? "Listening to \(name)"
        case .watching:
            "Watching \(name)"
        case .competing:
            "Competing in \(name)"
        case .unknown:
            name.isEmpty ? nil : name
        }
    }
}
