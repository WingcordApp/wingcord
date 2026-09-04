import Foundation

/// A thread's own state, beyond what every channel carries.
///
/// Discord nests this under `thread_metadata` rather than flattening it onto the
/// channel, and it is kept nested here for the same reason it is worth having at
/// all: its presence is what *makes* a channel a thread on the wire. A forum
/// post and a thread off a message are the same object with the same nested
/// block; only `parentID`'s channel kind tells them apart.
public struct ThreadMetadata: Hashable, Sendable, Codable {
    /// Archived threads are read-only until somebody posts — which un-archives
    /// them, unless `locked`.
    public var isArchived: Bool
    /// When the archive state last changed. **Not when the thread was made** —
    /// creating, archiving, un-archiving and changing `autoArchiveDuration` all
    /// move it, so it is useless as a creation time. `createdAt` is the one for
    /// that, and the id's own timestamp is the one that is always there.
    public var archivedAt: Date?
    /// Minutes of silence before Discord archives it: 60, 1440, 4320 or 10080.
    ///
    /// Stored as the raw minute count rather than an enum. A client that models
    /// it as four cases cannot round-trip a fifth that Discord adds, and this
    /// value is written back verbatim on any edit that touches the thread.
    public var autoArchiveMinutes: Int
    /// A locked thread does not un-archive on a new message. Only
    /// `MANAGE_THREADS` can act on it.
    public var isLocked: Bool
    /// Private threads only: whether non-moderators may add people.
    public var isInvitable: Bool?
    /// Present on threads made after Discord started sending it. Older ones have
    /// nil here and only the id's timestamp — which is why nothing reads this
    /// without a fallback.
    public var createdAt: Date?

    public init(
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        autoArchiveMinutes: Int = 4320,
        isLocked: Bool = false,
        isInvitable: Bool? = nil,
        createdAt: Date? = nil
    ) {
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.autoArchiveMinutes = autoArchiveMinutes
        self.isLocked = isLocked
        self.isInvitable = isInvitable
        self.createdAt = createdAt
    }
}

/// The bits Discord keeps on a thread member.
///
/// **Captured**, `threads.har`: three `PATCH .../thread-members/@me/settings`
/// calls sending `{"flags":2}`, `{"flags":4}` and `{"flags":8}` for All
/// Messages, Only @mentions and Nothing respectively. The reply to the first
/// came back `flags: 3` — so bit 0 is the server's own and is OR'd back in.
public struct ThreadMemberFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Set by the server the first time you act in the thread. **Never sent by
    /// this client** — see `ThreadNotification.wireFlags`.
    public static let hasInteracted = ThreadMemberFlags(rawValue: 1 << 0)
    public static let allMessages = ThreadMemberFlags(rawValue: 1 << 1)
    public static let onlyMentions = ThreadMemberFlags(rawValue: 1 << 2)
    public static let noMessages = ThreadMemberFlags(rawValue: 1 << 3)
}

/// Which messages in a thread are worth a notification.
///
/// A closed enum over the three bits rather than the bitfield itself, because
/// the three are mutually exclusive in every payload observed and a radio group
/// is what the reader is actually choosing between. The bitfield stays in
/// `ThreadMemberFlags` for the bits this does not model.
public enum ThreadNotification: Hashable, Sendable, CaseIterable {
    case allMessages
    case onlyMentions
    case nothing

    /// Reads the setting out of a member's flags.
    ///
    /// **Order matters, and the fallback is not arbitrary.** A member who has
    /// never touched the setting has none of the three bits — Discord means "as
    /// the parent channel says" by that, and the closest thing this enum can say
    /// is the middle one, which is also Discord's own default for a joined
    /// thread. Returning nil instead would make every caller write the same
    /// coalesce.
    public init(flags: ThreadMemberFlags) {
        self = if flags.contains(.allMessages) { .allMessages }
        else if flags.contains(.noMessages) { .nothing }
        else { .onlyMentions }
    }

