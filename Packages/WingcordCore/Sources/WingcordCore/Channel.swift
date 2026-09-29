import Foundation

/// Every channel kind Discord has, with the raw values it sends.
///
/// The `default` case on the decoder side is deliberate and load-bearing:
/// Discord ships new kinds without warning, and a client that throws on an
/// unknown one fails to decode the *whole guild* rather than hiding one row.
public enum ChannelKind: Int, Hashable, Sendable, Codable {
    case text = 0
    case directMessage = 1
    case voice = 2
    case groupDirectMessage = 3
    case category = 4
    case announcement = 5
    case announcementThread = 10
    case publicThread = 11
    case privateThread = 12
    case stage = 13
    case directory = 14
    case forum = 15
    case media = 16
    /// Anything Discord adds after this file was written.
    case unknown = -1

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .text
        case 1: .directMessage
        case 2: .voice
        case 3: .groupDirectMessage
        case 4: .category
        case 5: .announcement
        case 10: .announcementThread
        case 11: .publicThread
        case 12: .privateThread
        case 13: .stage
        case 14: .directory
        case 15: .forum
        case 16: .media
        default: .unknown
        }
    }

    /// Whether this kind holds a message transcript the timeline can render.
    public var isConversation: Bool {
        switch self {
        case .text, .directMessage, .groupDirectMessage, .announcement,
             .announcementThread, .publicThread, .privateThread, .voice:
            true
        case .category, .stage, .directory, .forum, .media, .unknown:
            false
        }
    }

    public var isThread: Bool {
        self == .publicThread || self == .privateThread || self == .announcementThread
    }

    public var isPrivate: Bool {
        self == .directMessage || self == .groupDirectMessage
    }

    /// The SF Symbol drawn in the channel list's gutter.
    ///
    /// A `#` for a text channel is a glyph, not a symbol — `number` is the
    /// system's own and lines up on the text baseline, which a literal "#"
    /// character in a `Text` does not.
    public var symbolName: String {
        switch self {
        case .text: "number"
        case .voice: "speaker.wave.2.fill"
        case .announcement: "megaphone.fill"
        case .stage: "person.wave.2.fill"
        case .forum: "list.bullet.rectangle"
        case .media: "photo.on.rectangle"
        case .directory: "signpost.right.fill"
        case .announcementThread, .publicThread, .privateThread: "text.bubble"
        case .directMessage, .groupDirectMessage: "at"
        case .category, .unknown: "questionmark"
        }
    }
}

