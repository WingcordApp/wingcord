import Foundation

/// A message.
///
/// **The size of this type is a design constraint, not an afterthought.** A busy
/// session holds tens of thousands of them and the store copies them on every
/// edit, reaction and read-state pass. Everything a plain text message does not
/// have — attachments, embeds, reactions, mentions, a reply reference, an
/// interaction record — is behind `payload`, one optional class reference. A
/// plain "ok" from a friend is the common case and it costs 8 bytes for all of
/// it.
///
/// There is no `guildId` field, deliberately. Discord sends one on gateway
/// messages and omits it on everything fetched over REST — that is, on all
/// history — so a field that is present for the newest page and nil for every
/// page behind it invites exactly the bug it looks like it prevents: code reads
/// it, finds nil, and falls back to a linear scan over every guild and every
/// channel, per row, per evaluation. The channel knows its guild. Ask the
/// channel.
public struct Message: Hashable, Sendable, Identifiable, Codable {
    public var id: MessageID
    public var channelID: ChannelID
    public var authorID: UserID
    public var content: String
    /// Nil unless the message has been edited.
    public var editedAt: Date?
    public var kind: MessageKind
    public var flags: MessageFlags
    /// Everything rare. Nil for a plain text message.
    public var payload: MessagePayload?

    /// When the message was sent. Derived from the snowflake rather than stored:
    /// the id already carries a millisecond timestamp, so a `Date` field would
    /// be 8 bytes per message duplicating a value that cannot disagree.
    public var sentAt: Date { id.timestamp }

    public init(
        id: MessageID,
        channelID: ChannelID,
        authorID: UserID,
        content: String = "",
        editedAt: Date? = nil,
        kind: MessageKind = .default,
        flags: MessageFlags = [],
        payload: MessagePayload? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.authorID = authorID
        self.content = content
        self.editedAt = editedAt
        self.kind = kind
        self.flags = flags
        self.payload = payload
    }

    public var attachments: [Attachment] { payload?.attachments ?? [] }
    public var embeds: [Embed] { payload?.embeds ?? [] }
    public var reactions: [Reaction] { payload?.reactions ?? [] }
    public var referencedMessageID: MessageID? { payload?.referencedMessageID }
    public var mentionedUserIDs: [UserID] { payload?.mentionedUserIDs ?? [] }
    public var mentionsEveryone: Bool { payload?.mentionsEveryone ?? false }
    public var webhookID: UserID? { payload?.webhookID }

    /// Whether the message shows nothing at all without its components.
    ///
    /// An app posting through Components V2 sends `content: ""` and no embeds,
    /// putting everything in `components`. A renderer that only knows about
    /// content and embeds draws an author line and a blank space, which is
    /// indistinguishable from a bug. The flag is the tell.
    public var isComponentsOnly: Bool {
        flags.contains(.isComponentsV2)
    }

    /// Whether the message has any renderable body at all.
    public var isEmpty: Bool {
        content.isEmpty && attachments.isEmpty && embeds.isEmpty
            && (payload?.stickers.isEmpty ?? true) && !isComponentsOnly
    }

    /// Whether this row addresses an *object* rather than something someone
    /// typed.
    ///
    /// Discord composes a call record server-side with no content, so Reply
    /// quotes an empty body, Forward delivers a call record to a channel it did
    /// not happen in, and Edit has nothing anyone wrote. Those actions are
    /// dropped from both the menu and the hover pill for these kinds.
    public var isSystemEvent: Bool {
        switch kind {
        case .default, .reply, .chatInputCommand, .contextMenuCommand, .threadStarterMessage:
            false
        default:
            true
        }
    }
}

