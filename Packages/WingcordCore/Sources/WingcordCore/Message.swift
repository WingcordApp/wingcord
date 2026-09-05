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
    /// Whether the channel is holding this message on its pinned list.
    ///
    /// **A stored `Bool` rather than a per-channel set of pinned ids.** It
    /// costs nothing — it lands in the padding after `flags` — where a set
    /// would be a second table to keep in step with the transcript, and the
    /// pin state has to be right on a message the pins pane has never fetched.
    /// Discord sends it on every message object, on history and on the socket.
    public var isPinned: Bool
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
        isPinned: Bool = false,
        payload: MessagePayload? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.authorID = authorID
        self.content = content
        self.editedAt = editedAt
        self.kind = kind
        self.flags = flags
        self.isPinned = isPinned
        self.payload = payload
    }

    /// The result of a poll that has ended, for a `POLL_RESULT` message.
    ///
    /// Nil for everything else, which is nearly every message — and nil for a
    /// `POLL_RESULT` whose embed Discord shaped differently, which draws the
    /// plain sentence rather than a claim the wire did not make.
    public var pollResult: PollResult? {
        guard kind == .pollResult,
              let embed = embeds.first(where: { $0.kind == "poll_result" }) ?? embeds.first
        else { return nil }
        func field(_ name: String) -> String? {
            embed.fields.first { $0.name == name }?.value
        }
        guard let question = field("poll_question_text") else { return nil }
        let emojiName = field("victor_answer_emoji_name")
        let emojiID = field("victor_answer_emoji_id").flatMap(UInt64.init).map(EmojiID.init(rawValue:))
        return PollResult(
            question: question,
            winner: field("victor_answer_text"),
            winnerEmoji: emojiName.map {
                EmojiRef(
                    id: emojiID,
                    name: $0,
                    isAnimated: field("victor_answer_emoji_animated") == "true"
                )
            },
            winnerVotes: field("victor_answer_votes").flatMap(Int.init) ?? 0,
            totalVotes: field("total_votes").flatMap(Int.init) ?? 0
        )
    }

    /// The embeds a transcript should draw.
    ///
    /// Everything but a poll result's, whose fields the row's own sentence
    /// already says — drawn as an ordinary card it is a grey box listing
    /// `victor_answer_id` at somebody.
    public var drawableEmbeds: [Embed] {
        guard kind == .pollResult else { return embeds }
        return embeds.filter { $0.kind != "poll_result" }
    }

    public var attachments: [Attachment] { payload?.attachments ?? [] }
    public var embeds: [Embed] { payload?.embeds ?? [] }
    public var components: [ActionRow] { payload?.components ?? [] }
    /// The application to name when a button on this message is pressed.
    ///
    /// **`application_id` where Discord sent it, the author otherwise.** A bot
    /// user's id *is* its application id for every app registered since 2016,
    /// and the capture's two values agree — `slash help.har` presses a button on
    /// a message whose author is `949479338275913799` and posts an interaction
    /// naming `949479338275913799`. The field is preferred anyway because it is
    /// Discord's own answer rather than an identity this client is assuming.
    public var componentApplicationID: ApplicationID {
        payload?.applicationID ?? ApplicationID(rawValue: authorID.rawValue)
    }
    /// The live action button carrying this `custom_id`, if the message still
    /// has one.
    ///
    /// **Searched at press time, not carried from the draw.** A pager edits
    /// itself and the buttons on it change — the capture's Next goes dead on
    /// page 6 — so a click has to be checked against the message as it is now
    /// rather than against the slot that was laid out before the last edit.
    /// Both component paths are walked: an ordinary action row, and the
    /// Components V2 tree, where the pager in the capture actually lives.
    public func pressableComponent(customID: String) -> MessageComponent? {
        for row in components {
            for control in row.components where control.customID == customID {
                return control
            }
        }
        return DisplayComponent.firstControl(in: displayComponents) { $0.customID == customID }
    }

    /// Whether only the reader can see this message.
    ///
    /// An ephemeral message is delivered over the socket to the one session that
    /// caused it and exists nowhere else — it is not in history, and reopening
    /// the channel loses it. Saying so is the whole point of the note Discord
    /// draws under it.
    public var isEphemeral: Bool { flags.contains(.ephemeral) }
    public var displayComponents: [DisplayComponent] { payload?.displayComponents ?? [] }
    public var poll: Poll? { payload?.poll }
    public var stickers: [StickerRef] { payload?.stickers ?? [] }
    public var reactions: [Reaction] { payload?.reactions ?? [] }
    /// The thread started from this message. Nil for everything else.
    public var thread: MessageThread? { payload?.thread }
    /// What a reply quotes. Nil for everything else.
    public var reference: MessageReference? { payload?.reference }
    public var referencedMessageID: MessageID? { payload?.reference?.messageID }
    /// The message this one carries, when it is a forward.
    public var forwarded: ForwardedMessage? { payload?.forwarded }
    public var mentionedUserIDs: [UserID] { payload?.mentionedUserIDs ?? [] }
    public var mentionsEveryone: Bool { payload?.mentionsEveryone ?? false }
    public var webhookID: UserID? { payload?.webhookID }
    /// The activity an app launched into this channel. Nil for everything else.
    public var activityInvite: ActivityInvite? { payload?.activityInvite }
    /// Who invoked the command this message answers. Nil for everything a
    /// person typed.
    public var interaction: MessageInteraction? { payload?.interaction }

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
    ///
    /// **An activity invitation counts, and it is the only body it has.** The
    /// captured launch message carries no content, no embed, no component and
    /// no attachment — the card is drawn entirely from `activityInvite` — so a
    /// check that omitted it would call the one thing on the row nothing.
    public var isEmpty: Bool {
        content.isEmpty && attachments.isEmpty && embeds.isEmpty
            && stickers.isEmpty && components.isEmpty && displayComponents.isEmpty
            && poll == nil && !isComponentsOnly && activityInvite == nil
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
    /// The controls an app attached. Empty for everything a person typed, which
    /// is the overwhelming majority — the array costs a word on a box that only
    /// exists for messages that are already unusual.
    public let components: [ActionRow]
    /// The Components V2 tree, when the message is built out of one. Empty for
    /// everything else, which is nearly everything.
    public let displayComponents: [DisplayComponent]
    /// The poll, when there is one. A message carrying one has no body at all.
    public let poll: Poll?
    public let mentionedUserIDs: [UserID]
    public let mentionedRoleIDs: [RoleID]
    public let mentionsEveryone: Bool
    /// What a reply quotes: the target, and enough of it to draw the header
    /// above this message without a second fetch.
    public let reference: MessageReference?
    /// What a forward carries. Discord sends the whole quoted message as a
    /// *snapshot* rather than a pointer, deliberately — the original may be
    /// somewhere the reader cannot reach, and a forward has to render anyway.
    public let forwarded: ForwardedMessage?
    /// A webhook's author id belongs to no account. Kept distinct from
    /// `isBot` because webhooks set that too, and the difference decides whether
    /// asking the gateway for the author is a request that can ever be answered.
    public let webhookID: UserID?
    /// The nonce a pending send was posted with, so the echo can be matched to
    /// the optimistic row and replace it rather than duplicating it.
    public let nonce: String?
    /// The invitation card an activity launch leaves behind. Nil for every
    /// message a person wrote, which is why it is here rather than on `Message`.
    public let activityInvite: ActivityInvite?
    /// Who invoked the command this message answers, and what it was called.
    ///
    /// **Not activity-specific.** An activity launch and a slash command are
    /// the same thing on the wire — an interaction — and both draw the same
    /// "somebody used *name*" line above the reply. Keeping it general is what
    /// lets the second one arrive without a second header.
    public let interaction: MessageInteraction?
    /// The application that owns this message's controls.
    ///
    /// **Only on an interaction response or an application-owned webhook**,
    /// which is exactly where a pressable button lives. Pressing one names the
    /// application, and `Message.componentApplicationID` is what falls back to
    /// the author when Discord did not send this — a bot user's id *is* its
    /// application id for every app registered since 2016, and the capture's
    /// two values agree.
    public let applicationID: ApplicationID?
    /// The thread started from this message, when there is one. Nil for
    /// everything else, which is nearly every message.
    public let thread: MessageThread?

    public init(
        attachments: [Attachment] = [],
        embeds: [Embed] = [],
        reactions: [Reaction] = [],
        stickers: [StickerRef] = [],
        components: [ActionRow] = [],
        displayComponents: [DisplayComponent] = [],
        poll: Poll? = nil,
        mentionedUserIDs: [UserID] = [],
        mentionedRoleIDs: [RoleID] = [],
        mentionsEveryone: Bool = false,
        reference: MessageReference? = nil,
        forwarded: ForwardedMessage? = nil,
        webhookID: UserID? = nil,
        nonce: String? = nil,
        activityInvite: ActivityInvite? = nil,
        interaction: MessageInteraction? = nil,
        applicationID: ApplicationID? = nil,
        thread: MessageThread? = nil
    ) {
        self.activityInvite = activityInvite
        self.interaction = interaction
        self.applicationID = applicationID
        self.attachments = attachments
        self.embeds = embeds
        self.reactions = reactions
        self.stickers = stickers
        self.components = components
        self.displayComponents = displayComponents
        self.poll = poll
        self.mentionedUserIDs = mentionedUserIDs
        self.mentionedRoleIDs = mentionedRoleIDs
        self.mentionsEveryone = mentionsEveryone
        self.reference = reference
        self.forwarded = forwarded
        self.webhookID = webhookID
        self.nonce = nonce
        self.thread = thread
    }

    /// The same box with one array replaced.
    ///
    /// **A copy helper rather than the constructor written out at each call
    /// site.** The properties here are `let` so a shared box can never be
    /// mutated out from under another holder, which means every change is a
    /// full re-construction — and a re-construction written by hand is a
    /// re-construction that silently drops whatever field was added last. Both
    /// call sites in the app had done exactly that: a reaction arriving on a
    /// message with a poll rebuilt the box without the poll, and the tally
    /// vanished on the next thumbs-up.
    public func replacingReactions(_ reactions: [Reaction]) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread
        )
    }

    /// The same box with a different poll. See `replacingReactions`.
    public func replacingPoll(_ poll: Poll?) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread
        )
    }

    /// Whether the box is worth allocating. A decoder that builds one of these
    /// for every plain message has undone the point of the type.
    public var isEmpty: Bool {
        attachments.isEmpty && embeds.isEmpty && reactions.isEmpty
            && stickers.isEmpty && components.isEmpty && displayComponents.isEmpty
            && poll == nil && mentionedUserIDs.isEmpty
            && mentionedRoleIDs.isEmpty && !mentionsEveryone
            && reference == nil && forwarded == nil && webhookID == nil && nonce == nil
            && activityInvite == nil && interaction == nil && thread == nil
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
                && lhs.components == rhs.components
                && lhs.displayComponents == rhs.displayComponents
                && lhs.poll == rhs.poll
                && lhs.mentionedUserIDs == rhs.mentionedUserIDs
                && lhs.mentionedRoleIDs == rhs.mentionedRoleIDs
                && lhs.mentionsEveryone == rhs.mentionsEveryone
                && lhs.reference == rhs.reference
                && lhs.forwarded == rhs.forwarded
                && lhs.webhookID == rhs.webhookID
                && lhs.activityInvite == rhs.activityInvite
                && lhs.interaction == rhs.interaction
                && lhs.thread == rhs.thread)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(attachments.count)
        hasher.combine(embeds.count)
        hasher.combine(reactions.count)
        hasher.combine(reference?.messageID)
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
    /// A poll that has ended. **Its words are in an embed, not in `content`** —
    /// see `Message.pollResult` — so a renderer that only knows about content
    /// draws an author line over a blank row, which is what a closed poll looked
    /// like in this app.
    case pollResult = 46
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
        case 46: .pollResult
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