/// A channel, of any kind.
///
/// One type for all of them rather than a protocol or an enum of payloads. A
/// channel list, a read-state table and a navigation target all want to hold
/// "a channel" without caring which kind, and every kind-specific field here is
/// optional anyway — Discord's own payload is one heterogeneous object.
public struct Channel: Hashable, Sendable, Identifiable, Codable {
    public var id: ChannelID
    public var kind: ChannelKind
    /// Nil for DMs and group DMs, which belong to no guild.
    public var guildID: GuildID?
    public var name: String
    public var topic: String?
    /// The category this sits in, or nil for an uncategorised channel.
    public var parentID: ChannelID?
    /// Discord's sort key within its category. Ties break on id.
    public var position: Int
    public var isNSFW: Bool
    /// The id of the newest message, as Discord last told us.
    ///
    /// **This field moves constantly and changes no structure.** Every inbound
    /// message rewrites it. Any index built over channels must be able to say so
    /// — see `ChannelIndex.patchLastMessage` — or the index is torn down and
    /// rebuilt over every guild and every channel several times a second, which
    /// is a memo that is present, correct, and never hit.
    public var lastMessageID: MessageID?
    /// Slow mode, in seconds. Zero means off.
    public var rateLimitPerUser: Int
    /// Per-channel permission overwrites, in Discord's order.
    public var overwrites: [PermissionOverwrite]
    /// Group DM and DM participants. Empty for a guild channel.
    public var recipientIDs: [UserID]
    /// A group DM's custom icon hash.
    public var iconHash: String?
    /// A group DM's owner — the person who made it, and the only one who can
    /// rename it or remove anybody. Nil everywhere else.
    public var ownerID: UserID?
    /// Threads only: the parent conversation's id is `parentID`, and this is the
    /// message count Discord reports.
    public var messageCount: Int?
    /// A voice channel's audio ceiling, in bits per second.
    ///
    /// **The encoder is configured from this, not from a constant.** Discord's
    /// mixer drops anything over the channel's own limit rather than
    /// transcoding it, so a client that always encodes at 96k is a client that
    /// is silent in every unboosted server — which is most of them.
    public var bitrate: Int?
    /// How many people a voice channel holds. Zero, and nil, both mean no limit.
    public var userLimit: Int?
    /// A thread's own state. **Its presence is what makes this a thread** — see
    /// `ThreadMetadata`. Nil on every other kind.
    public var threadMetadata: ThreadMetadata?
    /// A forum post's tags, as ids into its parent forum's `availableTags`.
    /// Up to five. Empty on everything that is not a post.
    public var appliedTags: [ForumTagID]
    /// A forum's own tag definitions. Up to twenty. Empty everywhere else.
    ///
    /// **This arrives over the gateway, never over HTTP.** The channel object in
    /// READY and GUILD_CREATE carries it; no REST route this client calls
    /// returns it. A forum whose posts render with bare tag ids is a forum whose
    /// channel object was never merged, not a decode fault here.
    public var availableTags: [ForumTag]
    /// The one-tap reaction Discord offers on every post in this forum.
    public var defaultReaction: EmojiRef?
    /// The order the forum opens in, before the reader chooses one.
    public var defaultSortOrder: ForumSortOrder?
    /// The layout the forum opens in. Discord's 0 is resolved on decode — see
    /// `ForumLayout.init(rawChannelValue:)`.
    public var defaultForumLayout: ForumLayout?
    /// Slow mode *inside* new posts, in seconds. Copied onto a post at creation;
    /// the forum's own `rateLimitPerUser` throttles making posts instead.
    public var defaultThreadRateLimitPerUser: Int?
    /// Text a new post's composer is pre-filled with.
    public var template: String?
    /// Discord's channel bitfield. Carried whole so the bits this client cannot
    /// draw survive a write back — `INVARIANTS.md` §1.
    public var flags: ChannelFlags
    /// A thread's approximate member count. **Discord stops counting at 50**, so
    /// this is a floor above that, never a total.
    public var memberCount: Int?
    /// A handful of the people in a thread, for a row's avatar stack.
    ///
    /// **Five ids and nothing else** — no user objects, so a client that has not
    /// met these people cannot draw their faces and must degrade to the count
    /// beside them. `threads/search` is the only route that sends it.
    public var memberIDsPreview: [UserID]
    /// Every message ever sent in a thread, including deleted ones — it never
    /// goes down where `messageCount` does.
    ///
    /// **Not what a chip shows**, despite being the more stable number: the
    /// capture's thread reports 728 here against a `messageCount` of 720, and
    /// Discord's own chip reads "720 Messages". See `threadMessageCount`.
    public var totalMessageSent: Int?
    /// The member list this channel shows, when the server names it — which
    /// outranks the list Discord's rule would otherwise pick. See
    /// `MemberList.id(for:everyonePermissions:)`.
    public var memberListID: String?