    /// The value to PATCH.
    ///
    /// **One bit, and only the one.** The capture sends a bare `{"flags":2}`
    /// while the member's stored value was `3`; echoing the whole field back
    /// would either re-assert `hasInteracted` — which is the server's to set —
    /// or clear it, depending on what the client had cached. Sending the single
    /// bit lets Discord merge, which is what it demonstrably does.
    public var wireFlags: ThreadMemberFlags {
        switch self {
        case .allMessages: .allMessages
        case .onlyMentions: .onlyMentions
        case .nothing: .noMessages
        }
    }
}

/// How long a thread stays muted.
///
/// **Captured**, `forums.har`: `{"muted":true,"mute_config":{
/// "selected_time_window":900,"end_time":"2026-09-04T14:16:42.000Z"}}` for the
/// "For 15 Minutes" row — so the window is *seconds*, and the end time is
/// computed by the client rather than by the server.
public enum MuteDuration: Int, Hashable, Sendable, CaseIterable {
    case fifteenMinutes = 900
    case oneHour = 3600
    case threeHours = 10800
    case eightHours = 28800
    case twentyFourHours = 86400
    /// Discord's own sentinel for an indefinite mute: the window is -1 and there
    /// is no end time.
    case untilTurnedBackOn = -1

    public var title: String {
        switch self {
        case .fifteenMinutes: "For 15 Minutes"
        case .oneHour: "For 1 Hour"
        case .threeHours: "For 3 Hours"
        case .eightHours: "For 8 Hours"
        case .twentyFourHours: "For 24 Hours"
        case .untilTurnedBackOn: "Until I turn it back on"
        }
    }

    /// When a mute started now would lapse. Nil for the indefinite case.
    public func endTime(from now: Date = .now) -> Date? {
        self == .untilTurnedBackOn ? nil : now.addingTimeInterval(TimeInterval(rawValue))
    }
}

/// A mute that is running.
public struct ThreadMuteConfig: Hashable, Sendable, Codable {
    /// Nil means indefinite — "Until I turn it back on".
    public var endTime: Date?
    /// The row the reader picked, in seconds, or -1 for indefinite. Kept so the
    /// menu can show which one is ticked without having to infer it from the
    /// remaining time, which drifts.
    public var selectedTimeWindow: Int?

    public init(endTime: Date? = nil, selectedTimeWindow: Int? = nil) {
        self.endTime = endTime
        self.selectedTimeWindow = selectedTimeWindow
    }

    /// Whether the mute is still in force at `date`.
    ///
    /// **A lapsed mute is not un-muted on the wire.** Discord leaves `muted`
    /// true and lets the end time pass, so a client that reads the flag alone
    /// shows a thread as muted for ever. Every read of the mute state goes
    /// through here.
    public func isActive(at date: Date = .now) -> Bool {
        guard let endTime else { return true }
        return endTime > date
    }
}

/// The current user's membership of one thread.
///
/// Discord returns this from the join call, from `threads/search`, and on
/// `THREAD_MEMBER_UPDATE`. It is the *only* record that the account follows a
/// thread — a thread's presence in the channel list does not imply it.
public struct ThreadMember: Hashable, Sendable, Codable, Identifiable {
    /// The thread's id. Discord names it `id`, not `thread_id`.
    public var id: ChannelID
    public var userID: UserID
    public var joinedAt: Date?
    public var flags: ThreadMemberFlags
    public var isMuted: Bool
    public var muteConfig: ThreadMuteConfig?

    public init(
        id: ChannelID,
        userID: UserID,
        joinedAt: Date? = nil,
        flags: ThreadMemberFlags = [],
        isMuted: Bool = false,
        muteConfig: ThreadMuteConfig? = nil
    ) {
        self.id = id
        self.userID = userID
        self.joinedAt = joinedAt
        self.flags = flags
        self.isMuted = isMuted
        self.muteConfig = muteConfig
    }

    /// What the notification submenu shows as ticked.
    public var notification: ThreadNotification { ThreadNotification(flags: flags) }

    /// Whether the mute is both set and unexpired — see `ThreadMuteConfig.isActive`.
    public func isMutedNow(at date: Date = .now) -> Bool {
        isMuted && (muteConfig?.isActive(at: date) ?? true)
    }
}