/// The thread hanging off a message, as its chip needs it.
///
/// **Captured**, `threads.har`: `GET /channels/{id}/messages` returns a whole
/// nested channel object under `thread` on any message that started one — name,
/// `message_count`, `thread_metadata` and all. So the chip needs no second
/// fetch and no active-threads sweep; the transcript already has everything it
/// draws.
///
/// A summary rather than the `Channel` itself: the chip needs three fields, and
/// the full channel goes into `ChannelIndex` on the same page so that opening it
/// resolves. Holding a second copy here is how the chip and the panel come to
/// disagree about the thread's name.
public struct MessageThread: Hashable, Sendable, Codable {
    public var id: ChannelID
    public var name: String
    /// What the chip says. `total_message_sent` where Discord sends it, because
    /// it never decrements — see `Channel.threadMessageCount`.
    public var messageCount: Int
    public var isArchived: Bool

    public init(id: ChannelID, name: String, messageCount: Int, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.messageCount = messageCount
        self.isArchived = isArchived
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

    /// What a picker types into the composer.
    ///
    /// A custom emoji goes out as Discord's inline form — `<:name:id>`, with the
    /// `a` prefix when it is animated — which every other client unfurls back
    /// into the picture. A Unicode one is just itself.
    public var messageToken: String {
        guard let id else { return name }
        return "<\(isAnimated ? "a" : ""):\(name):\(id.rawValue)>"
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

        /// Whether the picture moves.
        ///
        /// All three moving formats end up as the same filmstrip: APNG and GIF
        /// through `CGImageSource`, Lottie through the rasteriser. **Lottie has
        /// no bitmap on the CDN at all** — measured, both its `.png` and `.gif`
        /// endpoints answer 404 — so it has no still to fall back on and its
        /// cell is empty until the strip lands.
        public var isAnimated: Bool { self != .png }
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

/// What a reply quotes.
///
/// **A snapshot, not a pointer.** The target may be a thousand messages above
/// what is loaded, in a channel that has been evicted, or deleted outright — and
/// the header above the reply still has to draw. Discord sends the whole
/// referenced message inline for exactly this reason, and everything the header
/// needs is flattened here at decode: the author's id, one line of text, and
/// whether there was a picture instead of words.
///
/// Flattening at decode rather than at layout is deliberate. The header is drawn
/// by a canvas that runs off the main actor and cannot reach the store, and
/// folding a markdown tree into a line per row per frame is the cost
/// `MarkdownDocument.plainText` exists to pay once.
public struct MessageReference: Hashable, Sendable, Codable {
    public var messageID: MessageID?
    public var channelID: ChannelID?
    /// Nil when the reference arrived with no message behind it — deleted, or
    /// out of reach. The header then says so rather than drawing a blank quote.
    public var authorID: UserID?
    public var isAuthorBot: Bool
    /// The quoted line, already flattened.
    public var excerpt: String
    /// Whether the quoted message was a picture or a file rather than words.
    public var hasAttachment: Bool

    public init(
        messageID: MessageID? = nil,
        channelID: ChannelID? = nil,
        authorID: UserID? = nil,
        isAuthorBot: Bool = false,
        excerpt: String = "",
        hasAttachment: Bool = false
    ) {
        self.messageID = messageID
        self.channelID = channelID
        self.authorID = authorID
        self.isAuthorBot = isAuthorBot
        self.excerpt = excerpt
        self.hasAttachment = hasAttachment
    }

    /// Whether Discord sent a reference with nothing behind it.
    public var isUnavailable: Bool { authorID == nil }

    /// One line of a quoted body: markdown folded, newlines collapsed, and cut
    /// well past anything a header can show.
    ///
    /// **Folded once, at decode.** The header is drawn by a canvas that runs off
    /// the main actor and cannot reach a parser cache; doing this per row per
    /// frame is the cost `MarkdownDocument.plainText` exists to pay once.
    ///
    /// The cut is a *character* bound rather than a measured width, because this
    /// runs with no font in hand. The painter truncates to the real width; this
    /// only stops a ten-kilobyte code block being carried around in every copy
    /// of the message that quotes it.
    public static func excerpt(of content: String) -> String {
        guard !content.isEmpty else { return "" }
        let plain = MarkdownParser().parse(content).plainText
        var line = ""
        line.reserveCapacity(min(plain.count, excerptLimit))
        var wasSpace = false
        for character in plain {
            if character.isNewline || character == "\t" || character == " " {
                wasSpace = true
                continue
            }
            if wasSpace, !line.isEmpty { line.append(" ") }
            wasSpace = false
            line.append(character)
            if line.count >= excerptLimit { break }
        }
        return line
    }

    private static let excerptLimit = 180
}

/// The message a forward carries.
///
/// **A copy, and Discord means it as one.** A forward's snapshot has no author:
/// the whole point of the shape is that the original's identity does not travel
/// with it. A client that invents one — from the reference's channel, from the
/// forwarder — is asserting something the payload deliberately does not say.
/// What a closed poll says about itself.
///
/// **Read out of an embed, because that is where Discord puts it.** A
/// `POLL_RESULT` message has empty content and one embed of kind `poll_result`
/// whose *fields* carry the question, the winning answer and the counts. They
/// are fields rather than a payload, so the names below are the wire's and a
/// typo in one is a nil rather than a failure.
public struct PollResult: Hashable, Sendable {
    public var question: String
    /// The answer that won, when anybody voted.
    public var winner: String?
    public var winnerEmoji: EmojiRef?
    public var winnerVotes: Int
    public var totalVotes: Int

    /// The winner's share, 0...1. Zero when nobody voted, which is a real state:
    /// a poll can close with no votes at all.
    public var share: Double {
        guard totalVotes > 0 else { return 0 }
        return Double(winnerVotes) / Double(totalVotes)
    }
}

public struct ForwardedMessage: Hashable, Sendable, Codable {
    public var content: String
    /// **The snapshot's own attachments, not a count of them.** Discord sends
    /// the whole forwarded message under `message_snapshots` — content,
    /// attachments and embeds — and a client that kept only a number has
    /// nothing to draw: a forwarded photograph renders as an author line over
    /// empty space, which is what a forward looked like in this app.
    public var attachments: [Attachment]
    public var embeds: [Embed]
    /// Where it was forwarded from, when the reference named it. Only ever used
    /// to say "from #channel"; never to attribute the message to anybody.
    public var channelID: ChannelID?

    public var attachmentCount: Int { attachments.count }
    public var hasEmbed: Bool { !embeds.isEmpty }

    /// Whether there is anything at all inside the quote. A forward with an
    /// empty snapshot is a real state — a message that has since been deleted —
    /// and the block still draws its label rather than a bare rule.
    public var isEmpty: Bool {
        content.isEmpty && attachments.isEmpty && embeds.isEmpty
    }

    public init(
        content: String,
        attachments: [Attachment] = [],
        embeds: [Embed] = [],
        channelID: ChannelID? = nil
    ) {
        self.content = content
        self.attachments = attachments
        self.embeds = embeds
        self.channelID = channelID
    }
}

extension EmojiRef {
    /// Reads `messageToken` back into a reference.
    ///
    /// The inverse of `messageToken`, and it exists because the expression
    /// picker speaks in tokens — a pick is "what to type into a draft" — while
    /// a reaction is addressed by name and id. Parsing the token back is one
    /// scan of at most a few dozen bytes; the alternative is a second field on
    /// every one of the two thousand items the picker builds.
    ///
    /// **Split by hand, not by a regex.** A Swift regex literal is re-parsed on
    /// every call — `INVARIANTS.md` §2 — and this runs on a pick.
    public init?(messageToken token: String) {
        guard token.hasPrefix("<"), token.hasSuffix(">") else {
            guard !token.isEmpty else { return nil }
            self.init(name: token)
            return
        }
        let body = token.dropFirst().dropLast()
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        // `a:name:id` when animated, `:name:id` when not — the leading field is
        // empty for a still emoji, which is why empty subsequences are kept.
        guard parts.count == 3, let id = EmojiID(parts[2]), !parts[1].isEmpty else {
            return nil
        }
        self.init(id: id, name: String(parts[1]), isAnimated: parts[0] == "a")
    }
}


/// The command a message is answering, and who ran it.
///
/// **One type for slash commands and activity launches alike.** Both are
/// interactions on the wire; the captured launch carries
/// `interaction_metadata: {id, type: 2, user, name: "launch", command_type: 4}`
/// beside a legacy `interaction` with the same name and user. The newer key is
/// preferred and the older one is the fallback — Discord has been removing the
/// latter, and a client reading only it loses the header when it goes.
public struct MessageInteraction: Hashable, Sendable, Codable {
    public var userID: UserID
    /// The command's name, drawn in the chip: `launch`, `ban`, `play`.
    public var name: String
    /// `1` chat input, `2` user, `3` message, `4` primary entry point. Kept raw
    /// so a kind this client has no name for still draws its header.
    public var commandType: Int

    public init(userID: UserID, name: String, commandType: Int) {
        self.userID = userID
        self.name = name
        self.commandType = commandType
    }
}