    public init(
        id: ChannelID,
        kind: ChannelKind,
        guildID: GuildID? = nil,
        name: String = "",
        topic: String? = nil,
        parentID: ChannelID? = nil,
        position: Int = 0,
        isNSFW: Bool = false,
        lastMessageID: MessageID? = nil,
        rateLimitPerUser: Int = 0,
        overwrites: [PermissionOverwrite] = [],
        recipientIDs: [UserID] = [],
        iconHash: String? = nil,
        ownerID: UserID? = nil,
        messageCount: Int? = nil,
        bitrate: Int? = nil,
        userLimit: Int? = nil,
        threadMetadata: ThreadMetadata? = nil,
        appliedTags: [ForumTagID] = [],
        availableTags: [ForumTag] = [],
        defaultReaction: EmojiRef? = nil,
        defaultSortOrder: ForumSortOrder? = nil,
        defaultForumLayout: ForumLayout? = nil,
        defaultThreadRateLimitPerUser: Int? = nil,
        template: String? = nil,
        flags: ChannelFlags = [],
        memberCount: Int? = nil,
        memberIDsPreview: [UserID] = [],
        totalMessageSent: Int? = nil,
        memberListID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.guildID = guildID
        self.name = name
        self.topic = topic
        self.parentID = parentID
        self.position = position
        self.isNSFW = isNSFW
        self.lastMessageID = lastMessageID
        self.rateLimitPerUser = rateLimitPerUser
        self.overwrites = overwrites
        self.recipientIDs = recipientIDs
        self.iconHash = iconHash
        self.ownerID = ownerID
        self.messageCount = messageCount
        self.bitrate = bitrate
        self.userLimit = userLimit
        self.threadMetadata = threadMetadata
        self.appliedTags = appliedTags
        self.availableTags = availableTags
        self.defaultReaction = defaultReaction
        self.defaultSortOrder = defaultSortOrder
        self.defaultForumLayout = defaultForumLayout
        self.defaultThreadRateLimitPerUser = defaultThreadRateLimitPerUser
        self.template = template
        self.flags = flags
        self.memberCount = memberCount
        self.memberIDsPreview = memberIDsPreview
        self.totalMessageSent = totalMessageSent
        self.memberListID = memberListID
    }

    /// Whether this channel holds posts rather than a transcript.
    ///
    /// Forum and media are one concept with two layouts, and every call site
    /// that cares treats them identically — a media channel is a forum whose
    /// posts lead with a picture.
    public var isForumLike: Bool { kind == .forum || kind == .media }

    /// Whether this post is pinned to the top of its forum.
    public var isPinnedPost: Bool { flags.contains(.pinned) }

    /// Whether a post here must carry at least one tag.
    public var requiresTag: Bool { flags.contains(.requireTag) }

    /// The "N messages" a thread chip or a forum row shows.
    ///
    /// **`messageCount`, and the capture settles which.** A thread in
    /// `threads.har` reports `message_count: 720` beside
    /// `total_message_sent: 728`, and Discord's own chip reads "720 Messages" —
    /// so the number people see excludes deleted messages rather than counting
    /// everything ever sent. `totalMessageSent` is the fallback only where the
    /// other is missing, which is a thread old enough that Discord caps it.
    /// Neither includes the opening message.
    public var threadMessageCount: Int? { messageCount ?? totalMessageSent }

    /// Sort order inside a guild.
    ///
    /// Discord orders by `position` and breaks ties on id, and the tie is not
    /// rare — a bulk channel creation gives every new channel position 0. Two
    /// channels that compare equal make `sorted` unstable, so the list reorders
    /// itself between two identical payloads, which reads as the sidebar
    /// twitching.
    public static func listOrder(_ lhs: Channel, _ rhs: Channel) -> Bool {
        lhs.position != rhs.position
            ? lhs.position < rhs.position
            : lhs.id.rawValue < rhs.id.rawValue
    }
}

/// One permission overwrite on a channel.
public struct PermissionOverwrite: Hashable, Sendable, Codable {
    public enum Subject: Int, Hashable, Sendable, Codable {
        case role = 0
        case member = 1
    }

    /// A `RoleID` or a `UserID` depending on `subject`. Stored raw because it is
    /// genuinely one or the other, and a phantom-typed id here would need a
    /// wrapper enum that every call site would immediately unwrap.
    public var id: UInt64
    public var subject: Subject
    public var allow: Permissions
    public var deny: Permissions

    public init(id: UInt64, subject: Subject, allow: Permissions, deny: Permissions) {
        self.id = id
        self.subject = subject
        self.allow = allow
        self.deny = deny
    }
}