/// Everything a message rarely has.
///
/// A final class so `Message` stays small and copying one copies a pointer. Its
/// stored properties are `let`, so a shared box can never be mutated out from
/// under another holder — an edit builds a new box.
public final class MessagePayload: Hashable, Sendable, Codable {
    public let attachments: [Attachment]
    public let embeds: [Embed]
    public let reactions: [Reaction]
    public let stickers: [StickerRef]
    public let mentionedUserIDs: [UserID]
    public let mentionedRoleIDs: [RoleID]
    public let mentionsEveryone: Bool
    public let referencedMessageID: MessageID?
    public let referencedChannelID: ChannelID?
    /// A webhook's author id belongs to no account. Kept distinct from
    /// `isBot` because webhooks set that too, and the difference decides whether
    /// asking the gateway for the author is a request that can ever be answered.
    public let webhookID: UserID?
    /// The nonce a pending send was posted with, so the echo can be matched to
    /// the optimistic row and replace it rather than duplicating it.
    public let nonce: String?

    public init(
        attachments: [Attachment] = [],
        embeds: [Embed] = [],
        reactions: [Reaction] = [],
        stickers: [StickerRef] = [],
        mentionedUserIDs: [UserID] = [],
        mentionedRoleIDs: [RoleID] = [],
        mentionsEveryone: Bool = false,
        referencedMessageID: MessageID? = nil,
        referencedChannelID: ChannelID? = nil,
        webhookID: UserID? = nil,
        nonce: String? = nil
    ) {
        self.attachments = attachments
        self.embeds = embeds
        self.reactions = reactions
        self.stickers = stickers
        self.mentionedUserIDs = mentionedUserIDs
        self.mentionedRoleIDs = mentionedRoleIDs
        self.mentionsEveryone = mentionsEveryone
        self.referencedMessageID = referencedMessageID
        self.referencedChannelID = referencedChannelID
        self.webhookID = webhookID
        self.nonce = nonce
    }

    /// Whether the box is worth allocating. A decoder that builds one of these
    /// for every plain message has undone the point of the type.
    public var isEmpty: Bool {
        attachments.isEmpty && embeds.isEmpty && reactions.isEmpty
            && stickers.isEmpty && mentionedUserIDs.isEmpty
            && mentionedRoleIDs.isEmpty && !mentionsEveryone
            && referencedMessageID == nil && webhookID == nil && nonce == nil
    }

    public static func == (lhs: MessagePayload, rhs: MessagePayload) -> Bool {
        // Identity first. Two messages that share a box — every copy of one
        // message in the store — settle in a pointer compare, which is the
        // common case by a wide margin.
        lhs === rhs
            || (lhs.attachments == rhs.attachments
                && lhs.embeds == rhs.embeds
                && lhs.reactions == rhs.reactions
                && lhs.stickers == rhs.stickers
                && lhs.mentionedUserIDs == rhs.mentionedUserIDs
                && lhs.mentionedRoleIDs == rhs.mentionedRoleIDs
                && lhs.mentionsEveryone == rhs.mentionsEveryone
                && lhs.referencedMessageID == rhs.referencedMessageID
                && lhs.webhookID == rhs.webhookID)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(attachments.count)
        hasher.combine(embeds.count)
        hasher.combine(reactions.count)
        hasher.combine(referencedMessageID)
    }
}

public enum MessageKind: Int, Hashable, Sendable, Codable {
    case `default` = 0
    case recipientAdd = 1
    case recipientRemove = 2
    case call = 3
    case channelNameChange = 4
    case channelIconChange = 5
    case channelPinnedMessage = 6
    case userJoin = 7
    case guildBoost = 8
    case guildBoostTier1 = 9
    case guildBoostTier2 = 10
    case guildBoostTier3 = 11
    case channelFollowAdd = 12
    case threadCreated = 18
    case reply = 19
    case chatInputCommand = 20
    case threadStarterMessage = 21
    case contextMenuCommand = 23
    case autoModerationAction = 24
    case unknown = -1

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .default
        case 1: .recipientAdd
        case 2: .recipientRemove
        case 3: .call
        case 4: .channelNameChange
        case 5: .channelIconChange
        case 6: .channelPinnedMessage
        case 7: .userJoin
        case 8: .guildBoost
        case 9: .guildBoostTier1
        case 10: .guildBoostTier2
        case 11: .guildBoostTier3
        case 12: .channelFollowAdd
        case 18: .threadCreated
        case 19: .reply
        case 20: .chatInputCommand
        case 21: .threadStarterMessage
        case 23: .contextMenuCommand
        case 24: .autoModerationAction
        default: .unknown
        }
    }
}

public struct MessageFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let crossposted = MessageFlags(rawValue: 1 << 0)
    public static let isCrosspost = MessageFlags(rawValue: 1 << 1)
    public static let suppressEmbeds = MessageFlags(rawValue: 1 << 2)
    public static let sourceMessageDeleted = MessageFlags(rawValue: 1 << 3)
    public static let urgent = MessageFlags(rawValue: 1 << 4)
    public static let hasThread = MessageFlags(rawValue: 1 << 5)
    public static let ephemeral = MessageFlags(rawValue: 1 << 6)
    public static let loading = MessageFlags(rawValue: 1 << 7)
    public static let suppressNotifications = MessageFlags(rawValue: 1 << 12)
    public static let isVoiceMessage = MessageFlags(rawValue: 1 << 13)
    /// The message renders entirely from `components`. See
    /// `Message.isComponentsOnly`.
    public static let isComponentsV2 = MessageFlags(rawValue: 1 << 15)
}

public struct Attachment: Hashable, Sendable, Identifiable, Codable {
    public var id: AttachmentID
    public var filename: String
    public var url: String
    public var proxyURL: String
    public var contentType: String?
    public var size: Int
    public var width: Int?
    public var height: Int?
    /// A spoilered attachment is named `SPOILER_…` by the uploader; Discord
    /// carries no flag for it.
    public var isSpoiler: Bool { filename.hasPrefix("SPOILER_") }
    public var description: String?
    /// Voice message waveform, base64. Present only on voice notes.
    public var waveform: String?
    public var durationSeconds: Double?

    public init(
        id: AttachmentID,
        filename: String,
        url: String,
        proxyURL: String,
        contentType: String? = nil,
        size: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        description: String? = nil,
        waveform: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.proxyURL = proxyURL
        self.contentType = contentType
        self.size = size
        self.width = width
        self.height = height
        self.description = description
        self.waveform = waveform
        self.durationSeconds = durationSeconds
    }

    public var isImage: Bool {
        contentType?.hasPrefix("image/") ?? false
    }

    public var isVideo: Bool {
        contentType?.hasPrefix("video/") ?? false
    }

    /// The intrinsic aspect ratio, or nil when Discord sent no dimensions.
    ///
    /// Nil is a real state: a layout that substitutes 1.0 reserves a square for
    /// a panorama and then jumps when the picture arrives.
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

public struct Reaction: Hashable, Sendable, Codable {
    public var emoji: EmojiRef
    public var count: Int
    public var isMine: Bool
    /// Burst (super) reaction count, kept separate because it renders
    /// differently and Discord counts it separately.
    public var burstCount: Int

    public init(emoji: EmojiRef, count: Int, isMine: Bool, burstCount: Int = 0) {
        self.emoji = emoji
        self.count = count
        self.isMine = isMine
        self.burstCount = burstCount
    }
}

/// An emoji, either a Unicode sequence or a custom upload.
public struct EmojiRef: Hashable, Sendable, Codable {
    /// Nil for a Unicode emoji.
    public var id: EmojiID?
    /// The Unicode sequence, or the custom emoji's name.
    public var name: String
    public var isAnimated: Bool

    public init(id: EmojiID? = nil, name: String, isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }

    public var isCustom: Bool { id != nil }

    /// The form Discord's reaction routes want in a path segment: `name:id` for
    /// a custom emoji, the bare sequence for a Unicode one.
    public var apiIdentifier: String {
        if let id { return "\(name):\(id.rawValue)" }
        return name
    }
}

public struct StickerRef: Hashable, Sendable, Identifiable, Codable {
    public enum Format: Int, Hashable, Sendable, Codable {
        case png = 1
        case apng = 2
        case lottie = 3
        case gif = 4
        case unknown = -1

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .png
            case 2: .apng
            case 3: .lottie
            case 4: .gif
            default: .unknown
            }
        }
    }

    public var id: UInt64
    public var name: String
    public var format: Format

    public init(id: UInt64, name: String, format: Format) {
        self.id = id
        self.name = name
        self.format = format
    }
}
