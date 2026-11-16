import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// One row's geometry and everything the painter needs to draw it.
///
/// A value, so a row can be laid out on a background task and handed to the main
/// actor as a plain result. The one reference it holds — the text block — is
/// immutable and shared, which is what makes reusing a layout across a rows
/// change a pointer copy rather than a re-framesetting.
nonisolated struct TimelineRow: Sendable {
    var height: CGFloat
    var kind: Kind

    enum Kind: Sendable {
        case daySeparator(label: String)
        case unreadDivider
        case conversationStart(ConversationStartSlot)
        case skeleton(index: Int)
        /// A topic's or a summary's mark. Drawn from the title alone: one
        /// line, cut to the row, with nothing in it that a layout pass has to
        /// measure.
        case marker(TimelineMark.Kind, title: String)
        case loadingFirstPage
        case historyUnavailable(reason: String)
        case message(MessageRow)
        /// A fold's own line — see `CollapsedGroupSlot`.
        case collapsedGroup(CollapsedGroupSlot)
        /// A forum post's bar under its opening message — see
        /// `PostActionsSlot`.
        case postActions(PostActionsSlot)
    }

    var messageID: MessageID? {
        if case .message(let row) = kind { return row.id }
        return nil
    }

    var isSelectable: Bool {
        if case .message = kind { return true }
        return false
    }
}

extension MessageRow {
    /// Where this row's "(edited)" landed, in row space, whichever of its two
    /// places that is, and when the message changed — what its tooltip says.
    var editedMark: (rect: CGRect, editedAt: Date)? {
        if let foot = editedFoot {
            return (CGRect(origin: foot.origin, size: foot.block.size), foot.editedAt)
        }
        guard let block = textBlock, let mark = block.text.editedMark, let rect = block.editedMarkRect else {
            return nil
        }
        return (rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y), mark.editedAt)
    }
}

/// "(edited)" under a message's accessories, where it has no words to follow.
nonisolated struct EditedFootSlot: @unchecked Sendable {
    var block: TimelineTextBlock
    var origin: CGPoint
    var editedAt: Date
}

/// A message row, laid out.
/// Where a DM system line names somebody, and what lights it.
///
/// **Discord's `447215`**: a system line sets the name in its owner's face
/// everywhere, and in a private channel only it draws the whole style —
/// `PLAIN` at rest, `ANIMATED` and looping while the line is under the pointer.
/// So the line keeps its sentence as laid out, and the hovered paint swaps in
/// a copy with the name in clear ink and draws the effect over the gap.
///
/// Only for a name on one line: an effect is one run of outlines, and a name a
/// narrow column breaks in two keeps its face and goes without.
nonisolated struct SystemNameSlot: @unchecked Sendable {
    var style: DisplayNameStyle
    var name: String
    /// The face at the line's size, and its kern at that size.
    var face: NSFont
    var tracking: CGFloat
    /// The name's top-left in the row — its baseline less the face's ascender,
    /// the point `DisplayNameEffectPainter` draws from.
    var origin: CGPoint
    var width: CGFloat
    /// The same sentence, the name in clear ink, laid out identically.
    var unnamedBlock: TimelineTextBlock
}

nonisolated struct MessageRow: @unchecked Sendable {
    var id: MessageID
    var authorID: UserID
    /// Whether the row draws its author's name — a run's first message, and in
    /// bubbles only somebody else's in a conversation that names them. Every
    /// reader of the name asks this, so a row with no name line has no name to
    /// hover, click or light either.
    var hasAuthorLine: Bool
    var mentionsMe: Bool
    var isPending: Bool
    var isFailed: Bool
    /// The message is in a fold the reader opened, and sits on its tint —
    /// Discord's `expanded`. Painted, so carried over from the cache like
    /// `isPending` rather than keyed on.
    var isInOpenFold = false

    /// Present only on a run head — or, in bubbles, on the last message of
    /// somebody's run, beside its last bubble. Everything else leaves the
    /// gutter empty and reveals a compact timestamp there on hover.
    var avatarRect: CGRect?
    var avatarURL: URL?
    var avatarMonogram: String
    var decorationURL: URL?

    /// The quoted line above a reply. Nil for everything else, which is nearly
    /// every message — so it costs one optional word on a row that already has
    /// a dozen.
    var replyHeader: ReplyHeaderSlot?
    /// The "somebody used *command*" line, when the message answers one.
    var interactionHeader: InteractionHeaderSlot?
    /// "Only you can see this", under an ephemeral message. Nil for every
    /// message anybody else can read, which is nearly all of them.
    var ephemeralNote: EphemeralNoteSlot?

    var authorName: String
    /// The styled face and tracking the name was measured in, carried so the
    /// painter draws in the same one.
    var authorFace: NSFont?
    var authorTracking: CGFloat = 0
    /// The author's role gradient, painted through the name under the
    /// pointer — the member list's own behaviour, in the transcript.
    var authorGradient: [NSColor]?
    /// The effect and colours this name is lit with under the pointer.
    ///
    /// **Carried even though only the hovered row ever paints it**, because the
    /// layout is cached and the pointer is not: resolving it at hover time
    /// would mean re-laying out a row to answer a mouse move.
    var authorStyle: DisplayNameStyle?
    var authorColor: NSColor?
    var authorRect: CGRect
    var timestampText: String
    var timestampRect: CGRect
    /// The compact `HH:mm` shown in the gutter on hover, for a continuation row.
    var gutterTimestampText: String

    /// Discord's tag beside the name — OFFICIAL, SERVER, APP or OP. See
    /// `AuthorTag`.
    var authorTag: AuthorTag?
    /// A crosspost, whose author is the channel that published it: its name
    /// opens that server's card rather than a person's.
    var isCrosspost = false

    /// The server tag worn beside the name, and where it sits.
    ///
    /// **Reserved at layout time, like the bot badge**, because the timestamp
    /// is placed after it — a chip measured inside the painter would draw over
    /// the time or leave a hole where it should be.
    var tag: String?
    var tagBadgeURL: URL?
    var tagRect: CGRect = .zero

    /// The role icon worn after the name, and its box.
    ///
    /// **Reserved at layout time like the tag chip**, because the timestamp is
    /// placed after it — an icon measured inside the painter would draw over
    /// the time or leave a hole where it should be.
    var roleIconURL: URL?
    var roleEmoji: String?
    var roleIconRect: CGRect = .zero

    /// The message this one forwards, quoted. Nil for everything else, which is
    /// nearly every message.
    var forwarded: ForwardedSlot?

    /// Laid-out body text. Nil for a message with no textual content.
    var textBlock: TimelineTextBlock?
    var textOrigin: CGPoint
    /// The "(edited)" of a message with no words to set it after.
    var editedFoot: EditedFootSlot? = nil

    var attachments: [AttachmentSlot]
    /// A send's files going up, drawn in place of the attachments they are
    /// about to be — see `UploadCardSlot`. Nil for every message Discord has.
    var upload: UploadCardSlot? = nil
    /// A message request's media, counted and not drawn — see
    /// `HiddenMediaSlot`. Nil everywhere but a request's preview.
    var hiddenMedia: HiddenMediaSlot? = nil
    var stickers: [StickerSlot]
    var embeds: [EmbedSlot]
    /// The controls an app attached, laid out into rows.
    var components: [ComponentSlot]
    /// The poll, when the message is one.
    var poll: PollSlot?
    /// The activity invitation, when the message is one. Like a poll, this IS
    /// the message — the launch carries no body at all.
    var activityInvite: ActivityInviteSlot?
    /// An invitation to listen along on the author's Spotify — the whole
    /// message, as a poll is. See `ListenAlongSlot`.
    var listenAlong: ListenAlongSlot? = nil
    /// A custom theme the message shares — Discord's theme card.
    var sharedTheme: SharedThemeCardSlot? = nil
    /// The invites the text links to, drawn as Discord's invite cards.
    var inviteCards: [InviteCardSlot] = []
    /// The profiles the text links to — Discord's user profile embed. Hosted
    /// over the canvas, not drawn by it; see `HostedCardSlot`.
    var hostedCards: [HostedCardSlot] = []
    var reactions: [ReactionSlot]
    /// Add-a-reaction and bookmark, at the end of the reaction row.
    ///
    /// Empty where the message carries no reaction: the row exists because
    /// there is something on it, and two controls floating under a message
    /// nobody has reacted to is chrome the hover bar already offers.
    var reactionControls: [ReactionControlSlot] = []
    /// A card drawn from parts — AutoMod's alert or notice, which is the
    /// whole row, or a safety notice under a system message's words. See
    /// `DrawnCard`.
    var card: DrawnCard? = nil
    /// The thread this message started, when it did.
    var threadChip: ThreadChipSlot?

    /// A system event's gutter glyph — a join, a boost, a pin.
    ///
    /// **A field on the ordinary row rather than a row kind of its own.** A
    /// system message is still a message: it has an id, an author, a timestamp,
    /// reactions and a place in the layout cache, and the only things that
    /// differ are that the gutter holds a symbol instead of a face and the
    /// sentence is composed rather than typed. A separate kind would duplicate
    /// the cache key, the height calculation and the hit testing to change two
    /// of them.
    var systemSymbol: String?
    var systemTint: NSColor?
    /// A DM system line's name, to be lit under the pointer — see
    /// `SystemNameSlot`. Nil in a server, and for anybody without a style.
    var systemName: SystemNameSlot? = nil

    /// Where the row sits in the bubble arrangement. Nil in Discord's columns,
    /// and on a system line, which is centred rather than on a side.
    var bubbles: BubbleRow? = nil

    /// One plain string for one accessibility node.
    ///
    /// **This is the whole accessibility surface of a message row, deliberately.**
    /// Letting the platform derive a label from styled text carrying link
    /// attributes makes it re-resolve every run into attributes on every render —
    /// reaching localized bundle string tables to answer what font a run is in,
    /// per run, per frame — and that happens whether or not anyone is using
    /// VoiceOver, because on a real Mac something always holds the accessibility
    /// API open.
    var accessibilityLabel: String
}

/// A fold's line — Discord's `blockedSystemMessage`, on its system-message
/// frame: the fold's glyph where a system message's sits, the sentence in the
/// reading ink, then " — Show" or " — Hide" with the one word quieter until the
/// row is hovered.
///
/// **Only the word takes a click**, as only Discord's anchor does: the rest of
/// the line is a statement, and a line that opened wherever it was clicked
/// would open under a drag meant to select the message above it.
nonisolated struct CollapsedGroupSlot: Sendable {
    var group: CollapsedGroup
    var symbolName: String
    /// The sentence and the dash after it, in the reading ink — or, for a fold
    /// that cannot open, the whole line in the quiet one.
    var text: TimelineTextBlock
    var textOrigin: CGPoint
    /// "Show" or "Hide", where it is drawn in row space, and the word laid out
    /// twice: in the quiet ink, and in the link's for a hovered row — Discord's
    /// `blockedAction` and its `:hover`. Two blocks rather than one recoloured
    /// at paint time, which would be a framesetting pass per hover. Nil for a
    /// fold that cannot open.
    var action: Action?
    var accessibilityLabel: String

    struct Action: Sendable {
        var word: String
        var rect: CGRect
        var quiet: TimelineTextBlock
        var lit: TimelineTextBlock
    }

    /// Discord's words for the fold, by its count — `+FcYM/`, `VFWjc+` and
    /// `rHRovo`, whose ICU plurals these are.
    static func sentence(for group: CollapsedGroup) -> String {
        let count = group.count
        switch group.reason {
        case .blocked: return count == 1 ? "1 blocked message" : "\(count) blocked messages"
        case .ignored: return count == 1 ? "1 ignored message" : "\(count) ignored messages"
        case .suspended:
            return count == 1
                ? "One message removed from a suspended account."
                : "Some messages removed from a suspended account."
        }
    }

    /// The fold's glyph: Discord's block mark, its eye with a slash, and its
    /// suspended person, in the system's own symbols.
    static func symbolName(for reason: CollapsedGroup.Reason) -> String {
        switch reason {
        case .blocked: "nosign"
        case .ignored: "eye.slash"
        case .suspended: "person.crop.circle.badge.xmark"
        }
    }
}

/// A forwarded message, quoted inside the one that carries it.
///
/// **The snapshot is drawn, not summarised.** Discord sends the whole forwarded
/// message — its words, its files and its embeds — and a renderer that knew only
/// that a forward existed drew an author line over empty space. That is what
/// every forwarded message looked like in this app, in the transcript and in the
/// pinned pane alike.
///
/// Laid out as a quote: one rule down the leading edge, a label saying what the
/// block is, then the snapshot's own content indented behind the rule. The
/// contents are ordinary slots — the same text block, attachment slots and embed
/// slots the message itself uses — so anything the transcript can draw, a
/// forward can carry.
nonisolated struct ForwardedSlot: Sendable {
    /// The whole block, so the row height and the rule both come from one rect.
    var rect: CGRect
    /// The leading rule.
    var ruleRect: CGRect
    /// The arrow beside the label.
    var glyphRect: CGRect
    var label: TimelineTextBlock
    var labelOrigin: CGPoint
    var body: TimelineTextBlock?
    var bodyOrigin: CGPoint
    var attachments: [AttachmentSlot]
    var embeds: [EmbedSlot]
    /// The snapshot's stickers, drawn as the message's own are.
    var stickers: [StickerSlot] = []
    /// Discord's breadcrumb: "#general  •  Today at 13:15 ›", or the server's
    /// name with its icon when the original is in another server. Nil where
    /// the reader cannot see where it came from — inventing a name for a
    /// channel the reader has no access to is a claim the client cannot make.
    var footer: TimelineTextBlock?
    var footerOrigin: CGPoint
    /// The whole breadcrumb, icon and chevron included: what a click jumps
    /// to the original from. Zero without a footer.
    var footerRect: CGRect = .zero
    /// The server's icon before its name, for an original in another server.
    var footerIconURL: URL?
    var footerIconRect: CGRect = .zero
    /// The chevron after the time.
    var footerChevronRect: CGRect = .zero
    /// Where the breadcrumb goes — nil when there is nowhere to go.
    var jump: ForwardJump?
    /// **Whether the body is the row's own text** (`MessageRow.textBlock`).
    /// A forward with no words of its own around it hands its text to the row,
    /// so selecting, copying, links, mentions, emoji and spoilers in it all
    /// work as they do in any message — they used to stop at the quote's edge.
    /// The row draws it then, and this slot does not.
    var bodyIsRowText = false
}

/// Where a forward's breadcrumb goes: the original message.
nonisolated struct ForwardJump: Sendable, Equatable {
    var guildID: GuildID?
    var channelID: ChannelID
    var messageID: MessageID
}

/// What a forum post's bar needs to know — Discord's `rg`, under the opening
/// message: React to Post, Follow, and Copy Link.
nonisolated struct PostActions: Sendable, Equatable {
    /// The opening message, whose id is the post's own.
    var openerID: MessageID
    /// The opening message is gone, so the bar hangs under the post's head.
    var openerDeleted: Bool
    /// Following the post — "Following" with a tick, or "Follow" with a bell.
    var isFollowing: Bool
    /// Not while previewing the server: Discord offers no follow there.
    var offersFollow: Bool
    /// "React to Post", while the opening message has no reactions and the
    /// reader may add one.
    var offersReaction: Bool
    /// The link went to the clipboard a moment ago — "Copied", for two
    /// seconds, as Discord's says.
    var isLinkCopied: Bool
}

/// A forum post's bar, laid out.
nonisolated struct PostActionsSlot: Sendable {
    enum Action: Hashable, Sendable {
        case react
        case follow
        case copyLink
    }

    struct Button: Sendable {
        var action: Action
        var rect: CGRect
        var symbolName: String
        var glyphRect: CGRect
        /// Nil for Copy Link at rest — Discord's is a bare icon until it has
        /// copied.
        var label: TimelineTextBlock?
        var labelOrigin: CGPoint
        /// Drawn in the accent: Following, and Copied.
        var isLit: Bool
        var accessibilityLabel: String
    }

    var buttons: [Button]
}

/// Which of Discord's heads a transcript opens with (`aE`).
nonisolated enum ChannelHead: Sendable, Equatable {
    /// "Welcome to #channel!" — `sM`.
    case channel
    /// A thread's name, "Started by" its author, and for a private thread how
    /// to bring people in — `sL`. A nil name is an author nobody has told this
    /// client about, which Discord draws as "???".
    case thread(startedBy: String?, isPrivate: Bool)
    /// A forum post's title, its tags, and "Original message was deleted"
    /// when it is — `iX`.
    case post(tags: [ForumTag], openerDeleted: Bool)
    /// A direct message — Discord's `sc` with a person: their face, their
    /// names, the sentence, the servers in common, and what can be done.
    case directMessage(DirectMessageHead)
    /// A group — its picture, its name, and "Welcome to the beginning of the
    /// **{name}** group."
    case groupDirectMessage(iconURL: URL?)
    /// Discord's own system messages, under its face.
    case systemDirectMessage(avatarURL: URL?)
}

nonisolated extension ChannelHead {
    /// The controls under the head: a person's, an app's, or a group's.
    var actions: [HeadAction] {
        switch self {
        case .directMessage(let head): head.actions
        case .groupDirectMessage: [.inviteToGroup, .editGroup]
        default: []
        }
    }
}

/// What Discord's head of a direct message shows about the other person.
nonisolated struct DirectMessageHead: Sendable, Equatable {
    var avatarURL: URL?
    var monogram: String
    /// The username under the name, Discord's second heading. Nil where it
    /// would only repeat the name.
    var username: String?
    /// "{username} sent you a friend request." — an incoming request, answered
    /// right here.
    var incomingRequestFrom: String?
    /// The servers in common: up to three faces and the count. A count of
    /// none — or one nobody has asked for — reads "No servers in common", as
    /// Discord's does.
    var mutualIcons: [MutualMark]
    var mutualCount: Int
    var actions: [HeadAction]

    nonisolated struct MutualMark: Sendable, Equatable {
        var iconURL: URL?
        var monogram: String
    }
}

/// A control in a direct message's head (`au`, `ad`, `at`).
nonisolated enum HeadAction: Hashable, Sendable {
    case addFriend
    /// "Friend Request Sent" — Discord's disabled primary.
    case friendRequestSent
    case acceptRequest
    case ignoreRequest
    case removeFriend
    case block
    case unblock
    /// The servers-in-common line, which opens them.
    case mutualServers
    /// An app's DM, with a grant the reader holds (`s7`'s `sq` and `s$`).
    case mute
    case unmute
    case deauthorize
    /// The app's first message, through Discord's first-DM report (`sW`).
    case reportSpam
    /// A group's two (`sr`).
    case inviteToGroup
    case editGroup

    var title: String {
        switch self {
        case .addFriend: "Add Friend"
        case .friendRequestSent: "Friend Request Sent"
        case .acceptRequest: "Accept Request"
        case .ignoreRequest: "Ignore Request"
        case .removeFriend: "Remove Friend"
        case .block: "Block"
        case .unblock: "Unblock"
        case .mutualServers: ""
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .deauthorize: "Deauthorize"
        case .reportSpam: "Report Spam"
        case .inviteToGroup: "Invite to Group DM"
        case .editGroup: "Edit Group"
        }
    }

    /// Discord's primary buttons; the rest are its secondary.
    var isProminent: Bool {
        self == .addFriend || self == .friendRequestSent || self == .acceptRequest || self == .inviteToGroup
    }

    /// Discord's `critical-primary`: Mute, and Report Spam.
    var isCritical: Bool { self == .mute || self == .reportSpam }

    var isEnabled: Bool { self != .friendRequestSent }
}

/// The head of a channel: an icon, a welcome, and what the channel is for.
///
/// **Laid out rather than drawn at fixed offsets.** The old version painted two
/// strings at `+30` and `+62` into a 120-point row, so a long channel name
/// truncated, a topic had nowhere to go, and the empty band underneath was the
/// "weird space" — a fixed height reserved for two lines that only ever used
/// half of it. Everything here is measured, and the row is as tall as what it
/// holds.
nonisolated struct ConversationStartSlot: Sendable {
    /// The icon tile.
    var iconRect: CGRect
    /// The channel's own symbol — `#`, a speaker, a megaphone, a thread.
    var symbolName: String
    /// Where the glyph sits inside the tile.
    var glyphRect: CGRect
    var title: TimelineTextBlock
    var titleOrigin: CGPoint
    /// "This is the start of…" for a channel, "Started by…" for a thread. A
    /// forum post has none: its title is the whole head.
    var subtitle: TimelineTextBlock?
    var subtitleOrigin: CGPoint
    /// A second line where Discord has one: how to bring people into a
    /// private thread, or that a post's opening message is gone.
    var note: TimelineTextBlock?
    var noteOrigin: CGPoint
    /// A forum post's tags, as chips under its title.
    var tags: [Tag]
    /// A person's or a group's picture in the tile's place, round.
    var avatarURL: URL?
    var avatarMonogram: String?
    /// The servers-in-common line of a direct message's head.
    var mutuals: Mutuals?
    /// A direct message's controls — Add Friend, Block and their kin.
    var buttons: [HeadButton]
    /// A conversation's head is a face in a circle; a channel's a tile.
    var isRound: Bool

    struct Mutuals: Sendable {
        var icons: [(mark: DirectMessageHead.MutualMark, rect: CGRect)]
        var label: TimelineTextBlock
        var labelOrigin: CGPoint
        /// The whole line, which opens the servers.
        var rect: CGRect
    }

    struct HeadButton: Sendable {
        var action: HeadAction
        var rect: CGRect
        var label: TimelineTextBlock
        var labelOrigin: CGPoint
    }

    /// The head's control under a point in the row's own space — an enabled
    /// button, or the servers-in-common line — and where its plate starts,
    /// which is how the hover is told which one to lift.
    func control(at point: CGPoint) -> (action: HeadAction, origin: CGPoint)? {
        if let button = buttons.first(where: { $0.action.isEnabled && $0.rect.contains(point) }) {
            return (button.action, button.rect.origin)
        }
        if let mutuals, mutuals.rect.contains(point) {
            return (.mutualServers, mutuals.rect.origin)
        }
        return nil
    }

    struct Tag: Sendable {
        var rect: CGRect
        var label: TimelineTextBlock
        var labelOrigin: CGPoint
    }
    /// The channel's topic, when it has one. Markdown, because people write it
    /// there — a topic rendered as a plain string shows `<:emoji:id>` and
    /// `**bold**` as literal characters.
    var topic: TimelineTextBlock?
    var topicOrigin: CGPoint
    /// Discord's Edit Channel button, for somebody who may manage the channel.
    var editButton: EditButton?

    struct EditButton: Sendable {
        var rect: CGRect
        var glyphRect: CGRect
        var label: TimelineTextBlock
        var labelOrigin: CGPoint
    }
}

/// What an upload's card says: its files' name or count, and their size.
///
/// Handed to the layout like the Spotify cards, keyed by the echo's id, because
/// the files are the session's and this type cannot reach it.
nonisolated struct UploadSummary: Equatable, Sendable {
    var title: String
    var size: Int
}

/// A send's files going up — Discord's pending upload (module `564771`).
///
/// **One card for the whole send**, as Discord's is: the file's mark, its name
/// or "Uploading 3 Files", how big it is, one bar, and a cancel. At the end of
/// the bar the cancel goes and the bar says "Processing...", until Discord's
/// message arrives in its place. The bar's fill is painted from the session's
/// progress, never laid out — it moves a hundred times an upload.
nonisolated struct UploadCardSlot: Sendable {
    var rect: CGRect
    /// The icon Discord draws for the title: one file's own, or — for
    /// "Uploading 3 Files" — the unknown one.
    var fileKind: AttachmentFileKind
    var title: String
    var titleOrigin: CGPoint
    var titleWidth: CGFloat
    /// "— 3.2 MB", after the name: Discord's `size`.
    var sizeLabel: String
    var sizeOrigin: CGPoint
    /// The bar's track; "Processing..." is set on its line once it is full.
    var progressRect: CGRect
    var cancelRect: CGRect
}

/// A message request's media, before it is accepted — Discord's restricted
/// preview (`d1`): a tile per piece reading "Image attachment", and one line
/// under them saying why.
nonisolated struct HiddenMediaSlot: Sendable {
    var rect: CGRect
    var tiles: [CGRect]
    var noteRect: CGRect
}

/// What a voice note sits on.
nonisolated enum VoiceNoteLook: Sendable {
    case capsule, bubble, accentBubble
}

/// A voice note, laid out: `(▶) bars 0:12 [1×]`.
///
/// **The values are worked out once, here.** A note's waveform is base64 on the wire,
/// and decoding it per repaint would be work inside a draw that runs sixty times a
/// second while it plays. Rects are in the row's space, as every other slot's are.
nonisolated struct VoiceNoteSlot: Sendable {
    var attachmentID: AttachmentID
    var source: URL?
    var duration: Double
    /// One value per bar, as drawn. See `VoiceWaveform.displayed`.
    var bars: [Float]
    var disc: CGRect
    var barsRect: CGRect
    var timeRect: CGRect
    var pill: CGRect
    /// **In a bubble, the bubble is its ground.** A capsule of its own in there is one
    /// plate on another, for no reason a reader could name.
    var isBare = false
    /// On an accent bubble, where the accent can't say which bars have been played.
    var isOnAccent = false

    /// What a press on the bars means: how far through the note.
    func fraction(atX x: CGFloat) -> Double {
        guard barsRect.width > 0 else { return 0 }
        return Double(max(0, min(1, (x - barsRect.minX) / barsRect.width)))
    }
}

nonisolated struct AttachmentSlot: Sendable {
    var rect: CGRect
    var url: URL?
    var isSpoiler: Bool
    var altText: String?
    /// The pixel width the image should be decoded at.
    var decodeWidth: CGFloat
    /// What the painter draws, decided at layout time.
    ///
    /// **Four kinds, not a Bool.** A picture, a clip with a poster, a voice note
    /// and a zip file are four different rectangles with four different
    /// contents, and resolving that inside `draw` puts the decision in every
    /// repaint of every row — the same rule `EmbedLayoutEngine` follows.
    var kind: Kind = .image
    /// Whether the picture fills its box and is cropped, or keeps its own
    /// shape.
    ///
    /// **True for every cell of a mosaic and false for a lone picture.** A grid
    /// row is only flush if its cells are a fixed size, and a fixed cell can
    /// only hold a picture of another shape by cropping it. Decided here rather
    /// than inferred in `draw` from whether the rect's ratio happens to match
    /// the image's — that comparison is a floating-point coincidence, and it
    /// would be wrong for the one case where the picture's dimensions never
    /// arrived at all.
    var cropsToFill: Bool = false
    /// The file's own name and size, for the kinds that show them.
    var filename: String = ""
    var sizeLabel: String = ""
    /// Which of Discord's file icons a file card draws.
    var fileKind: AttachmentFileKind = .unknown
    /// A file card's Download, in the hover group that hangs past its corner.
    /// Nil on every other kind.
    var downloadRect: CGRect?
    /// Where the name and the size sit inside a file card.
    var titleOrigin: CGPoint = .zero
    var subtitleOrigin: CGPoint = .zero
    /// "0:14", under a clip's play badge. Empty when Discord sent no duration.
    var durationLabel: String = ""
    /// A voice note's bars and controls. Nil on every other kind.
    var voice: VoiceNoteSlot?
    /// Whether the picture is animated and should be drawn from a filmstrip
    /// rather than from a still. See `AnimatedImageStore`.
    var isAnimated: Bool = false
    /// The GIF this slot would star, when it is one the account can keep.
    ///
    /// **Only a GIF, and only one with a URL another client can unfurl.** A
    /// favourite is stored as its source URL and re-sent as a message; a
    /// photograph or a clip has nothing to send. Nil is what keeps the control
    /// off every attachment that is not one — `INVARIANTS.md` §5.5.
    var favorite: GIF?
    /// Where the star sits inside the picture. Only meaningful with `favorite`.
    var favoriteRect: CGRect = .zero
    /// Discord's blurred stand-in, drawn until the picture lands.
    var placeholder: String?
    /// What a Discord clip draws over its poster — its title, game and people.
    /// Nil on every other attachment.
    var clip: ClipTileHeader?

    enum Kind: Sendable, Equatable {
        /// A still or animated picture, drawn at its own size.
        case image
        /// A clip. The rect holds a poster; the badge and the duration go over
        /// it.
        case video
        /// A voice note — a waveform and a duration, at one line's height.
        case voice
        /// Anything else: a card with a glyph, a name and a size.
        case file
        /// A text file's preview: room kept for the hosted card that draws
        /// it (`PlaintextPreviewCard`), and nothing painted here.
        case textPreview
    }

    /// Whether the slot draws a picture at all. What decides if the prefetch
    /// should ask for bytes.
    var carriesArtwork: Bool { kind == .image || kind == .video }
}

/// A Discord clip's header over its poster (docs/CLIPS-PRESENCE.md, Phase
/// 4.5) — Discord's player's (module 478531): the title or "Untitled", the game
/// and the day it was made, and up to four faces with the rest as a count.
///
/// **The words only where there is room for them**: Discord drops them under
/// 250 points (`showTextContent`), and so does this.
nonisolated struct ClipTileHeader: Sendable, Equatable {
    struct Face: Sendable, Equatable {
        var url: URL?
        var monogram: String
    }

    var title: String?
    var subtitle: String?
    var faces: [Face]
    /// Everyone past the fourth.
    var overflow: Int

    static let faceSide: CGFloat = 22
    static let shownFaces = 4
    static let minimumWidthForWords: CGFloat = 250
    /// How far the shade under the header reaches down the poster.
    static let shadeHeight: CGFloat = 64

    init(_ clip: AttachmentClip, width: CGFloat) {
        if width >= Self.minimumWidthForWords {
            title = clip.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let parts = [
                clip.applicationName,
                clip.createdAt.map { $0.formatted(.dateTime.month(.abbreviated).day()) },
            ].compactMap(\.self)
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else {
            title = nil
            subtitle = nil
        }
        faces = clip.participants.prefix(Self.shownFaces).map { user in
            Face(
                url: user.avatarHash.flatMap { CDN.avatar(userID: user.id, hash: $0, side: Self.faceSide) }
                    ?? CDN.defaultAvatar(index: user.defaultAvatarIndex),
                monogram: user.monogram
            )
        }
        overflow = max(0, clip.participants.count - Self.shownFaces)
    }

    /// Where the faces sit inside a poster `frame`, right to left from its
    /// top-trailing corner, and the count's box before them.
    func faceRects(in frame: CGRect) -> (faces: [CGRect], overflow: CGRect?) {
        let inset: CGFloat = 10
        let gap: CGFloat = 4
        var x = frame.maxX - inset
        var overflowRect: CGRect?
        if overflow > 0 {
            let width: CGFloat = overflow > 9 ? 30 : 24
            x -= width
            overflowRect = CGRect(x: x, y: frame.minY + inset, width: width, height: Self.faceSide)
            x -= gap
        }
        var rects: [CGRect] = []
        for _ in faces.indices {
            x -= Self.faceSide
            rects.append(CGRect(x: x, y: frame.minY + inset, width: Self.faceSide, height: Self.faceSide))
            x -= gap
        }
        return (rects.reversed(), overflowRect)
    }
}

/// A sticker's box.
///
/// **Its own slot rather than an attachment.** A sticker is not a file somebody
/// uploaded — it has a fixed authored size, no filename, no spoiler state, and a
/// third of them are vector animations with no bitmap on the CDN at all. Folding
/// it into `AttachmentSlot` would mean four fields that are never set and one
/// that means something different.
nonisolated struct StickerSlot: Sendable {
    var rect: CGRect
    var sticker: StickerRef
    var url: URL?
    /// Whether the asset is Lottie, which lives in the filmstrip cache rather
    /// than the still one — `CGImageSource` cannot open it and the CDN serves no
    /// bitmap for it, so its poster is the first frame of a rasterised strip.
    var isVector: Bool
    /// Whether it moves.
    ///
    /// **All three animated formats end up as the same filmstrip** — APNG and
    /// GIF through `CGImageSource`, Lottie through the rasteriser — so this is
    /// one flag rather than three cases, and it is what decides whether the
    /// canvas subscribes to the clock at all.
    var isAnimated: Bool
}

/// One button an app attached to a message.
///
/// **A link button and an action button are both live.** A link opens its URL;
/// an action posts an interaction naming its `custom_id`. A select menu is not —
/// its interaction carries the options chosen and that shape is not captured —
/// so it is drawn dimmed, along with any button malformed enough to be neither.
/// A bot's message is unreadable without its controls, and a control that looks
/// pressable and does nothing is worse than one that says it is not.
nonisolated struct ComponentSlot: Sendable {
    var rect: CGRect
    var label: String
    var emoji: EmojiRef?
    /// Where it goes. Nil for anything this client cannot honour.
    var url: String?
    /// What pressing it posts. Nil for anything that is not a live action
    /// button. Never both this and `url` — a component is one or the other.
    var customID: String?
    var isEnabled: Bool
    var style: MessageComponent.Style
    /// A select menu, drawn as its placeholder with a disclosure.
    var isMenu: Bool
    /// What choosing in it names, for a select menu this client can answer.
    /// Nil for everything else — a button's is `customID`.
    var selectID: String? = nil
    /// Inside a card (a Components V2 container) rather than under one, on a
    /// bubble: a grey button takes its grey over the card it sits on.
    var isOnCard = false
}

/// The line under a message that says only the reader can see it, and the
/// control that throws it away.
///
/// **Dismissing is a real removal, not a hide.** An ephemeral message is
/// delivered over the socket to the one session that caused it and exists
/// nowhere else — it is not in history, and reopening the channel loses it. So
/// taking it out of the store destroys the only copy the reader can reach, which
/// is exactly what the word promises. There is no route to call and none is
/// needed; `INVARIANTS.md` §5.5 asks whether a control *works*, and this one
/// does completely.
///
/// **It does not come back.** `messageUpdated` merges onto a message it can
/// find and returns when it cannot, so an application editing a dismissed
/// message no longer has anywhere to put it.
nonisolated struct EphemeralNoteSlot: Sendable {
    /// The whole line, note and control together. What the row is measured
    /// against.
    var rect: CGRect
    var text: String
    /// The "Dismiss message" run alone — the only part that is a target.
    var dismissRect: CGRect
    var dismissText: String
}

/// The quoted line above a reply, laid out.
///
/// **Everything in it is resolved here, once.** The painter has no store and no
/// main actor: the quoted author's name, face, colour and one line of their
/// message are all measured at layout time, and the row's cache key means a
/// reply that has not moved is not measured again.
nonisolated struct ReplyHeaderSlot: @unchecked Sendable {
    /// The whole clickable strip, in row space. Runs from the elbow's leading
    /// edge to the end of the quote, so the target is the line the reader sees
    /// rather than a word inside it.
    var rect: CGRect
    /// Where the elbow's horizontal leg lands, so the painter and the hit test
    /// agree about the strip's own foot. Nil in bubbles, where there is no
    /// avatar gutter for an elbow to rise out of.
    var elbowBottom: CGFloat?
    var avatarRect: CGRect
    var avatarURL: URL?
    var monogram: String
    /// `@name`, already prefixed.
    var name: String
    var nameRect: CGRect
    /// The styled face at the quote's own size, or nil for the plain one.
    var nameFace: NSFont?
    var nameTracking: CGFloat
    var nameColor: NSColor?
    var excerpt: String
    var excerptRect: CGRect
    /// The quote's face: the metadata face for the quoted words, its italic for
    /// Discord's placeholders — "Message could not be loaded", "Blocked
    /// message", "Click to see attachment" (`repliedTextPlaceholder`).
    var excerptFont: NSFont
    /// Discord's reply badge — its reply arrow in a 16-point circle — where a
    /// face would be, or `.zero`. See `layoutReplyHeader` for when.
    var badgeRect: CGRect
    var isBot: Bool
    /// Where a click goes. Nil when the quoted message is gone, which is also
    /// when the strip says so instead of quoting anything.
    var targetID: MessageID?
}

/// "alex used **launch**", above a message an app posted in answer.
///
/// **Shaped after the reply header, and drawn with the same elbow**, because it
/// is the same idea: a line above a message saying what it is a response to.
/// One is a quote and the other is a command; sharing the connector is what
/// makes them read as one vocabulary rather than two.
nonisolated struct InteractionHeaderSlot: @unchecked Sendable {
    var rect: CGRect
    /// Where the elbow's horizontal leg lands. See `ReplyHeaderSlot`.
    var elbowBottom: CGFloat?
    var avatarRect: CGRect
    var avatarURL: URL?
    var monogram: String
    /// "alex used", already joined — the verb belongs to the sentence rather
    /// than to the chip beside it.
    var lead: String
    var leadRect: CGRect
    var leadFace: NSFont?
    var leadTracking: CGFloat
    var leadColor: NSColor?
    /// Who ran it, and where their name is in the sentence: the face and the
    /// name open them, as a message's own do. "used" opens nobody.
    var userID: UserID
    var nameRect: CGRect
    /// The chip's words, in Discord's medium weight.
    var command: String
    var commandFont: NSFont
    var commandRect: CGRect
    /// The chip's own box: the glyph and the words, grown by its padding.
    var chipRect: CGRect
    /// What the chip is — and so whether it is a plate, whether it takes the
    /// click and what the click does.
    var chip: CommandHeaderChip
    /// Discord's apps icon at a plate's head — see `AppsGlyph`.
    var glyphRect: CGRect?
}

/// The chip under a message that started a thread.
///
/// **Its own slot rather than a reaction-shaped one**, because it is a
/// navigation target: it opens a channel, where every other chip on a row
/// toggles something about this message. `targetID` is what the hit test hands
/// back, and the whole `rect` takes the click — a chip whose label is the only
/// live part is a chip people click beside.
nonisolated struct ThreadChipSlot: Sendable {
    var rect: CGRect
    var targetID: ChannelID
    var name: String
    /// "720 Messages", pre-composed: the painter draws strings, and pluralising
    /// per frame in a draw loop is work with one answer.
    var countText: String
    /// Where the name ends and the count begins, so the painter can colour the
    /// two differently without measuring again.
    var nameWidth: CGFloat
}

/// One chip under a message: one half of one emoji's reactions.
///
/// **An emoji with both kinds is two chips**, the super one first — Discord's
/// own order, from the reactions row in module `279182`, which pushes an
/// emoji's burst half before its plain half.
nonisolated struct ReactionSlot: Sendable {
    var rect: CGRect
    var emoji: EmojiRef
    /// Which half this chip is. A click adds or takes back a reaction of THIS
    /// kind, never the other.
    var kind: ReactionKind
    var count: Int
    var isMine: Bool
    var imageURL: URL?
    /// A super reaction chip's colours, for both rooms. Resolved here, once per
    /// layout, rather than per repaint: the derivation is a contrast search, and
    /// the only thing that can change its answer — the palette — changes the
    /// message and so re-lays-out the row. Which room applies is read at paint
    /// time, so a theme switch never waits on a relayout to recolour a chip.
    ///
    /// Nil on a plain chip, and on a super chip that arrived with no colours,
    /// which Discord draws plain as well.
    var palette: SuperReactionPalette?
    /// A badge on its bubble's corner rather than a chip under it — see
    /// `TimelineMetrics.tapbackLimit`.
    var isTapback = false

    /// The emoji's box inside the chip — where the picture is drawn, where an
    /// animated one's frames are repainted, and what an effect is centred on.
    var glyphRect: CGRect {
        let side = TimelineMetrics.reactionGlyphSide
        return CGRect(
            x: rect.minX + (isTapback ? TimelineMetrics.tapbackInset : TimelineMetrics.reactionLeadingInset),
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// The chip's outline, in whatever space `rect` is in: a capsule for a
    /// tapback, the measured rounded square for a chip.
    var outline: CGPath {
        let radius = isTapback ? rect.height / 2 : TimelineMetrics.reactionChipRadius
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// One of the two square controls at the end of a message's reaction row.
///
/// **Its own slot rather than a reaction-shaped one.** These carry no emoji, no
/// count and no "mine": folding them into `ReactionSlot` would mean four fields
/// that mean nothing for two of the three cases, which is the free-form bag
/// `INVARIANTS.md` warns about — and the hit test would then have to ask which
/// kind it had found before it could read any of them.
///
/// **The bookmark's *state* is deliberately not here.** A row's layout is cached
/// and only re-runs on a presentation or items change, so a flag taken at
/// measure time would freeze the moment it was laid out — §4.5's rule. The
/// geometry does not depend on it; the painter reads it off its own `State`,
/// where a change costs a redraw.
nonisolated struct ReactionControlSlot: Sendable {
    enum Kind: Sendable, Equatable {
        case addReaction
        case bookmark
    }
    var rect: CGRect
    var kind: Kind
}

nonisolated extension MessageRow {
    /// The reaction row's controls that are showing, each in the slot it takes.
    ///
    /// Both are the pointer's (Alex, 2026-11-12, "should appear only on hover
    /// like on Discord"): the add control where a new reaction may be started
    /// and the pointer is on the message — the caller's `canAddReaction` says
    /// both — and the bookmark while the pointer is there or the message is
    /// kept, which is a state a reader has to be able to see. **Showing controls
    /// fill the slots in order**, so a missing add control leaves no hole in
    /// front of the bookmark. The painter and the hit test both read this, so
    /// what is drawn and what answers a click cannot disagree.
    func visibleReactionControls(canAddReaction: Bool, showsBookmark: Bool) -> [ReactionControlSlot] {
        var kinds: [ReactionControlSlot.Kind] = []
        if canAddReaction { kinds.append(.addReaction) }
        if showsBookmark, reactionControls.contains(where: { $0.kind == .bookmark }) {
            kinds.append(.bookmark)
        }
        return zip(kinds, reactionControls).map { ReactionControlSlot(rect: $1.rect, kind: $0) }
    }

    /// Whether a row-space point is on the reactions — Discord's `.reactions`
    /// box, whose hover is what shows the bookmark: every line the chips
    /// wrapped onto, from the first chip to the column's trailing edge.
    func reactionStripContains(_ point: CGPoint, rowWidth: CGFloat) -> Bool {
        guard let first = reactions.first?.rect else { return false }
        let bottom = max(
            reactions.map(\.rect.maxY).max() ?? first.maxY,
            reactionControls.map(\.rect.maxY).max() ?? first.maxY
        )
        return CGRect(x: first.minX, y: first.minY, width: rowWidth - first.minX, height: bottom - first.minY)
            .contains(point)
    }
}

/// One message's own content, laid out — everything between the lines above
/// it and what hangs under it. See `layoutContent` in
/// `TimelineLayoutEngine.buildMessage`.
private nonisolated struct MessageContent {
    var x: CGFloat
    var top: CGFloat
    var textOrigin: CGPoint
    var editedFoot: EditedFootSlot?
    var forwarded: ForwardedSlot?
    /// A forward's words, standing in for the message's own when it has none.
    var forwardText: TimelineTextBlock?
    var stickers: [StickerSlot] = []
    var attachments: [AttachmentSlot] = []
    var upload: UploadCardSlot?
    var hiddenMedia: HiddenMediaSlot?
    var poll: PollSlot?
    var activityInvite: ActivityInviteSlot?
    var listenAlong: ListenAlongSlot?
    var sharedTheme: SharedThemeCardSlot?
    var card: DrawnCard?
    var embeds: [EmbedSlot] = []
    var components: [ComponentSlot] = []
    var inviteCards: [InviteCardSlot] = []
    var hostedCards: [HostedCardSlot] = []
    /// How far past `x` it reaches — in a bubble, the bubble's width.
    var width: CGFloat = 0
    /// Where it ends — in a bubble, the bubble's foot.
    var bottom: CGFloat = 0
    /// Whether anything but words is in it.
    var hasCards = false
    /// Neither words nor anything else — nothing for a bubble to hold.
    var isEmpty = false

    var bounds: CGRect { CGRect(x: x, y: top, width: width, height: bottom - top) }
}

// MARK: - The layout engine

/// Turns timeline items into laid-out rows.
///
/// **Incremental by construction.** A rows change usually adds one message
/// (a live arrival) or prepends a hundred (a page of history); everything else
/// is unchanged, and re-laying it out would mean re-framesetting text that has
/// not moved. The cache is keyed on identity plus everything that can change the
/// answer — width, and the presentation revision that covers text size, theme
/// and mention names — so a hit is exact and a miss is honest.
nonisolated struct TimelineLayoutEngine: Sendable {

    /// The event on now in a channel, as far as a stage start asks: which,
    /// and its name.
    struct LiveEvent: Hashable, Sendable {
        var guildID: GuildID
        var id: UInt64
        var name: String
    }

    struct Input: Sendable {
        var items: [TimelineItem]
        var width: CGFloat
        var style: MessageTextStyle
        var mentions: MentionContext
        var channelName: String
        /// Which of Discord's heads the transcript opens with — see
        /// `ChannelHead`.
        var head: ChannelHead = .channel
        /// A forum post's bar, for a transcript that is one — see
        /// `PostActions`.
        var postActions: PostActions?
        /// The forum post's author, whose messages in it are OP.
        var postOwnerID: UserID?
        /// The channel's own SF Symbol — `#`, a speaker, a megaphone. Resolved
        /// by the caller, because the kind is a store fact and this type is
        /// deliberately unable to reach the store.
        var channelSymbol: String = "number"
        /// What the channel is for, in the words whoever set it up wrote.
        /// Markdown, because that is what the field accepts.
        var channelTopic: String?
        /// Everything the layout needs about people, resolved by the caller so
        /// this never touches the store.
        var authors: [UserID: AuthorInfo]
        var calendar: Calendar
        /// What the reader's preferences contribute — density, whether embeds
        /// are measured, and the date formatters. Resolved once per presentation
        /// revision, never read from the store here: this type is `nonisolated`
        /// and runs off the main actor.
        var settings: TimelineSettings
        /// The cards behind whatever Spotify links these messages carry, keyed
        /// by `kind/id`.
        ///
        /// **Handed in like everything else, because this type cannot reach the
        /// store.** Usually empty: it holds an entry only for links the reader
        /// has actually seen, so a channel with no music in it carries an empty
        /// dictionary and pays a lookup that never fires.
        var spotify: [String: SpotifyUnfurl] = [:]
        /// What each linked invite turned out to be, by code — see
        /// `AppModel.inviteLookups`. Empty for nearly every channel.
        var invites: [String: InviteLookup] = [:]
        /// The rooms voice invites lead to, as the reader may see them — see
        /// `AppModel.voiceInviteStates`. Empty unless one is linked.
        var voiceInvites: [ChannelID: VoiceInviteState] = [:]
        /// The profile cards the reader has opened past Discord's fold.
        var expandedInvites: Set<InviteCardFold> = []
        /// The colours taken from pictures, by picture — a server card's banner
        /// is its icon's colour where the server chose none. See
        /// `AppModel.derivedPalettes`.
        var palettes: [URL: [UInt32]] = [:]
        /// What each hosted card measured — see `AppModel.hostedCardSizes`.
        var hostedCardSizes: [HostedCardKey: HostedCardMeasure] = [:]
        /// The server this transcript is in, which the profile cards in it
        /// wear. Nil in a direct message.
        var guildID: GuildID?
        /// Whether the reader may manage this channel, which puts Discord's
        /// Edit Channel button under its welcome header.
        var canEditChannel = false
        /// Whether the reader may manage messages here — Discord's Delete
        /// User's Message on an AutoMod alert.
        var canManageMessages = false
        /// The reader's sends whose files are going up, by their echo's id.
        /// Empty for nearly every transcript at nearly every moment.
        var uploads: [MessageID: UploadSummary] = [:]
        /// A message request not yet accepted: words only, the media counted
        /// — see `Message.restrictedPreview`.
        var hidesMedia = false
        /// The listening parties still on, by party id — whether a listen-along
        /// card is the live one or Discord's "The listening party is over!".
        var listenAlongLive: Set<String> = []
        /// A stage chat's "requested to speak." lines whose hand is still up,
        /// for a reader who may answer — each wears Invite to Speak. Empty
        /// everywhere else; see `AppModel.openStageRequests`.
        var stageInvitations: Set<MessageID> = []
        /// The event on now in this channel — what a stage start that
        /// announced it wears its card for (Discord's
        /// `getActiveEventByChannel`). Nil nearly everywhere.
        var liveEvent: LiveEvent?
        /// The stickers other Fake Nitro users' GIF uploads stand for, by
        /// sticker — see `AppModel.fakeGIFStickers`. Empty nearly everywhere.
        var fakeGIFStickers: [UInt64: StickerRef] = [:]
        /// Columns or bubbles. **Only a transcript ever asks for bubbles** —
        /// search, the inbox and the pinned pane keep Discord's columns, which
        /// is why this is decided by the caller rather than read from the
        /// reader's preference here.
        var arrangement: MessageArrangement = .columns
    }

    /// `@unchecked` for the same reason `MessageTextStyle` is: it carries a
    /// resolved `NSFont`, which is immutable in practice but not marked
    /// `Sendable`. **Resolved on the main actor where this is built**, because
    /// the registry is main-actor state and the layout deliberately is not — and
    /// because resolving here means only the faces actually on screen are ever
    /// registered.
    struct AuthorInfo: @unchecked Sendable, Equatable {
        var name: String
        var colorValue: UInt32?
        var avatarURL: URL?
        var monogram: String
        var decorationURL: URL?
        var isBot: Bool
        /// The reader blocked or ignored this person, so a reply quoting them
        /// says "Blocked message" or "Ignored message" — Discord's own.
        var isBlocked = false
        var isIgnored = false
        /// A verified app's badge carries a check — `AppBadge`.
        var isVerifiedBot = false
        /// Discord's own system account, whose messages are OFFICIAL.
        var isSystem = false
        /// The server tag they wear, beside their name.
        ///
        /// **The same fact the roster and the direct-message list already
        /// draw** — `UserDecoration.primaryGuildTag` — resolved here so the
        /// three surfaces cannot disagree about what somebody looks like. It
        /// was on the wire and read by nothing in the transcript.
        var tag: String?
        /// The little badge inside the chip, ahead of the letters.
        var tagBadgeURL: URL?
        /// The icon of their highest role that has one, and where it comes
        /// from — an uploaded image, or a unicode emoji.
        ///
        /// **Discord draws this beside the name and this client drew it
        /// nowhere.** `Role.iconHash` and `Role.unicodeEmoji` have both been
        /// decoded since roles were, and only the profile's role chips ever
        /// read them.
        var roleIconURL: URL?
        var roleEmoji: String?
        /// The styled face, already resolved. Nil is the ordinary case.
        var nameFace: NSFont?
        /// Discord's per-family tracking, in points.
        var nameTracking: CGFloat = 0
        /// The stops of the author's colour role, when that role carries a
        /// gradient. The transcript draws it exactly as the roster does.
        var gradient: [UInt32]?
        /// The effect and colours the account chose, for the hover state.
        ///
        /// **The face has been read here since the transcript first drew a
        /// styled name; the rest of the style was decoded and dropped.** A
        /// person with Prism looked exactly like a person with the same font
        /// and no effect, in every channel, forever — which is the shape of
        /// `INVARIANTS.md`'s "on the wire and read by nothing".
        var nameStyle: DisplayNameStyle?
        /// Their account's username — the `@name` AutoMod's Activity Alerts
        /// notice names whoever switched them on by.
        var username: String?
    }

    /// One message's laid-out form, and everything it was laid out against.
    ///
    /// **Keyed by id, matched on the message itself — not keyed on a tuple of
    /// scalars.** The scalar key that this replaces carried the id, the width,
    /// the presentation revision and the run flag, and nothing about the
    /// message's *content*: a reaction arriving, a body being edited or an
    /// embed unfurling all hit the cache and served the previous layout, for
    /// ever. That is invisible until something in the app can actually change a
    /// message, which is exactly what the action menu added.
    ///
    /// Comparing the whole `Message` is cheap and settles in a pointer compare
    /// in the common case: the string is the same buffer, and `MessagePayload`'s
    /// `==` opens with `lhs === rhs`. A *hash* of the message would not do —
    /// `MessagePayload.hash` folds counts rather than values, so a reaction
    /// going from 12 to 13 hashes identically and the collision would be a
    /// stale row rather than a slow one.
    struct CacheEntry: Sendable {
        /// Width, rounded to a whole point. A drag resizes by fractions and an
        /// entry that carries them never matches.
        var width: Int
        var presentationRevision: UInt64
        /// What the mention table was at: the channels, roles and servers a
        /// row can name. **Not the people.** They are checked one by one,
        /// below, because a counter for them moves with every user record in
        /// the account.
        var identityToken: UInt64
        /// Everybody the row draws by their own name and face — its author,
        /// whoever it quotes, whoever ran its command — as each stood when it
        /// was laid out. See `TimelineLayoutEngine.people(in:autoMod:)`.
        var people: [Person] = []
        /// The user mentions its words asked for, and what each was set as:
        /// nil for somebody not known then, so the row is set again once they
        /// are.
        var names: [MentionedName] = []

        struct Person: Sendable {
            var id: UserID
            var info: AuthorInfo?
        }

        struct MentionedName: Sendable {
            var id: UserID
            var name: String?
        }
        /// What the Spotify table was at.
        ///
        /// **A card resolves *after* the row is already laid out**, and it is a
        /// different height from the link unfurl it replaces — so unlike an
        /// activity's accent, which resolves late and only repaints, this cannot
        /// live on the paint state. Without it, the first layout of a message
        /// carrying a Spotify link is the only one it ever gets.
        var cardRevision: UInt64
        /// Whether the row can carry a card at all — see `carriesCards(_:)`.
        /// **Only these rows are rebuilt when a card lands**: comparing the
        /// revision on every row relaid the whole loaded transcript each time
        /// one invite resolved, and a chat opens with several resolving.
        var carriesCards: Bool
        var isRunHead: Bool
        /// Whether the row closed its run, in bubbles — where the last bubble
        /// wears the tail and somebody's face sits beside it. Nil in columns,
        /// where it changes nothing, so a run growing there relays nothing.
        var isRunTail: Bool?
        /// Whether the row was laid out in the critical ink of a refused send —
        /// which is set into the body's text, so a send turning red is a
        /// relayout. Being on its way is not: that is painted.
        var isFailed: Bool
        /// Laid out as a request's preview. Accepting one in front of the
        /// reader is a relayout of every row, into the whole message.
        var hidesMedia: Bool
        /// Whether a listen-along card was laid out live. Nil on every other
        /// row. A party ending is a shorter card, so it is a relayout.
        var listenAlongLive: Bool?
        /// Whether an AutoMod alert was laid out for a reader who may delete
        /// the member's message. Nil on every other row; a permission change
        /// adds or takes away the bar's last button.
        var canManageMessages: Bool?
        /// Whether a stage's "requested to speak." line was laid out with
        /// Invite to Speak under it. Nil on every other row; the hand coming
        /// down takes the button away.
        var stageInvitationOpen: Bool?
        /// The event a stage start was laid out wearing the card of — see
        /// `stageStartEvent(of:in:)`. Nil on every other row; the event
        /// starting or ending adds or takes away the card.
        var stageStartEvent: UInt64?
        /// The stickers the message's GIF uploads were drawn as — see
        /// `fakeGIFStickers(of:in:)`. Nil on every other row.
        var gifStickers: [StickerRef]?
        var message: Message
        var row: MessageRow
        /// The highlighter's revision when the row was laid out with a code
        /// block still waiting on it — nil when nothing was. **Only such rows
        /// are rebuilt when answers land**, as only rows with cards are when a
        /// card does.
        var awaitingHighlightAt: UInt64? = nil

        func matches(
            _ message: Message,
            width: Int,
            presentationRevision: UInt64,
            identityToken: UInt64,
            cardRevision: UInt64,
            isRunHead: Bool,
            isRunTail: Bool?,
            isFailed: Bool,
            hidesMedia: Bool,
            listenAlongLive: Bool?,
            canManageMessages: Bool?,
            stageInvitationOpen: Bool?,
            stageStartEvent: UInt64?,
            gifStickers: [StickerRef]?,
            authors: [UserID: AuthorInfo],
            userNames: [UserID: String]
        ) -> Bool {
            self.width == width
                && self.presentationRevision == presentationRevision
                && self.identityToken == identityToken
                && (!carriesCards || self.cardRevision == cardRevision)
                && self.isRunHead == isRunHead
                && self.isRunTail == isRunTail
                && self.isFailed == isFailed
                && self.hidesMedia == hidesMedia
                && self.listenAlongLive == listenAlongLive
                && self.canManageMessages == canManageMessages
                && self.stageInvitationOpen == stageInvitationOpen
                && self.stageStartEvent == stageStartEvent
                && self.gifStickers == gifStickers
                && self.message == message
                && (awaitingHighlightAt.map { $0 == CodeHighlighter.revision } ?? true)
                // After the message itself: an equal message names the same
                // people, so what is left to ask is whether any of them changed.
                && people.allSatisfy { authors[$0.id] == $0.info }
                && names.allSatisfy { userNames[$0.id] == $0.name }
        }
    }

    /// Everybody a message's row draws by their own name and face: its author,
    /// whoever ran its command, whoever it quotes, and the people an AutoMod
    /// card names.
    ///
    /// **The same people `AppModel.authorInfo` resolves, and it has to stay
    /// so.** Somebody resolved there and missing here is a row that never hears
    /// their name changed; the other way round costs a lookup that finds nil.
    static func people(in message: Message, autoMod: AutoModMessage?) -> [UserID] {
        var ids = [message.authorID]
        if let invoker = message.interaction?.userID { ids.append(invoker) }
        if let quoted = message.reference?.authorID { ids.append(quoted) }
        if let autoMod { ids.append(contentsOf: autoMod.namedUserIDs) }
        return ids
    }

    var presentationRevision: UInt64
    /// Moves when a Spotify card lands. See `CacheEntry.cardRevision`.
    var cardRevision: UInt64 = 0

    /// Whether a message can draw a card that resolves after it is laid out:
    /// an invite, profile or event link in its text, a stage start's event, or
    /// a Spotify embed in it or in what it forwards. The same gates the
    /// builders use, so the answer cannot disagree with what the row draws.
    static func carriesCards(_ message: Message) -> Bool {
        !InviteCard.codes(in: message.content).isEmpty
            || !UserLink.userIDs(in: message.content).isEmpty
            || !EventLink.links(in: message.content).isEmpty
            || message.kind == .stageStart
            || message.attachments.contains { PlaintextPreview.isPreviewable(filename: $0.filename) }
            || message.embeds.contains { $0.providerName == "Spotify" }
            || message.forwarded?.embeds.contains { $0.providerName == "Spotify" } == true
    }

    /// Where an event card goes, once it has measured: as wide as the column
    /// up to Discord's 432, and as tall as it measured at that width — or at
    /// the nearest it has, until the live card says.
    private static func eventCardSlot(
        _ key: EventCardKey,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        input: Input
    ) -> HostedCardSlot? {
        let width = min(Metrics.embedMaxWidth, width).rounded(.down)
        guard let height = input.hostedCardSizes[.event(key)]?.height(atWidth: width) else { return nil }
        return HostedCardSlot(rect: CGRect(x: x, y: y, width: width, height: height), key: .event(key))
    }

    /// Whether a link's unfurl gives way to a card drawn for it: a profile
    /// link's or an event link's that has measured.
    private static func hasHostedCard(forLink url: String, in input: Input) -> Bool {
        guard !input.hostedCardSizes.isEmpty else { return false }
        if let userID = UserLink.userID(inURL: url) {
            return input.hostedCardSizes[.user(UserCardKey(userID: userID, guildID: input.guildID))] != nil
        }
        if let link = EventLink.parse(url) {
            let key = EventCardKey(guildID: link.guildID, eventID: link.eventID, occurrence: link.occurrence)
            return input.hostedCardSizes[.event(key)] != nil
        }
        return false
    }

    /// The event whose card a stage start wears: the channel's live event,
    /// where its name is the line's topic — Discord's own test (`STAGE_START`
    /// in `270642`). Nil for every other row.
    static func stageStartEvent(of message: Message, in input: Input) -> UInt64? {
        guard message.kind == .stageStart, let live = input.liveEvent, live.name == message.content else {
            return nil
        }
        return live.id
    }

    /// The resolved card behind an embed, if it is a Spotify link and Spotify's
    /// own page has answered for it.
    ///
    /// **Gated on the provider before the URL is parsed.** Discord unfurled the
    /// link and said whose it was, so the overwhelming majority of embeds in a
    /// transcript are rejected by one string compare rather than by a URL parse.
    static func spotifyCard(for embed: Embed, in input: Input) -> SpotifyUnfurl? {
        guard !input.spotify.isEmpty, embed.providerName == "Spotify",
              let link = embed.url, let address = SpotifyLink.parse(link)
        else { return nil }
        return input.spotify["\(address.kind.rawValue)/\(address.id)"]
    }

    /// Lays out every item, reusing what `cache` already holds.
    ///
    /// The cache is `inout` rather than a class, so the caller owns its lifetime
    /// and the engine cannot retain anything past the call — there is no place
    /// for a leak to hide.
    func layout(
        _ input: Input,
        cache: inout [MessageID: CacheEntry],
        parser: MarkdownParser = MarkdownParser()
    ) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(input.items.count)
        var used = Set<MessageID>()
        used.reserveCapacity(input.items.count)
        let width = Int(input.width.rounded())
        // The user mentions each row's words ask for, noted as they are asked
        // — see `MentionLookups`. The caller's own, where it wants to hear
        // which names the whole pass used.
        let lookups = input.mentions.lookups ?? MentionLookups()
        var input = input
        input.mentions.lookups = lookups
        var asked = Set<UserID>()

        for item in input.items {
            switch item {
            case .daySeparator(let date):
                rows.append(TimelineRow(
                    height: TimelineMetrics.daySeparatorHeight,
                    kind: .daySeparator(label: input.settings.dayLabel(date, calendar: input.calendar))
                ))

            case .unreadDivider:
                rows.append(TimelineRow(
                    height: TimelineMetrics.unreadDividerHeight,
                    kind: .unreadDivider
                ))

            case .conversationStart:
                let slot = Self.conversationStart(
                    input,
                    width: input.width,
                    parser: parser
                )
                rows.append(TimelineRow(
                    height: slot.height,
                    kind: .conversationStart(slot.slot)
                ))

            case .historySkeleton(let index):
                rows.append(TimelineRow(
                    height: TimelineMetrics.skeletonHeight,
                    kind: .skeleton(index: index)
                ))

            case .marker(let kind, _, let title):
                rows.append(TimelineRow(
                    height: TimelineMetrics.topicMarkerHeight,
                    kind: .marker(kind, title: title)
                ))

            case .loadingFirstPage:
                rows.append(TimelineRow(
                    height: TimelineMetrics.loadingRowHeight,
                    kind: .loadingFirstPage
                ))

            case .historyUnavailable(let reason):
                rows.append(TimelineRow(
                    height: TimelineMetrics.historyUnavailableHeight,
                    kind: .historyUnavailable(reason: reason)
                ))

            case .collapsedGroup(let group):
                let slot = Self.collapsedGroup(group, input: input)
                rows.append(TimelineRow(
                    height: ceil(slot.textOrigin.y + slot.text.size.height + TimelineMetrics.runBottomPadding),
                    kind: .collapsedGroup(slot)
                ))

            case .message(let message):
                used.insert(message.message.id)
                let isFailed = message.flags.contains(.failed)
                let listenAlongLive = message.message.listenAlong.map { input.listenAlongLive.contains($0.partyID) }
                let isRunTail = input.arrangement == .columns ? nil : message.isRunTail
                let autoMod = AutoModMessage(message.message)
                let canManageMessages = autoMod == nil ? nil : input.canManageMessages
                let stageInvitationOpen = message.message.kind == .stageRaiseHand
                    ? input.stageInvitations.contains(message.message.id) : nil
                let stageStartEvent = Self.stageStartEvent(of: message.message, in: input)
                let gifStickers = Self.fakeGIFStickers(of: message.message, in: input)
                if let cached = cache[message.message.id],
                   cached.matches(
                       message.message,
                       width: width,
                       presentationRevision: presentationRevision,
                       identityToken: input.mentions.token,
                       cardRevision: cardRevision,
                       isRunHead: message.isRunHead,
                       isRunTail: isRunTail,
                       isFailed: isFailed,
                       hidesMedia: input.hidesMedia,
                       listenAlongLive: listenAlongLive,
                       canManageMessages: canManageMessages,
                       stageInvitationOpen: stageInvitationOpen,
                       stageStartEvent: stageStartEvent,
                       gifStickers: gifStickers,
                       authors: input.authors,
                       userNames: input.mentions.userNames
                   )
                {
                    for name in cached.names { asked.insert(name.id) }
                    // Painted, so carried over rather than keyed on.
                    var row = cached.row
                    row.isPending = message.flags.contains(.pending)
                    row.isInOpenFold = message.flags.contains(.inOpenGroup)
                    rows.append(TimelineRow(height: rowHeight(of: row), kind: .message(row)))
                    continue
                }
                // Read before the build: an answer landing while the row is
                // built must leave it stale, not fresh.
                let highlightAt = CodeHighlighter.revision
                // What a head or a fold asked for before this row is not this
                // row's to remember.
                asked.formUnion(lookups.take())
                var row = if let autoMod {
                    Self.autoModRow(message, autoMod, input: input, parser: parser)
                } else if message.message.isSystemEvent {
                    buildSystemMessage(message, input: input)
                } else {
                    buildMessage(message, input: input, parser: parser)
                }
                row.isInOpenFold = message.flags.contains(.inOpenGroup)
                var names: [CacheEntry.MentionedName] = []
                for userID in lookups.take() where !names.contains(where: { $0.id == userID }) {
                    names.append(.init(id: userID, name: input.mentions.userNames[userID]))
                    asked.insert(userID)
                }
                cache[message.message.id] = CacheEntry(
                    width: width,
                    presentationRevision: presentationRevision,
                    identityToken: input.mentions.token,
                    people: Self.people(in: message.message, autoMod: autoMod).map {
                        .init(id: $0, info: input.authors[$0])
                    },
                    names: names,
                    cardRevision: cardRevision,
                    carriesCards: Self.carriesCards(message.message),
                    isRunHead: message.isRunHead,
                    isRunTail: isRunTail,
                    isFailed: isFailed,
                    hidesMedia: input.hidesMedia,
                    listenAlongLive: listenAlongLive,
                    canManageMessages: canManageMessages,
                    stageInvitationOpen: stageInvitationOpen,
                    stageStartEvent: stageStartEvent,
                    gifStickers: gifStickers,
                    message: message.message,
                    row: row,
                    awaitingHighlightAt: row.textBlock?.text.awaitsHighlighting == true ? highlightAt : nil
                )
                rows.append(TimelineRow(height: rowHeight(of: row), kind: .message(row)))
            }
        }

        // Drop anything this pass did not use, bounded so a long session cannot
        // accumulate every layout it has ever built. Without this the cache is a
        // leak with a polite name.
        if cache.count > used.count + Self.cacheSlack {
            cache = cache.filter { used.contains($0.key) }
        }

        // A forum post's bar goes under its opening message — Discord's
        // `FORUM_POST_ACTION_BAR` stream item — or under the post's head where
        // the opening message is gone.
        if let actions = input.postActions {
            let anchor = rows.firstIndex { $0.messageID?.rawValue == actions.openerID.rawValue }
                ?? (actions.openerDeleted
                    ? rows.firstIndex { if case .conversationStart = $0.kind { true } else { false } }
                    : nil)
            if let anchor {
                let slot = Self.postActions(actions, input: input)
                rows.insert(TimelineRow(height: slot.height, kind: .postActions(slot.slot)), at: anchor + 1)
            }
        }

        // Whatever the rows built last asked for, a head's topic included.
        asked.formUnion(lookups.take())
        lookups.finishPass(asked)
        return rows
    }

    /// Discord's own words. Kept as one constant because the layout measures it
    /// and the painter draws it, and two copies is two places for it to drift.
    static let ephemeralNoteText = "Only you can see this"
    /// Discord's own words for the control beside it.
    static let ephemeralDismissText = "Dismiss message"

    /// How many stale entries to tolerate before sweeping.
    ///
    /// Some slack is worth keeping: a width drag produces a burst of misses and
    /// then settles back, and sweeping on every pass would throw away the
    /// entries the settle is about to want again.
    ///
    /// **Smaller than it was, because an entry is bigger than it was.** Keyed by
    /// id, a miss now *replaces* its entry rather than adding a second one
    /// beside it — so the only stale entries left are messages that have
    /// scrolled out of the page, and four hundred of those is four hundred
    /// laid-out rows nobody is looking at.
    static let cacheSlack = 200

    private func rowHeight(of row: MessageRow) -> CGFloat {
        var bottom: CGFloat = 0
        if let header = row.replyHeader { bottom = max(bottom, header.rect.maxY) }
        if let header = row.interactionHeader { bottom = max(bottom, header.rect.maxY) }
        if let avatarRect = row.avatarRect { bottom = max(bottom, avatarRect.maxY) }
        bottom = max(bottom, row.authorRect.maxY)
        if let forwarded = row.forwarded { bottom = max(bottom, forwarded.rect.maxY) }
        if let block = row.textBlock {
            bottom = max(bottom, row.textOrigin.y + block.size.height)
        }
        if let foot = row.editedFoot { bottom = max(bottom, foot.origin.y + foot.block.size.height) }
        // The bubble's own padding reaches past its words.
        if let bubble = row.bubbles?.bubble { bottom = max(bottom, bubble.rect.maxY) }
        if let failure = row.bubbles?.failure { bottom = max(bottom, failure.caption.maxY) }
        for slot in row.stickers { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.attachments { bottom = max(bottom, slot.rect.maxY) }
        if let upload = row.upload { bottom = max(bottom, upload.rect.maxY) }
        if let hiddenMedia = row.hiddenMedia { bottom = max(bottom, hiddenMedia.rect.maxY) }
        for slot in row.embeds { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.components { bottom = max(bottom, slot.rect.maxY) }
        if let poll = row.poll { bottom = max(bottom, poll.rect.maxY) }
        if let invite = row.activityInvite { bottom = max(bottom, invite.rect.maxY) }
        if let listenAlong = row.listenAlong { bottom = max(bottom, listenAlong.rect.maxY) }
        if let theme = row.sharedTheme { bottom = max(bottom, theme.rect.maxY) }
        for card in row.inviteCards { bottom = max(bottom, card.rect.maxY) }
        for card in row.hostedCards { bottom = max(bottom, card.rect.maxY) }
        for slot in row.reactions { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.reactionControls { bottom = max(bottom, slot.rect.maxY) }
        if let chip = row.threadChip { bottom = max(bottom, chip.rect.maxY) }
        if let note = row.ephemeralNote { bottom = max(bottom, note.rect.maxY) }
        if let card = row.card { bottom = max(bottom, card.rect.maxY) }
        return ceil(bottom + TimelineMetrics.runBottomPadding)
    }

    private func buildMessage(
        _ item: TimelineMessage,
        input: Input,
        parser: MarkdownParser
    ) -> MessageRow {
        // A request's preview lays out the words and counts the rest.
        let (message, hiddenMediaCount) = input.hidesMedia
            ? item.message.restrictedPreview
            : (item.message, 0)
        let author = input.authors[message.authorID]
        // **Which side the message hugs, and whether it is named, decided
        // once.** In bubbles the reader's own messages trail and carry neither
        // a name nor a face; everybody else's lead, named over a run's first
        // bubble and faced beside its last — unless the conversation has only
        // one other person in it.
        let bubbleSide: BubbleRow.Side?
        let namesAuthor: Bool
        switch input.arrangement {
        case .columns:
            bubbleSide = nil
            namesAuthor = true
        case .bubbles(let namesAuthors):
            let isMine = input.mentions.selfIDs.contains(message.authorID.rawValue)
            bubbleSide = isMine ? .trailing : .leading
            namesAuthor = namesAuthors && !isMine
        }
        let isFailed = item.flags.contains(.failed)
        let lane = bubbleSide.map { side in
            var lane = MessageLane.bubble(
                rowWidth: input.width,
                side: side,
                indent: namesAuthor ? BubbleMetrics.avatarSide + BubbleMetrics.avatarGap : 0
            )
            // A refused send keeps room at the edge for its mark.
            if isFailed, side == .trailing { lane.width -= BubbleMetrics.failureReserve }
            return lane
        } ?? .column(rowWidth: input.width)
        let contentX = lane.minX
        let contentWidth = lane.width
        let hasAuthorLine = item.isRunHead && namesAuthor
        // Discord's tag beside the name, decided by the message — see
        // `AuthorTag`. Only where there is a name to put it beside.
        let authorTag = hasAuthorLine
            ? AuthorTag.resolve(
                message: message,
                isSystem: author?.isSystem ?? false,
                isBot: author?.isBot ?? false,
                isVerifiedBot: author?.isVerifiedBot ?? false,
                postOwnerID: input.postOwnerID
            )
            : nil

        /// Lays out a piece whose width is known only once it is laid out —
        /// and, on a trailing lane, once more against the trailing edge. Every
        /// layout here is the same at any origin, so the second pass moves the
        /// piece and breaks no line differently.
        func placed<Slot>(_ build: (CGFloat) -> Slot, width: (Slot) -> CGFloat) -> Slot {
            let leading = build(lane.minX)
            guard lane.isTrailing else { return leading }
            let used = width(leading)
            return used > 0 && used < lane.width - 0.5 ? build(lane.maxX - used) : leading
        }
        /// How far a run of pieces laid out from the lane's start reaches.
        func extent(_ rects: [CGRect]) -> CGFloat {
            (rects.map(\.maxX).max() ?? lane.minX) - lane.minX
        }

        var y: CGFloat = item.isRunHead ? input.settings.runSpacing : TimelineMetrics.lineSpacing
        var avatarRect: CGRect?
        var authorRect = CGRect(x: contentX, y: y, width: 0, height: 0)
        var timestampRect = CGRect.zero

        // The quoted line, above everything. A reply always breaks its run — see
        // `TimelineReducer` — so the header and the author line below it are
        // always drawn together and the elbow always has a face to rise out of.
        // In bubbles there is no gutter to rise out of: the line sits over the
        // bubble on its side, and has no elbow.
        var replyHeader: ReplyHeaderSlot?
        // A crosspost's reference is where it was published, not a message it
        // answers — Discord draws no quote over it.
        if let reference = message.reference, !message.isCrosspost {
            let quoted = reference.authorID.flatMap { input.authors[$0] }
            let compact = input.settings.isCompact
            let slot = bubbleSide == nil
                ? Self.layoutReplyHeader(
                    reference, y: y, leadingX: contentX,
                    maxX: input.width - TimelineMetrics.horizontalMargin,
                    elbowX: TimelineMetrics.replyElbowX, isCompact: compact,
                    style: input.style, author: quoted
                )
                : placed({
                    Self.layoutReplyHeader(
                        reference, y: y, leadingX: $0, maxX: lane.maxX,
                        elbowX: nil, isCompact: compact, style: input.style, author: quoted
                    )
                }, width: { $0.rect.width })
            replyHeader = slot
            y = slot.rect.maxY + TimelineMetrics.replyGap
        }

        // A command's answer always heads its own run (`TimelineReducer`), so
        // every one has this line: three commands in a row are three things
        // somebody ran, as Discord draws them.
        var interactionHeader: InteractionHeaderSlot?
        if item.isRunHead, let interaction = message.interaction, let chip = message.commandHeaderChip {
            let invoker = input.authors[interaction.userID]
            let slot = bubbleSide == nil
                ? Self.layoutInteractionHeader(
                    interaction, chip: chip, y: y, leadingX: contentX, maxX: input.width,
                    elbowX: TimelineMetrics.replyElbowX, style: input.style, author: invoker
                )
                : placed({
                    Self.layoutInteractionHeader(
                        interaction, chip: chip, y: y, leadingX: $0, maxX: lane.maxX,
                        elbowX: nil, style: input.style, author: invoker
                    )
                }, width: { $0.rect.width })
            interactionHeader = slot
            y = slot.rect.maxY + TimelineMetrics.replyGap
        }

        var tagRect = CGRect.zero
        var roleIconRect = CGRect.zero
        // **In bubbles the name is a caption** over the run's first bubble, as
        // Messages names a group's people (REDESIGN.md R6): the name's own face
        // and colour — a custom font or a role colour stays — a size down,
        // on a line of its own height rather than Discord's header's.
        let isCaption = bubbleSide != nil
        let baseFace = author?.nameFace ?? input.style.authorFont
        let nameFace = isCaption ? BubbleMetrics.captionFace(baseFace) : baseFace
        let nameTracking = (author?.nameTracking ?? 0)
            * (isCaption ? nameFace.pointSize / max(1, baseFace.pointSize) : 1)
        let nameLine = isCaption
            ? ceil(nameFace.ascender - nameFace.descender) + 2
            : TimelineMetrics.headerHeight
        /// The caption's reach across the row, name to role icon: where the
        /// bubble under it may let its tapbacks rise beside it.
        var captionSpan: ClosedRange<CGFloat>?
        if hasAuthorLine {
            // In bubbles the face sits beside a run's LAST bubble, and the
            // name lines up with the words in the bubble under it.
            if bubbleSide == nil {
                avatarRect = CGRect(
                    x: TimelineMetrics.horizontalMargin,
                    y: y,
                    width: Metrics.avatarMessage,
                    height: Metrics.avatarMessage
                )
            }
            let nameX = bubbleSide == nil ? contentX : contentX + BubbleMetrics.horizontalPadding
            let name = author?.name ?? "Unknown"
            // **Measured in the face it will be DRAWN in.** The bot badge and
            // the timestamp are placed off this width, so measuring in the
            // default face and drawing in another puts both in the wrong place.
            let nameWidth = Self.measure(name, font: nameFace, tracking: nameTracking)
            authorRect = CGRect(
                x: nameX,
                y: y,
                width: nameWidth,
                height: nameLine
            )
            // The server tag, in the same chip the roster draws — see
            // `MemberRowGeometry.tagChipWidth`, which both the reservation and
            // the draw call so the padding cannot end up pooled on one side.
            var afterName = authorRect.maxX
                + (authorTag.map { AuthorTagChip.width($0) + 4 } ?? 0)
            if let tag = author?.tag {
                let width = MemberRowGeometry.tagChipWidth(
                    textWidth: Self.measure(tag, font: MemberRowGeometry.tagChipFont),
                    hasBadge: author?.tagBadgeURL != nil
                )
                tagRect = CGRect(
                    x: afterName + 6,
                    // Centred on the name's own line box rather than pinned to
                    // its top: the chip is 15 points and the header is taller.
                    y: y + (nameLine - MemberRowGeometry.tagChipHeight) / 2,
                    width: width,
                    height: MemberRowGeometry.tagChipHeight
                )
                afterName = tagRect.maxX
            }
            // The role icon, after the tag. Discord's order on a run head is
            // name, server tag, role icon, time — and the icon is a square on
            // the name's own line box rather than a chip, because it carries no
            // text of its own.
            if item.isRunHead, author?.roleIconURL != nil || author?.roleEmoji != nil {
                let side = TimelineMetrics.roleIconSide
                roleIconRect = CGRect(
                    x: afterName + TimelineMetrics.roleIconGap,
                    y: y + (nameLine - side) / 2,
                    width: side,
                    height: side
                )
                afterName = roleIconRect.maxX
            }
            // In bubbles the time is beside the bubble, under the pointer.
            if bubbleSide == nil {
                timestampRect = CGRect(
                    x: afterName + 8,
                    y: y,
                    width: Self.measure(
                        input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
                        font: input.style.metadataFont
                    ),
                    height: TimelineMetrics.headerHeight
                )
            }
            if isCaption { captionSpan = authorRect.minX...afterName }
            y += nameLine + (isCaption ? BubbleMetrics.captionGap : TimelineMetrics.headerGap)
        }
        let contentTop = y

        // Body text — built once, wherever it lands.
        //
        // A message that is nothing but emoji is drawn large — the rule every
        // client shares, and the one that decides whether a lone thumbs-up
        // reads as a reply or as punctuation. The decision is made on the
        // PARSED tree, because `<:blobcat:123>` is not emoji by any character
        // test and `:thumbsup:` was expanded server-side long before this.
        //
        // **`displayedContent`, not `content`.** A message that is nothing but a
        // link to a picture draws the picture — see `Message.displayedContent`.
        // Display only: the words the message actually carries are still what a
        // copy, a search and an accessibility label get.
        // The reader's bubble is their glass, or the accent where they asked
        // for it. A send Discord refused keeps it: in bubbles the failure is
        // Messages' red mark beside it (`BubbleFailure`), and only Discord's
        // columns draw `.isFailed`'s critical ink on the words.
        let ground: MessageBubble.Ground = bubbleSide == .trailing
            ? (input.settings.tintsOwnBubbles ? .accent : .own)
            : .neutral
        let drawnContent = input.settings.showsEmbeds ? message.displayedContent : message.content
        var words: (block: TimelineTextBlock, isJumbo: Bool)?
        if !drawnContent.isEmpty {
            let document = parser.parse(drawnContent)
            let isJumbo = document.jumboEmojiCount != nil
            let sized = isJumbo ? input.style.jumbo : input.style
            let onAccent = bubbleSide != nil && ground == .accent && !isJumbo
            let style = isFailed && bubbleSide == nil ? sized.failed : (onAccent ? sized.onAccentBubble : sized)
            var text = MessageTextBuilder.build(
                document: document,
                context: input.mentions,
                style: style
            )
            // Discord's "(edited)" after the last word, in whatever ink the
            // words are on — see `MessageText.appendingEditedMark`.
            if let editedAt = message.editedAt {
                text = text.appendingEditedMark(at: editedAt, style: style)
            }
            words = (
                TimelineTextBlock(
                    text: text,
                    width: bubbleSide == nil
                        ? contentWidth
                        : max(1, contentWidth - BubbleMetrics.horizontalPadding * 2),
                    style: style,
                    hugsText: bubbleSide != nil
                ),
                isJumbo
            )
        }

        /// The message's own content — everything between the lines above it
        /// and what hangs under it — laid out from `x`.
        ///
        /// **In a bubble the words keep the bubble's padding and everything
        /// else a card's inset**, which is the gap every card already keeps
        /// above itself — so a bubble that opens on a card has its inset there
        /// for nothing, and the content's `width` is how wide the bubble must
        /// be to hold it all.
        func layoutContent(x: CGFloat, top: CGFloat, bubbled: Bool) -> MessageContent {
            let gap = TimelineMetrics.attachmentGap
            let inset: CGFloat = bubbled ? gap : 0
            let cardX = x + inset
            let cardWidth = max(1, contentWidth - inset * 2)
            var content = MessageContent(x: x, top: top, textOrigin: CGPoint(x: x, y: top))
            var y = top
            func holds(_ rect: CGRect) {
                content.width = max(content.width, rect.maxX - x + inset)
                content.hasCards = true
            }

            // The message this one forwards, quoted. **Above the body**,
            // because a forward that carries a note is "here is a thing, and
            // here is what I think of it" — the thing comes first, which is the
            // order every client draws it in.
            if let snapshot = message.forwarded {
                y += inset
                var slot = Self.layoutForward(
                    snapshot,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    input: input,
                    parser: parser
                )
                // **The forward's words are the row's words when it has none
                // of its own** — see `ForwardedSlot.bodyIsRowText`.
                if words == nil, let body = slot.body {
                    slot.bodyIsRowText = true
                    content.forwardText = body
                    content.textOrigin = slot.bodyOrigin
                }
                content.forwarded = slot
                holds(slot.rect)
                y = slot.rect.maxY + gap
            }

            if let words {
                let padding = bubbled ? BubbleMetrics.horizontalPadding : 0
                if bubbled { y += BubbleMetrics.verticalPadding }
                content.textOrigin = CGPoint(x: x + padding, y: y)
                content.width = max(content.width, words.block.size.width + padding * 2)
                y += words.block.size.height
                // The words' own padding is the gap to whatever follows them.
                if bubbled { y += BubbleMetrics.verticalPadding - gap }
            }

            // Stickers, above attachments: a sticker IS the message, and one
            // drawn under a screenshot reads as a caption on it. A Fake Nitro
            // GIF upload that stands for one is drawn as it, in its place.
            let gifStickers = Self.fakeGIFStickers(of: message, in: input)
            for sticker in message.displayedStickers + (gifStickers ?? []) {
                y += gap
                let side = min(Metrics.stickerInline, cardWidth)
                let rect = CGRect(x: cardX, y: y, width: side, height: side)
                content.stickers.append(StickerSlot(
                    rect: rect,
                    sticker: sticker,
                    url: CDN.sticker(id: sticker.id, format: sticker.format),
                    isVector: sticker.format == .lottie,
                    isAnimated: sticker.format.isAnimated
                ))
                holds(rect)
                y = rect.maxY
            }

            // Attachments, which keep their own gap above them. A text file's
            // preview is a hosted card over the room its slot keeps.
            content.attachments = Self.attachmentSlots(
                gifStickers == nil ? message.attachments : [],
                origin: CGPoint(x: cardX, y: y),
                availableWidth: cardWidth,
                style: input.style,
                voiceLook: !bubbled ? .capsule : ground == .accent ? .accentBubble : .bubble,
                textPreviewHeight: { Self.textPreviewHeight($0, width: $1, input: input) }
            )
            for (index, slot) in content.attachments.enumerated() {
                y = max(y, slot.rect.maxY)
                holds(slot.rect)
                if slot.kind == .textPreview {
                    content.hostedCards.append(HostedCardSlot(
                        rect: slot.rect,
                        key: .plaintext(PlaintextCardKey(message.attachments[index]))
                    ))
                }
            }

            if let summary = input.uploads[message.id] {
                y += gap
                let slot = Self.uploadSlot(
                    summary,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.upload = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            if hiddenMediaCount > 0 {
                y += gap
                let slot = Self.hiddenMediaSlot(
                    count: hiddenMediaCount,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.hiddenMedia = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // A poll IS the message: it arrives beside an empty body, so a
            // renderer that does not know about one draws an author line over a
            // blank row.
            if let value = message.poll {
                y += gap
                let slot = PollLayoutEngine.layout(
                    value,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.poll = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // An activity invitation, for the same reason a poll is here: the
            // launch message has no content, no embed and no component, so a
            // renderer that does not know about one draws an author line over a
            // blank row.
            if let value = message.activityInvite {
                y += gap
                let slot = ActivityInviteLayoutEngine.layout(
                    value,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.activityInvite = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // An invitation to listen along, for the same reason: content `""`,
            // and the card is the message.
            if let value = message.listenAlong {
                y += gap
                let slot = ListenAlongLayoutEngine.layout(
                    value,
                    isLive: input.listenAlongLive.contains(value.partyID),
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.listenAlong = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // A custom theme somebody shared — Discord's theme card, under
            // whatever they wrote with it.
            if let theme = message.sharedTheme {
                y += gap
                let author = input.authors[message.authorID]
                let slot = SharedThemeCardLayoutEngine.layout(
                    theme,
                    creatorName: author?.name ?? "Someone",
                    creatorAvatarURL: author?.avatarURL,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.sharedTheme = slot
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // A safety notice in Discord's system DM — the message's one embed,
            // drawn as Discord's own card rather than as an embed's.
            if let notice = SafetyNotice(message) {
                y += gap
                let card = Self.safetyCard(
                    notice,
                    origin: CGPoint(x: cardX, y: y),
                    width: cardWidth,
                    style: input.style
                )
                content.card = card
                holds(card.rect)
                y = card.rect.maxY
            }

            // Embeds. A link unfurl, a bot's status card, a release note — all
            // the same object with different subsets populated, which is why
            // the layout branches on what is present rather than on the `kind`
            // string. Skipped WHOLESALE when the reader has turned unfurls off —
            // not laid out and then hidden. An embed is a framesetting pass over
            // a title, a markdown description and a field grid; measuring one
            // nobody will see is the most expensive way to draw nothing.
            //
            // **A poll result's embed is not drawn**: it is a bag of *fields* —
            // the question, the winner, the counts — that the row's own sentence
            // already says, and drawn as an ordinary card it is a grey box
            // listing `victor_answer_id` at somebody. See `Message.pollResult`.
            // The components are filled by a Components V2 tree — the message's
            // own, below, or an embed's — and by rows of buttons.
            for embed in input.settings.showsEmbeds ? message.drawableEmbeds : [] {
                // A profile or event link's unfurl, where its card is drawn
                // instead — Discord shows the card and not both.
                if let url = embed.url, Self.hasHostedCard(forLink: url, in: input) {
                    continue
                }
                y += gap
                // **An embed of type `components` is its components**: Discord
                // draws the tree in place of a card, and it is laid out exactly
                // as a message's own is, cards and controls both.
                if embed.kind == "components", !embed.components.isEmpty {
                    let tree = ComponentsLayoutEngine.layout(
                        embed.components,
                        origin: CGPoint(x: cardX, y: y),
                        width: min(Metrics.embedMaxWidth, cardWidth),
                        context: ComponentsLayoutEngine.Context(
                            style: input.style,
                            mentions: input.mentions,
                            parser: parser
                        )
                    )
                    content.embeds.append(contentsOf: tree.cards)
                    content.components.append(contentsOf: tree.controls)
                    for rect in tree.cards.map(\.rect) + tree.controls.map(\.rect) { holds(rect) }
                    y = tree.bottom
                    continue
                }
                let slot = EmbedLayoutEngine.layout(
                    embed,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style,
                    mentions: input.mentions,
                    parser: parser,
                    spotify: Self.spotifyCard(for: embed, in: input),
                    footerStamp: embed.timestamp.map { input.settings.timestampLabel($0, calendar: input.calendar) }
                )
                content.embeds.append(slot)
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // The invites the text links to — Discord's invite card, one per
            // code, once the answer has arrived. Until then the link is only a
            // link. An invite that brought an event not yet over is that
            // event's card instead (`346542`'s `ly`), once it has measured.
            for code in InviteCard.codes(in: message.content) {
                guard let lookup = input.invites[code] else { continue }
                if case .resolved(let card) = lookup, let event = card.event, event.status.isLive {
                    let key = EventCardKey(guildID: event.guildID, eventID: event.id, invite: code)
                    if let slot = Self.eventCardSlot(key, x: cardX, y: y + gap, width: cardWidth, input: input) {
                        content.hostedCards.append(slot)
                        holds(slot.rect)
                        y = slot.rect.maxY
                    }
                    continue
                }
                y += gap
                let slot = InviteCardLayoutEngine.layout(
                    code: code,
                    lookup: lookup,
                    sentByReader: input.mentions.selfIDs.contains(message.authorID.rawValue),
                    selfIDs: input.mentions.selfIDs,
                    isExpanded: input.expandedInvites.contains(InviteCardFold(message: message.id, code: code)),
                    palettes: input.palettes,
                    voice: { if case .resolved(let card) = lookup, card.isVoiceChannel {
                        card.channelID.flatMap { input.voiceInvites[$0] }
                    } else { nil } }(),
                    authorID: message.authorID,
                    origin: CGPoint(x: cardX, y: y),
                    availableWidth: cardWidth,
                    style: input.style
                )
                content.inviteCards.append(slot)
                holds(slot.rect)
                y = slot.rect.maxY
            }

            // The events and the profiles the text links to, once each card
            // has measured itself. Until then the link is only a link, exactly
            // as an invite is.
            if !input.hostedCardSizes.isEmpty {
                for link in EventLink.links(in: message.content) {
                    let key = EventCardKey(guildID: link.guildID, eventID: link.eventID, occurrence: link.occurrence)
                    guard let slot = Self.eventCardSlot(key, x: cardX, y: y + gap, width: cardWidth, input: input)
                    else { continue }
                    content.hostedCards.append(slot)
                    holds(slot.rect)
                    y = slot.rect.maxY
                }
                for userID in UserLink.userIDs(in: message.content) {
                    let key = HostedCardKey.user(UserCardKey(userID: userID, guildID: input.guildID))
                    guard let size = input.hostedCardSizes[key]?.latest else { continue }
                    y += gap
                    let slot = HostedCardSlot(
                        rect: CGRect(x: cardX, y: y, width: size.width, height: size.height),
                        key: key
                    )
                    content.hostedCards.append(slot)
                    holds(slot.rect)
                    y = slot.rect.maxY
                }
            }

            // A Components V2 tree, which is the whole body of the message it
            // arrives on. It produces the same two things an embed does — cards
            // and controls — so nothing downstream needs a case for it.
            if !message.displayComponents.isEmpty {
                y += gap
                let tree = ComponentsLayoutEngine.layout(
                    message.displayComponents,
                    origin: CGPoint(x: cardX, y: y),
                    width: min(Metrics.embedMaxWidth, cardWidth),
                    context: ComponentsLayoutEngine.Context(
                        style: input.style,
                        mentions: input.mentions,
                        parser: parser
                    )
                )
                content.embeds.append(contentsOf: tree.cards)
                content.components.append(contentsOf: tree.controls)
                for rect in tree.cards.map(\.rect) + tree.controls.map(\.rect) { holds(rect) }
                y = tree.bottom
            } else if !message.components.isEmpty {
                // The ordinary flat form: rows of buttons under a body or an
                // embed.
                y += TimelineMetrics.componentGap
                y = Self.layoutComponents(
                    message.components,
                    contentX: cardX,
                    y: y,
                    width: cardWidth,
                    style: input.style,
                    into: &content.components
                )
                for slot in content.components { holds(slot.rect) }
            }

            // **No words to set "(edited)" after**: Discord draws it under
            // whatever the message holds (`AFTER_ACCESSORIES`) — and this is
            // no corner case, it is every bot that edits its embed in place.
            if words == nil, content.hasCards, let editedAt = message.editedAt {
                y += gap
                let ink = bubbleSide != nil && ground == .accent ? input.style.onAccentBubble : input.style
                let block = TimelineTextBlock(
                    text: .plain(NSAttributedString(string: MessageText.editedWord, attributes: ink.editedMark)),
                    width: cardWidth,
                    style: ink,
                    hugsText: true
                )
                let origin = CGPoint(x: cardX, y: y)
                content.editedFoot = EditedFootSlot(block: block, origin: origin, editedAt: editedAt)
                holds(CGRect(origin: origin, size: block.size))
                y += block.size.height
            }

            content.isEmpty = words == nil && !content.hasCards
            // The bubble's foot: the words' padding, or a card's inset.
            content.bottom = bubbled && !content.isEmpty ? y + gap : y
            return content
        }

        // **Tapbacks**: a bubble's first few reactions ride its top corner,
        // as Messages pins them, so the bubble steps down to make room for the
        // half that rises above it. More than a few hang under it as chips —
        // a corner holds three before it reads as a pile.
        let wantsTapbacks = bubbleSide != nil
            && (1...TimelineMetrics.tapbackLimit).contains(Self.reactionChipCount(message.reactions))
        if wantsTapbacks { y += TimelineMetrics.tapbackRise }

        // **One bubble holds the whole message** — its words and every card,
        // picture and sticker under them — the way Messages holds a link and
        // its preview in one. **Emoji on their own too** (Alex, 2026-10-26:
        // "emoji-only messages get no bubble"): drawn bare, as Messages draws
        // them, a big emoji stood apart from the conversation it was part of
        // — no plate to say whose side it was on, nowhere for its tapbacks to
        // ride. Only a body with nothing in it at all is left without one.
        let content: MessageContent
        var bubble: MessageBubble?
        if let bubbleSide {
            let probe = layoutContent(x: lane.minX, top: y, bubbled: true)
            if probe.isEmpty {
                content = probe
            } else {
                // A letter or two is a circle rather than a pill pinched at its
                // ends: never narrower than the bubble is tall.
                let height = probe.bottom - y
                let width = min(lane.width, max(probe.width, probe.hasCards ? 0 : height))
                let x = lane.isTrailing && width < lane.width - 0.5 ? lane.maxX - width : probe.x
                // **Under its own caption the badges rise beside the name**
                // rather than pushing the bubble away from it (Alex,
                // 2026-11-16: the name "raised up" over a bubble with a
                // tapback). The step down is for a bubble above, which the
                // badges would land on; a caption only needs them clear of
                // its words, so the bubble keeps its place unless the name
                // reaches across to where they sit.
                var top = y
                if wantsTapbacks, let captionSpan {
                    let badges = Self.layoutTapbacks(
                        message.reactions,
                        bubble: CGRect(x: x, y: y, width: width, height: height),
                        side: bubbleSide,
                        rowWidth: input.width,
                        style: input.style
                    )
                    let reach = (badges.map(\.rect.minX).min() ?? 0)...(badges.map(\.rect.maxX).max() ?? 0)
                    let clear = reach.lowerBound - BubbleMetrics.tapbackCaptionClearance > captionSpan.upperBound
                        || reach.upperBound + BubbleMetrics.tapbackCaptionClearance < captionSpan.lowerBound
                    if clear { top -= TimelineMetrics.tapbackRise }
                }
                // Laid out again only to move it: every piece here is the same
                // at any origin, so the second pass breaks no line differently.
                var laid = x != probe.x || top != y
                    ? layoutContent(x: x, top: top, bubbled: true)
                    : probe
                let rect = CGRect(x: laid.x, y: top, width: width, height: height)
                if let words, !laid.hasCards {
                    laid.textOrigin.x = rect.minX + ((rect.width - words.block.size.width) / 2).rounded()
                }
                content = laid
                bubble = MessageBubble(
                    rect: rect,
                    ground: ground,
                    hasTail: item.isRunTail,
                    path: BubbleShape.path(
                        body: rect,
                        radius: BubbleMetrics.cornerRadius(for: input.style.bodyFont),
                        tail: item.isRunTail ? bubbleSide : nil
                    )
                )
            }
        } else {
            content = layoutContent(x: contentX, top: y, bubbled: false)
        }
        // Where the message's own content ends — the face beside a run's last
        // bubble sits on it, rather than on reactions hanging under it.
        y = content.bottom
        let bodyBottom = y

        // A refused send of the reader's own: the disc beside the bubble,
        // centred on it, and the caption under its trailing edge.
        var failure: BubbleFailure?
        if isFailed, bubbleSide == .trailing, let shape = bubble?.rect {
            let side = BubbleMetrics.failureBadgeSide
            let font = input.style.metadataFont
            let captionSize = CGSize(
                width: Self.measure(BubbleFailure.caption, font: font),
                height: ceil(font.ascender - font.descender)
            )
            let mark = BubbleFailure(
                badge: CGRect(
                    x: shape.maxX + BubbleMetrics.tailReach + BubbleMetrics.failureGap,
                    y: (shape.midY - side / 2).rounded(),
                    width: side,
                    height: side
                ),
                caption: CGRect(
                    x: shape.maxX - captionSize.width,
                    y: shape.maxY + BubbleMetrics.failureCaptionGap,
                    width: captionSize.width,
                    height: captionSize.height
                )
            )
            failure = mark
            y = mark.caption.maxY
        }

        // Reactions: tapbacks on the bubble's corner, with a gap cut round
        // each into the bubble; or chips under the content.
        let reactionRow: (chips: [ReactionSlot], controls: [ReactionControlSlot], bottom: CGFloat)
        if wantsTapbacks, let bubbleSide, let shape = bubble {
            let badges = Self.layoutTapbacks(
                message.reactions,
                bubble: shape.rect,
                side: bubbleSide,
                rowWidth: input.width,
                style: input.style
            )
            bubble?.path = Self.notched(shape.path, around: badges)
            reactionRow = (badges, [], y)
        } else {
            reactionRow = placed({ x -> (chips: [ReactionSlot], controls: [ReactionControlSlot], bottom: CGFloat) in
                var chips: [ReactionSlot] = []
                var controls: [ReactionControlSlot] = []
                let bottom = Self.layoutReactions(
                    message.reactions,
                    contentX: x,
                    y: y,
                    width: contentWidth,
                    style: input.style,
                    // Discord never offers a bookmark on the reader's own message.
                    offersBookmark: !input.mentions.selfIDs.contains(message.authorID.rawValue),
                    into: &chips,
                    controls: &controls
                )
                return (chips, controls, bottom)
            }, width: { extent($0.chips.map(\.rect) + $0.controls.map(\.rect)) })
        }
        let reactions = reactionRow.chips
        let reactionControls = reactionRow.controls
        y = reactionRow.bottom

        // The thread this message started, under its content and above the
        // ephemeral note — it is about the message, and the note is about the
        // whole row.
        let chip = placed({
            Self.layoutThreadChip(
                message.thread,
                contentX: $0,
                y: y,
                width: contentWidth,
                style: input.style
            )
        }, width: { $0.slot?.rect.width ?? 0 })
        y = chip.bottom

        // "Only you can see this", last — under everything, which is where a
        // note about the whole message belongs and where Discord's own is.
        var ephemeralNote: EphemeralNoteSlot?
        if message.isEphemeral {
            let font = input.style.metadataFont
            let noteWidth = Self.measure(Self.ephemeralNoteText, font: font)
            let dismissWidth = Self.measure(Self.ephemeralDismissText, font: font)
            let lineWidth = TimelineMetrics.ephemeralNoteGlyphRoom + noteWidth
                + TimelineMetrics.ephemeralNoteSeparatorRoom + dismissWidth
            let noteX = lane.x(forWidth: lineWidth)
            let top = y + TimelineMetrics.ephemeralNoteGap
            // The control's own rect, measured rather than derived from the
            // line's: it is the only part that takes a click, and a target that
            // spans the note would dismiss the message on a click meant for
            // nothing at all.
            let dismissRect = CGRect(
                x: noteX + lineWidth - dismissWidth,
                y: top,
                width: dismissWidth,
                height: TimelineMetrics.ephemeralNoteHeight
            )
            ephemeralNote = EphemeralNoteSlot(
                rect: CGRect(
                    x: noteX,
                    y: top,
                    width: lineWidth,
                    height: TimelineMetrics.ephemeralNoteHeight
                ),
                text: Self.ephemeralNoteText,
                dismissRect: dismissRect,
                dismissText: Self.ephemeralDismissText
            )
        }

        // **The bubble arrangement's two remaining pieces, both placed against
        // the content.** The face beside the last bubble of somebody's run,
        // sitting on the content's foot as Messages' does; and the time, on
        // the side the content leaves open, centred on the bubble when there
        // is one.
        var bubbleRow: BubbleRow?
        if let bubbleSide {
            if namesAuthor, item.isRunTail {
                let side = BubbleMetrics.avatarSide
                avatarRect = CGRect(
                    x: TimelineMetrics.horizontalMargin,
                    y: max(contentTop, bodyBottom - side),
                    width: side,
                    height: side
                )
            }
            var timeRect = CGRect.zero
            if !content.isEmpty {
                let font = input.style.metadataFont
                let size = CGSize(
                    width: Self.measure(input.settings.time(message.sentAt), font: font),
                    height: ceil(font.ascender - font.descender)
                )
                let anchor = bubble?.rect ?? content.bounds
                // Level with the first line: the middle of a one-line bubble,
                // the top line of a taller one — where the pill hangs too. Under
                // the tapbacks, which share that side of the corner.
                let band = min(anchor.height, BubbleMetrics.cornerRadius(for: input.style.bodyFont) * 2)
                var timeY = (anchor.minY + band / 2 - size.height / 2).rounded()
                if let badges = reactions.filter(\.isTapback).map(\.rect.maxY).max() {
                    timeY = max(timeY, (badges + 2).rounded())
                }
                timeRect = CGRect(
                    x: bubbleSide == .trailing
                        ? anchor.minX - BubbleMetrics.timeGap - size.width
                        : anchor.maxX + BubbleMetrics.timeGap,
                    y: timeY,
                    width: size.width,
                    height: size.height
                )
            }
            bubbleRow = BubbleRow(side: bubbleSide, bubble: bubble, timeRect: timeRect, failure: failure)
        }

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            hasAuthorLine: hasAuthorLine,
            mentionsMe: item.flags.contains(.mentionsMe),
            isPending: item.flags.contains(.pending),
            isFailed: item.flags.contains(.failed),
            avatarRect: avatarRect,
            avatarURL: author?.avatarURL,
            avatarMonogram: author?.monogram ?? "?",
            decorationURL: author?.decorationURL,
            replyHeader: replyHeader,
            interactionHeader: interactionHeader,
            ephemeralNote: ephemeralNote,
            authorName: author?.name ?? "Unknown",
            // The face the name was measured in — a caption's in bubbles.
            authorFace: isCaption ? nameFace : author?.nameFace,
            authorTracking: nameTracking,
            authorGradient: hasAuthorLine
                ? author?.gradient.map { $0.map { NSColor(Color(hex: $0)) } }
                : nil,
            authorStyle: hasAuthorLine ? author?.nameStyle : nil,
            authorColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            authorRect: authorRect,
            // In bubbles the run head carries no time: every bubble shows its
            // own beside it — `BubbleRow.timeRect`.
            timestampText: bubbleSide == nil
                ? input.settings.timestampLabel(message.sentAt, calendar: input.calendar)
                : "",
            timestampRect: timestampRect,
            gutterTimestampText: input.settings.time(message.sentAt),
            authorTag: authorTag,
            isCrosspost: message.isCrosspost,
            tag: hasAuthorLine ? author?.tag : nil,
            tagBadgeURL: hasAuthorLine ? author?.tagBadgeURL : nil,
            tagRect: tagRect,
            roleIconURL: hasAuthorLine ? author?.roleIconURL : nil,
            roleEmoji: hasAuthorLine ? author?.roleEmoji : nil,
            roleIconRect: roleIconRect,
            forwarded: content.forwarded,
            textBlock: words?.block ?? content.forwardText,
            textOrigin: content.textOrigin,
            editedFoot: content.editedFoot,
            attachments: content.attachments,
            upload: content.upload,
            hiddenMedia: content.hiddenMedia,
            stickers: content.stickers,
            embeds: content.embeds,
            components: content.components,
            poll: content.poll,
            activityInvite: content.activityInvite,
            listenAlong: content.listenAlong,
            sharedTheme: content.sharedTheme,
            inviteCards: content.inviteCards,
            hostedCards: content.hostedCards,
            reactions: reactions,
            reactionControls: reactionControls,
            card: content.card,
            threadChip: chip.slot,
            bubbles: bubbleRow,
            accessibilityLabel: Self.accessibilityLabel(
                author: author?.name ?? "Unknown",
                time: input.settings.time(message.sentAt),
                body: words?.block.text.plainLabel ?? "",
                attachments: message.attachments.count,
                stickers: content.stickers.map(\.sticker.name),
                extra: Self.spokenBody(of: message),
                isEphemeral: message.isEphemeral,
                isEdited: message.editedAt != nil,
                isFailed: isFailed,
                reactions: message.reactions,
                muted: input.settings.mutedSpokenDetails
            )
        )
    }

    /// A fold's line, laid out on a system message's frame: the same top, the
    /// same text column, the glyph in the same place before it.
    private static func collapsedGroup(_ group: CollapsedGroup, input: Input) -> CollapsedGroupSlot {
        let style = input.style
        let sentence = CollapsedGroupSlot.sentence(for: group)
        let lead = group.canOpen ? sentence + " \u{2014} " : sentence
        let text = MessageText.plain(NSAttributedString(string: lead, attributes: [
            .font: style.bodyFont,
            // Discord's `blockedMessageText` reads in the default ink; a fold
            // with no Show in the muted one, `blockedMessageTextMuted`.
            .foregroundColor: group.canOpen ? style.primaryColor : style.secondaryColor,
        ]))
        let x = TimelineMetrics.contentInset
        let y = input.settings.runSpacing
        let block = TimelineTextBlock(
            text: text,
            width: max(80, input.width - x - TimelineMetrics.horizontalMargin),
            style: style,
            hugsText: true
        )
        var action: CollapsedGroupSlot.Action?
        if group.canOpen {
            let word = group.isOpen ? "Hide" : "Show"
            func laid(_ color: NSColor) -> TimelineTextBlock {
                TimelineTextBlock(
                    text: .plain(NSAttributedString(string: word, attributes: [
                        .font: style.bodyFont,
                        .foregroundColor: color,
                    ])),
                    width: max(40, input.width - x - block.size.width - TimelineMetrics.horizontalMargin),
                    style: style,
                    hugsText: true
                )
            }
            let quiet = laid(style.tertiaryColor)
            action = CollapsedGroupSlot.Action(
                word: word,
                rect: CGRect(origin: CGPoint(x: x + block.size.width, y: y), size: quiet.size),
                quiet: quiet,
                lit: laid(style.linkColor)
            )
        }
        return CollapsedGroupSlot(
            group: group,
            symbolName: CollapsedGroupSlot.symbolName(for: group.reason),
            text: block,
            textOrigin: CGPoint(x: x, y: y),
            action: action,
            accessibilityLabel: action.map { "\(sentence), \($0.word)" } ?? sentence
        )
    }

    /// A message nobody typed: a join, a boost, a pin, a call.
    ///
    /// **The words are the client's, and without them the row is blank.** These
    /// arrive with `content: ""` — a renderer that only knows how to draw
    /// content puts an avatar, a name and a timestamp over an empty space, which
    /// on a `#welcome` channel is the whole channel.
    ///
    /// Drawn compactly: a tinted glyph where the avatar would be, one sentence
    /// with the member's name in their colour, and the time inline after it. A
    /// system event is a fact about the channel rather than something somebody
    /// said, and giving it a full author header makes a hundred joins look like
    /// a hundred conversations.
    private func buildSystemMessage(
        _ item: TimelineMessage,
        input: Input
    ) -> MessageRow {
        let message = item.message
        // A Server Hub line is about somebody other than its author — the
        // leader, the top listener — and draws that person's name in their
        // colour, clicking through to them.
        let namedID = message.kind == .guildSpace
            ? message.guildSpaceData?.subjectUserID ?? message.authorID
            : message.authorID
        let author = input.authors[namedID]
        let name = author?.name ?? "Someone"
        let sentence = SystemMessageText.sentence(for: message, name: name, nameOf: { input.authors[$0]?.name })
        let y = input.settings.runSpacing

        let text = Self.systemText(
            sentence,
            authorID: namedID,
            colorValue: author?.colorValue,
            nameFace: author?.nameFace,
            nameTracking: author?.nameTracking ?? 0,
            time: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
            style: input.style
        )
        // **Centred in bubbles**, glyph and all, as Messages centres the lines
        // that are about the conversation rather than in it. The glyph sits a
        // gutter's gap before the words in both arrangements — the painter
        // places it from `textOrigin`.
        let isCentred = input.arrangement != .columns
        let glyphRoom = TimelineMetrics.systemGlyphSide + TimelineMetrics.avatarGap
        let margin = TimelineMetrics.horizontalMargin
        let blockWidth = isCentred
            ? max(80, input.width - margin * 2 - glyphRoom)
            : max(80, input.width - TimelineMetrics.contentInset - margin)
        let block = TimelineTextBlock(text: text, width: blockWidth, style: input.style, hugsText: isCentred)
        let contentX = isCentred
            ? ((input.width - block.size.width + glyphRoom) / 2).rounded()
            : TimelineMetrics.contentInset
        let contentWidth = max(80, input.width - contentX - margin)
        let systemName = Self.systemNameSlot(
            sentence: sentence,
            author: author,
            block: block,
            origin: CGPoint(x: contentX, y: y),
            input: input,
            unnamed: {
                // Laid out exactly as the sentence was, so every line breaks
                // in the same place and only the name's ink differs.
                TimelineTextBlock(
                    text: Self.systemText(
                        sentence,
                        authorID: message.authorID,
                        colorValue: author?.colorValue,
                        nameFace: author?.nameFace,
                        nameTracking: author?.nameTracking ?? 0,
                        time: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
                        style: input.style,
                        clearsName: true
                    ),
                    width: blockWidth,
                    style: input.style,
                    hugsText: isCentred
                )
            }
        )

        // The card of the event a stage start announced, under its line —
        // Discord's embed after `STAGE_START`, while that event is on.
        var hostedCards: [HostedCardSlot] = []
        var below = y + block.size.height
        if let eventID = Self.stageStartEvent(of: message, in: input), let live = input.liveEvent {
            let width = min(Metrics.embedMaxWidth, contentWidth).rounded(.down)
            if let slot = Self.eventCardSlot(
                EventCardKey(guildID: live.guildID, eventID: eventID),
                x: isCentred ? ((input.width - width) / 2).rounded() : contentX,
                y: below + TimelineMetrics.attachmentGap,
                width: width,
                input: input
            ) {
                hostedCards.append(slot)
                below = slot.rect.maxY
            }
        }

        // A join message can be reacted to like any other, and dropping them
        // would be dropping data the payload already carries.
        var reactions: [ReactionSlot] = []
        var reactionControls: [ReactionControlSlot] = []
        let reactionsBottom = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: below,
            width: contentWidth,
            style: input.style,
            // Discord never offers a bookmark on the reader's own message.
            offersBookmark: !input.mentions.selfIDs.contains(message.authorID.rawValue),
            into: &reactions,
            controls: &reactionControls
        )

        // **A THREAD_CREATED system message carries the thread it announces.**
        // Without the chip the sentence names a thread with no way to open it,
        // which is the one thing that line exists to offer.
        let systemChip = Self.layoutThreadChip(
            message.thread,
            contentX: contentX,
            y: reactionsBottom,
            width: contentWidth,
            style: input.style
        )
        // Discord's Invite to Speak under a hand that is still up, for a
        // reader who may answer it.
        let inviteCard = message.kind == .stageRaiseHand && input.stageInvitations.contains(message.id)
            ? Self.stageInviteCard(
                for: message.authorID,
                origin: CGPoint(x: contentX, y: systemChip.bottom + TimelineMetrics.threadChipGap),
                style: input.style
            )
            : nil

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            hasAuthorLine: false,
            mentionsMe: item.flags.contains(.mentionsMe),
            isPending: false,
            isFailed: false,
            avatarRect: nil,
            avatarURL: nil,
            avatarMonogram: "",
            decorationURL: nil,
            authorName: name,
            authorColor: nil,
            authorRect: CGRect(x: contentX, y: y, width: 0, height: 0),
            timestampText: "",
            timestampRect: .zero,
            gutterTimestampText: "",
            textBlock: block,
            textOrigin: CGPoint(x: contentX, y: y),
            attachments: [],
            stickers: [],
            embeds: [],
            components: [],
            poll: nil,
            activityInvite: nil,
            hostedCards: hostedCards,
            reactions: reactions,
            reactionControls: reactionControls,
            card: inviteCard,
            threadChip: systemChip.slot,
            systemSymbol: sentence?.symbolName ?? "circle",
            systemTint: Self.tintColor(sentence?.tint),
            systemName: systemName,
            accessibilityLabel: text.plainLabel
        )
    }

    /// The DM-only lit name of a system line, or nil — see `SystemNameSlot`.
    private static func systemNameSlot(
        sentence: SystemSentence?,
        author: TimelineLayoutEngine.AuthorInfo?,
        block: TimelineTextBlock,
        origin: CGPoint,
        input: Input,
        unnamed: () -> TimelineTextBlock
    ) -> SystemNameSlot? {
        // A server's line keeps the face alone; the style is a DM's. (The
        // author table carries no style in a server either.)
        guard input.guildID == nil,
              let sentence, !sentence.name.isEmpty,
              let worn = author?.nameStyle
        else { return nil }
        let start = (sentence.prefix as NSString).length
        let length = (sentence.name as NSString).length
        guard length > 0,
              let first = block.baselineOrigin(at: start),
              let last = block.baselineOrigin(at: start + length - 1),
              abs(first.y - last.y) < 0.5
        else { return nil }
        let size = input.style.boldFont.pointSize
        let face = author?.nameFace.map { NSFont(descriptor: $0.fontDescriptor, size: size) ?? $0 }
            ?? input.style.boldFont
        let tracking = author?.nameFace.map { (author?.nameTracking ?? 0) * size / max(1, $0.pointSize) } ?? 0
        let width = NSAttributedString(string: sentence.name, attributes: [
            .font: face,
            .kern: tracking,
        ]).size().width
        return SystemNameSlot(
            style: worn,
            name: sentence.name,
            face: face,
            tracking: tracking,
            origin: CGPoint(x: origin.x + first.x, y: origin.y + first.y - face.ascender),
            width: ceil(width),
            unnamedBlock: unnamed()
        )
    }

    /// The sentence, with the name coloured and clickable and the time after it.
    ///
    /// Built as one attributed string rather than three drawn runs so it wraps
    /// as a sentence — a long nickname on a narrow column has to break like
    /// prose, not leave the verb hanging off the edge.
    private static func systemText(
        _ sentence: SystemSentence?,
        authorID: UserID,
        colorValue: UInt32?,
        nameFace: NSFont? = nil,
        nameTracking: CGFloat = 0,
        time: String,
        style: MessageTextStyle,
        clearsName: Bool = false
    ) -> MessageText {
        // **The member's own face, in a welcome as in a message.** Discord sets
        // the name in a system line through the same font class a message
        // header takes (`447215`), so somebody who chose a face is greeted in
        // it. The face arrives at the header's size and is set at this line's.
        let nameFont = nameFace.map {
            NSFont(descriptor: $0.fontDescriptor, size: style.boldFont.pointSize) ?? $0
        } ?? style.boldFont
        let nameKern = nameFace.map { nameTracking * style.boldFont.pointSize / max(1, $0.pointSize) } ?? 0
        let body: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.secondaryColor,
        ]
        let output = NSMutableAttributedString()
        var links: [MessageText.LinkRun] = []

        guard let sentence else {
            output.append(NSAttributedString(string: "Message", attributes: body))
            return .plain(output)
        }

        output.append(NSAttributedString(string: sentence.prefix, attributes: body))
        if !sentence.name.isEmpty {
            let start = output.length
            var named: [NSAttributedString.Key: Any] = [
                .font: nameFont,
                .foregroundColor: clearsName ? NSColor.clear
                    : colorValue.map { NSColor(Color(hex: $0)) } ?? style.primaryColor,
            ]
            if nameKern != 0 { named[.kern] = nameKern }
            output.append(NSAttributedString(string: sentence.name, attributes: named))
            links.append(.init(
                range: NSRange(location: start, length: output.length - start),
                target: .user(authorID)
            ))
        }
        output.append(NSAttributedString(string: sentence.suffix, attributes: body))
        if !sentence.emphasis.isEmpty {
            output.append(NSAttributedString(string: sentence.emphasis, attributes: [
                .font: style.boldFont,
                .foregroundColor: style.primaryColor,
            ]))
        }
        output.append(NSAttributedString(string: "  " + time, attributes: [
            .font: style.metadataFont,
            .foregroundColor: style.tertiaryColor,
        ]))
        return .plain(output, links: links)
    }

    /// Discord's secondary button with the microphone, under "requested to
    /// speak." — the whole plate is the control, and its words light under
    /// the pointer as this transcript's other card buttons do.
    private static func stageInviteCard(
        for userID: UserID,
        origin: CGPoint,
        style: MessageTextStyle
    ) -> DrawnCard {
        var writer = DrawnCardWriter(style: style)
        let title = "Invite to Speak"
        let pad: CGFloat = 12
        let icon = DrawnCardMetrics.icon
        let gap: CGFloat = 6
        let label = writer.block(title, font: writer.smallMedium, color: style.primaryColor, width: 10_000)
        let lit = writer.block(title, font: writer.smallMedium, color: style.primaryColor, width: 10_000, underlined: true)
        let plate = CGRect(
            x: origin.x,
            y: origin.y,
            width: (pad + icon + gap + label.size.width + pad).rounded(.up),
            height: 32
        )
        writer.card.parts.append(.ground(plate, .plate, .all, radius: DrawnCardMetrics.corner))
        writer.card.parts.append(.symbol(
            "mic.fill",
            CGRect(x: plate.minX + pad, y: plate.midY - icon / 2, width: icon, height: icon),
            .primary
        ))
        let labelOrigin = CGPoint(
            x: plate.minX + pad + icon + gap,
            y: (plate.midY - label.size.height / 2).rounded()
        )
        writer.card.controls.append(DrawnCard.Control(
            action: .inviteToSpeak(userID),
            rect: plate,
            label: label,
            litLabel: lit,
            labelOrigin: labelOrigin,
            accessibilityLabel: title
        ))
        writer.card.rect = plate
        return writer.card
    }

    private static func tintColor(_ tint: SystemSentence.Tint?) -> NSColor {
        switch tint {
        case .affirmative: NSColor(Palette.presenceOnline)
        case .celebratory: NSColor(Palette.accent)
        case .destructive: NSColor(Palette.unreadBadge)
        case .quiet, nil: NSColor.tertiaryLabelColor
        }
    }

    /// The reaction chips under a message, wrapped to the column.
    ///
    /// Shared by the ordinary row and the system one — a join message can be
    /// reacted to like any other, and a second copy of this arithmetic is a
    /// second place for the chip width to drift from what the painter draws.
    ///
    /// Returns the y the next thing starts at, unchanged when there is nothing
    /// to lay out.
    /// The quoted line above a reply.
    ///
    /// **One line, measured and then clipped rather than wrapped.** A quote is
    /// a pointer to a message, not a copy of it: a header that wrapped would
    /// push the reply down the page by an amount decided by somebody else's
    /// typing, and the row it belongs to would move whenever that message was
    /// edited. The painter truncates with a tail; this reserves the strip.
    ///
    /// The name is drawn in the quoted author's own face at the quote's size —
    /// resized from the resolved face rather than looked up again, because the
    /// registry is main-actor state and this runs off it.
    ///
    /// - Parameters:
    ///   - leadingX: where the quoted face starts.
    ///   - maxX: where the quote must stop.
    ///   - elbowX: where the elbow rises from, or nil for a line with none.
    ///   - isCompact: the compact layout, where Discord draws the badge in
    ///     place of every face.
    private static func layoutReplyHeader(
        _ reference: MessageReference,
        y: CGFloat,
        leadingX: CGFloat,
        maxX: CGFloat,
        elbowX: CGFloat?,
        isCompact: Bool,
        style: MessageTextStyle,
        author: AuthorInfo?
    ) -> ReplyHeaderSlot {
        let height = TimelineMetrics.replyHeight
        let avatarRect = CGRect(
            x: leadingX,
            y: y + (height - TimelineMetrics.replyAvatarSide) / 2,
            width: TimelineMetrics.replyAvatarSide,
            height: TimelineMetrics.replyAvatarSide
        )

        let quoteFont = style.metadataFont
        let isUnavailable = reference.isUnavailable
        let name = isUnavailable ? "" : "@" + (author?.name ?? "Unknown")
        // Resized from the face already resolved for this person, which costs a
        // descriptor lookup rather than a registration.
        let face = author?.nameFace.map {
            NSFont(descriptor: $0.fontDescriptor, size: quoteFont.pointSize) ?? quoteFont
        }
        let tracking = face == nil
            ? 0
            : (author?.nameTracking ?? 0) * (quoteFont.pointSize / max(1, style.authorFont.pointSize))
        let nameWidth = measure(name, font: face ?? quoteFont, tracking: tracking)
        let nameRect = CGRect(
            x: avatarRect.maxX + TimelineMetrics.replyItemGap,
            y: y,
            width: nameWidth,
            height: height
        )

        // What the quote says. A message that was only a picture still has to
        // be quotable, and a reference with nothing behind it says so in words
        // rather than leaving a blank strip nobody can read — in Discord's two
        // sentences, because "deleted" is only what Discord said when it sent
        // `null`, and a quote it never looked up may be there all along.
        let quote: String
        if isUnavailable {
            quote = reference.isDeleted ? "Original message was deleted" : "Message could not be loaded"
        } else if author?.isBlocked == true {
            quote = "Blocked message"
        } else if author?.isIgnored == true {
            quote = "Ignored message"
        } else if !reference.excerpt.isEmpty {
            quote = reference.excerpt
        } else if reference.hasAttachment {
            quote = "Click to see attachment"
        } else {
            quote = ""
        }
        // **The badge stands where the face would**, for every quote whose face
        // Discord will not show: nobody to show, somebody blocked, or the
        // compact layout (its reply header's `replyBadge`).
        let showsBadge = isUnavailable || author?.isBlocked == true || isCompact
        let excerptX = isUnavailable
            ? avatarRect.maxX + TimelineMetrics.replyItemGap
            : nameRect.maxX + TimelineMetrics.replyItemGap
        let excerptRect = CGRect(
            x: excerptX,
            y: y,
            width: max(0, maxX - excerptX),
            height: height
        )

        // The strip's own bounds: from the elbow — or the face, where there is
        // none — to wherever the quote ends, so a click anywhere along the line
        // it draws lands on it.
        let excerptFont = quote == reference.excerpt ? quoteFont : style.metadataItalicFont
        let quoteWidth = quote.isEmpty
            ? 0
            : min(excerptRect.width, measure(quote, font: excerptFont))
        let start = elbowX ?? leadingX
        let rect = CGRect(
            x: start,
            y: y,
            width: max(0, excerptX + quoteWidth - start),
            height: height
        )

        return ReplyHeaderSlot(
            rect: rect,
            // The elbow's leg drops to the top of the avatar under it, which is
            // where the author line begins — the connector then reads as coming
            // out of the face rather than as a bracket floating beside it.
            elbowBottom: elbowX.map { _ in y + height + TimelineMetrics.replyGap },
            avatarRect: showsBadge ? .zero : avatarRect,
            avatarURL: author?.avatarURL,
            monogram: author?.monogram ?? "?",
            name: name,
            nameRect: nameRect,
            nameFace: face,
            nameTracking: tracking,
            nameColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            excerpt: quote,
            excerptRect: excerptRect,
            excerptFont: excerptFont,
            badgeRect: showsBadge ? avatarRect : .zero,
            isBot: reference.isAuthorBot,
            // Only a quote Discord said is gone goes nowhere: one it never
            // fetched still jumps to where it would be (`m = state !== DELETED`).
            targetID: isUnavailable && reference.isDeleted ? nil : reference.messageID
        )
    }

    /// The thread chip under a message that started one.
    ///
    /// Returns the y the next thing starts at, exactly as the reaction row does.
    private static func layoutThreadChip(
        _ thread: MessageThread?,
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle
    ) -> (slot: ThreadChipSlot?, bottom: CGFloat) {
        guard let thread else { return (nil, startY) }

        let y = startY + TimelineMetrics.threadChipGap
        let countText = thread.messageCount == 1
            ? "1 Message"
            : "\(thread.messageCount) Messages"
        let nameWidth = measure(thread.name, font: style.authorFont)
        let countWidth = measure(countText, font: style.metadataFont)

        let natural = TimelineMetrics.threadChipLeadingInset
            + nameWidth + TimelineMetrics.threadChipLabelGap + countWidth
            + TimelineMetrics.threadChipChevronRoom
            + TimelineMetrics.threadChipTrailingInset
        // Clamped at both ends: never wider than the column it sits in, never
        // wider than the cap, and never narrower than the room the chevron needs
        // on its own.
        let chipWidth = min(natural, min(width, TimelineMetrics.threadChipMaxWidth))

        return (
            ThreadChipSlot(
                rect: CGRect(
                    x: contentX + TimelineMetrics.threadChipIndent,
                    y: y,
                    width: chipWidth,
                    height: TimelineMetrics.threadChipHeight
                ),
                targetID: thread.id,
                name: thread.name,
                countText: countText,
                nameWidth: nameWidth
            ),
            y + TimelineMetrics.threadChipHeight
        )
    }

    static func layoutReactions(
        _ reactions: [Reaction],
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        offersBookmark: Bool,
        into slots: inout [ReactionSlot],
        controls: inout [ReactionControlSlot]
    ) -> CGFloat {
        guard !reactions.isEmpty else { return startY }
        var y = startY + TimelineMetrics.reactionGap
        var x = contentX

        func place(
            _ reaction: Reaction,
            kind: ReactionKind,
            imageURL: URL?,
            palette: SuperReactionPalette?
        ) {
            let count = reaction.count(of: kind)
            // Built from the same parts the painter draws, so the chip cannot be
            // narrower than its own contents.
            let chipWidth = TimelineMetrics.reactionChipWidth(
                countWidth: measure("\(count)", font: TimelineMetrics.reactionCountFont(style))
            )
            if x + chipWidth > contentX + width, x > contentX {
                x = contentX
                y += TimelineMetrics.reactionChipHeight + TimelineMetrics.reactionSpacing
            }
            slots.append(ReactionSlot(
                rect: CGRect(
                    x: x, y: y,
                    width: chipWidth, height: TimelineMetrics.reactionChipHeight
                ),
                emoji: reaction.emoji,
                kind: kind,
                count: count,
                isMine: reaction.isMine(kind),
                imageURL: imageURL,
                palette: palette
            ))
            x += chipWidth + TimelineMetrics.reactionSpacing
        }

        for reaction in reactions {
            // **At the side the chip draws it**, which is also the key the
            // painter peeks and the prefetch asks for. This used to ask the CDN
            // for a 16-point rendition and draw it at 19.
            let imageURL = reaction.emoji.id.flatMap {
                CDN.emoji(
                    id: $0,
                    animated: reaction.emoji.isAnimated,
                    side: TimelineMetrics.reactionGlyphSide
                )
            }
            if reaction.burstCount > 0 {
                place(
                    reaction, kind: .burst, imageURL: imageURL,
                    palette: SuperReactionPalette(colors: reaction.burstColors)
                )
            }
            if reaction.count > 0 {
                place(reaction, kind: .normal, imageURL: imageURL, palette: nil)
            }
        }

        // The two controls follow the last chip rather than being pinned to
        // the row's end: a message with eight reactions on a narrow column ends
        // its last line wherever it ends, and a control pinned to the right of
        // the measure would sit alone under a gap.
        //
        // **They never get a line to themselves.** They are drawn only while
        // the pointer is on the message (`visibleReactionControls`), so a line
        // holding nothing else would be a blank band under every such message
        // at rest. Where they do not fit after the last chip, that chip comes
        // down with them — the line then has a chip on it either way.
        let kinds: [ReactionControlSlot.Kind] = offersBookmark ? [.addReaction, .bookmark] : [.addReaction]
        let side = TimelineMetrics.reactionControlSide
        let controlsWidth = CGFloat(kinds.count) * side + CGFloat(kinds.count - 1) * 4
        if x + controlsWidth > contentX + width, x > contentX {
            y += TimelineMetrics.reactionChipHeight + TimelineMetrics.reactionSpacing
            if let last = slots.indices.last, slots[last].rect.minX > contentX {
                slots[last].rect.origin = CGPoint(x: contentX, y: y)
                x = contentX + slots[last].rect.width + TimelineMetrics.reactionSpacing
            } else {
                // The one case left: a chip so wide it fills its line alone.
                x = contentX
            }
        }
        for kind in kinds {
            controls.append(ReactionControlSlot(
                rect: CGRect(x: x, y: y, width: side, height: side),
                kind: kind
            ))
            x += side + 4
        }
        return y + TimelineMetrics.reactionChipHeight
    }

    /// How many chips `reactions` make: one per kind an emoji has, so an
    /// emoji with super and plain reactions is two.
    static func reactionChipCount(_ reactions: [Reaction]) -> Int {
        reactions.reduce(0) { $0 + ($1.burstCount > 0 ? 1 : 0) + ($1.count > 0 ? 1 : 0) }
    }

    /// A bubble's reactions as Messages' tapbacks: badges on its top corner on
    /// the side facing the conversation — the leading corner of the reader's
    /// own, the trailing corner of everybody else's — the first on the corner
    /// and the rest leading away from the bubble, in the chips' own order.
    static func layoutTapbacks(
        _ reactions: [Reaction],
        bubble: CGRect,
        side: BubbleRow.Side,
        rowWidth: CGFloat,
        style: MessageTextStyle
    ) -> [ReactionSlot] {
        let height = TimelineMetrics.tapbackSide
        let corner = TimelineMetrics.tapbackCornerInset
        let minY = bubble.minY + corner.height - height / 2
        // The edge of the next badge nearest the bubble.
        var edge = side == .trailing
            ? bubble.minX + corner.width + height / 2
            : bubble.maxX - corner.width - height / 2
        var slots: [ReactionSlot] = []

        func place(_ reaction: Reaction, kind: ReactionKind, imageURL: URL?, palette: SuperReactionPalette?) {
            let count = reaction.count(of: kind)
            // A count only where there is more than one: a single tapback is
            // a circle round its emoji, as Messages draws it.
            let width = TimelineMetrics.tapbackWidth(
                countWidth: count > 1 ? measure("\(count)", font: style.metadataFont) : nil
            )
            let minX = side == .trailing ? edge - width : edge
            slots.append(ReactionSlot(
                rect: CGRect(x: minX, y: minY, width: width, height: height),
                emoji: reaction.emoji,
                kind: kind,
                count: count,
                isMine: reaction.isMine(kind),
                imageURL: imageURL,
                palette: palette,
                isTapback: true
            ))
            edge = side == .trailing ? minX - TimelineMetrics.tapbackGap : minX + width + TimelineMetrics.tapbackGap
        }

        for reaction in reactions {
            let imageURL = reaction.emoji.id.flatMap {
                CDN.emoji(id: $0, animated: reaction.emoji.isAnimated, side: TimelineMetrics.reactionGlyphSide)
            }
            if reaction.burstCount > 0 {
                place(reaction, kind: .burst, imageURL: imageURL, palette: SuperReactionPalette(colors: reaction.burstColors))
            }
            if reaction.count > 0 {
                place(reaction, kind: .normal, imageURL: imageURL, palette: nil)
            }
        }

        // A bubble as wide as a narrow window leaves no room beside it: the
        // badges slide back over its top edge rather than off the row.
        let margin = TimelineMetrics.horizontalMargin / 2
        let low = slots.map(\.rect.minX).min() ?? margin
        let high = slots.map(\.rect.maxX).max() ?? rowWidth - margin
        let shift = low < margin ? margin - low : (high > rowWidth - margin ? rowWidth - margin - high : 0)
        if shift != 0 {
            for index in slots.indices { slots[index].rect.origin.x += shift }
        }
        return slots
    }

    /// A bubble with a gap cut round each badge riding it.
    static func notched(_ path: CGPath, around badges: [ReactionSlot]) -> CGPath {
        guard !badges.isEmpty else { return path }
        let cut = CGMutablePath()
        let notch = TimelineMetrics.tapbackNotch
        for badge in badges {
            let ring = badge.rect.insetBy(dx: -notch, dy: -notch)
            cut.addPath(CGPath(roundedRect: ring, cornerWidth: ring.height / 2, cornerHeight: ring.height / 2, transform: nil))
        }
        return path.subtracting(cut)
    }

    /// The button rows under a message, wrapped to the column.
    ///
    /// Returns the y the next thing starts at.
    /// Shared with `ComponentsLayoutEngine`, which lays rows out inside a card.
    static func layoutComponentRows(
        _ rows: [ActionRow],
        contentX: CGFloat,
        y: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        into slots: inout [ComponentSlot]
    ) -> CGFloat {
        layoutComponents(rows, contentX: contentX, y: y, width: width, style: style, into: &slots)
    }

    private static func layoutComponents(
        _ rows: [ActionRow],
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        into slots: inout [ComponentSlot]
    ) -> CGFloat {
        var y = startY
        let font = TimelineMetrics.componentFont(style)

        for row in rows {
            var x = contentX
            var usedRow = false
            for control in row.components {
                let glyphRoom = control.emoji == nil
                    ? 0
                    : TimelineMetrics.componentGlyphSide + TimelineMetrics.componentGlyphGap
                // **A link button needs the room too.** It draws an arrow at
                // its trailing edge exactly as a menu draws a chevron, and
                // reserving for one but not the other is what put the mark on
                // top of "Open roadmap".
                let chevronRoom: CGFloat = control.isSelectMenu || control.destination != nil
                    ? TimelineMetrics.componentTrailingGlyphRoom
                    : 0
                let labelWidth = measure(control.label, font: font)
                // **A select is Discord's field width, not its words'**: 400
                // points or the column, whichever is less (`.select`, `width:
                // 400px; max-width: 100%`) — a menu the width of its
                // placeholder reads as a button that says "Make a selection".
                let buttonWidth = control.isSelectMenu
                    ? min(width, TimelineMetrics.selectMenuWidth)
                    : min(
                        width,
                        TimelineMetrics.componentPadding * 2 + glyphRoom + labelWidth + chevronRoom
                    )
                if usedRow, x + buttonWidth > contentX + width {
                    x = contentX
                    y += TimelineMetrics.componentHeight + TimelineMetrics.componentGap
                }
                slots.append(ComponentSlot(
                    rect: CGRect(
                        x: x, y: y,
                        width: buttonWidth, height: TimelineMetrics.componentHeight
                    ),
                    label: control.label,
                    emoji: control.emoji,
                    url: control.destination,
                    customID: control.customID,
                    isEnabled: control.isActionable,
                    style: control.style,
                    isMenu: control.isSelectMenu,
                    selectID: control.select?.customID
                ))
                x += buttonWidth + TimelineMetrics.componentGap
                usedRow = true
            }
            if usedRow { y += TimelineMetrics.componentHeight + TimelineMetrics.componentGap }
        }
        // The last row contributed a trailing gap the caller does not want. With
        // nothing laid out at all there is no gap to take back.
        return slots.isEmpty ? startY : y - TimelineMetrics.componentGap
    }

    /// What a message says when its body is not `content`.
    ///
    /// Folded once, at layout time, for the same reason `plainText` is: a row is
    /// one accessibility node with a plain `String`, and letting the platform
    /// derive a label from styled text re-resolves every run into attributes on
    /// every render — per run, per frame, whether or not anybody is using
    /// VoiceOver.
    private static func spokenBody(of message: Message) -> String {
        var parts: [String] = []
        for node in message.displayComponents {
            let text = node.plainText
            if !text.isEmpty { parts.append(text) }
        }
        if let invite = message.activityInvite {
            parts.append("Activity invitation. \(invite.name). Play.")
        }
        if let invite = message.listenAlong {
            parts.append("Invite to Listen Along on \(invite.name).")
        }
        if message.sharedTheme != nil {
            parts.append("A custom theme. Preview, or Save.")
        }
        // A clip's header and faces are drawn, so they are said: what it is
        // called, its game, who is in it (docs/CLIPS-PRESENCE.md, 4.5).
        for clip in message.attachments.compactMap(\.clip) {
            var line = "Clip, " + (clip.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")
            if let game = clip.applicationName { line += ", \(game)" }
            let names = clip.participants.map(\.preferredName)
            if !names.isEmpty {
                let shown = names.prefix(ClipTileHeader.shownFaces).joined(separator: ", ")
                let rest = names.count - ClipTileHeader.shownFaces
                line += rest > 0 ? ", with \(shown) and \(rest) more" : ", with \(shown)"
            }
            parts.append(line)
        }
        // A timeline comment's moment, which its reply header does not draw.
        if let moment = message.mediaMention {
            parts.append("At \(mediaTimeLabel(moment.timestampMS / 1_000)) in the clip")
        }
        switch SafetyNotice(message) {
        case .policy(_, let incident):
            parts.append("You broke Discord's community guidelines. \(SafetyNotice.daysAgo(since: incident)). "
                + "We've taken action that affects your account.")
        case .system(let system):
            parts.append("\(system.header). \(SafetyNotice.daysAgo(since: system.date)). \(system.body)")
        case nil:
            break
        }
        if let poll = message.poll {
            parts.append("Poll. \(poll.question)")
            for answer in poll.answers {
                parts.append(poll.showsResults
                    ? "\(answer.text), \(answer.count) votes"
                    : answer.text)
            }
        }
        return parts.joined(separator: ". ")
    }

    // MARK: A forwarded message

    /// Lays a forward out as a quote: a rule, a label, and the snapshot inside.
    private static func layoutForward(
        _ snapshot: ForwardedMessage,
        origin: CGPoint,
        availableWidth: CGFloat,
        input: Input,
        parser: MarkdownParser
    ) -> ForwardedSlot {
        let style = input.style
        let indent = TimelineMetrics.forwardIndent
        let contentX = origin.x + indent
        let contentWidth = max(60, availableWidth - indent)
        var y = origin.y + TimelineMetrics.forwardTopPadding

        // The label row: an arrow and the word. Metadata ink, because it names
        // the block rather than saying anything the sender wrote.
        let glyphSide = TimelineMetrics.forwardGlyphSide
        let label = TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: "Forwarded",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: style.metadataFont.pointSize, weight: .semibold
                    ),
                    .foregroundColor: style.tertiaryColor,
                ]
            )),
            width: contentWidth,
            style: style
        )
        let glyphRect = CGRect(
            x: contentX,
            y: y + (label.size.height - glyphSide) / 2,
            width: glyphSide,
            height: glyphSide
        )
        let labelOrigin = CGPoint(x: glyphRect.maxX + Spacing.tight, y: y)
        y += label.size.height

        // What was forwarded. Markdown like any other body, because it IS
        // another message's body.
        var body: TimelineTextBlock?
        var bodyOrigin = CGPoint.zero
        if !snapshot.content.isEmpty {
            y += TimelineMetrics.forwardLineGap
            let document = parser.parse(snapshot.content)
            let text = MessageTextBuilder.build(
                document: document,
                context: input.mentions,
                style: style
            )
            let block = TimelineTextBlock(text: text, width: contentWidth, style: style)
            body = block
            bodyOrigin = CGPoint(x: contentX, y: y)
            y += block.size.height
        }

        // Stickers above the files, as on the message itself: a sticker IS the
        // message, and one under a screenshot reads as a caption on it.
        var stickers: [StickerSlot] = []
        for sticker in snapshot.stickers {
            y += TimelineMetrics.attachmentGap
            let side = min(Metrics.stickerInline, contentWidth)
            let rect = CGRect(x: contentX, y: y, width: side, height: side)
            stickers.append(StickerSlot(
                rect: rect,
                sticker: sticker,
                url: CDN.sticker(id: sticker.id, format: sticker.format),
                isVector: sticker.format == .lottie,
                isAnimated: sticker.format.isAnimated
            ))
            y = rect.maxY
        }

        let attachments = attachmentSlots(
            snapshot.attachments,
            origin: CGPoint(x: contentX, y: y),
            availableWidth: contentWidth,
            style: style
        )
        for slot in attachments { y = max(y, slot.rect.maxY) }

        var embeds: [EmbedSlot] = []
        if input.settings.showsEmbeds {
            for embed in snapshot.embeds {
                y += TimelineMetrics.attachmentGap
                let slot = EmbedLayoutEngine.layout(
                    embed,
                    origin: CGPoint(x: contentX, y: y),
                    availableWidth: contentWidth,
                    style: style,
                    mentions: input.mentions,
                    parser: parser,
                    spotify: Self.spotifyCard(for: embed, in: input),
                    footerStamp: embed.timestamp.map { input.settings.timestampLabel($0, calendar: input.calendar) }
                )
                embeds.append(slot)
                y = slot.rect.maxY
            }
        }

        // **Discord's breadcrumb** (its forward footer, read 2026-11-16): the
        // original's channel when it is in this message's server and the
        // reader may see it, else that server's icon and name; then the time
        // it was sent; then a chevron, because the whole line jumps to it. An
        // original in a conversation, or in a server this account knows
        // nothing of, has no line: inventing a name for a place the reader
        // cannot see is a claim the client cannot make.
        let footerParts = Self.forwardOrigin(of: snapshot, in: input)
        var footer: TimelineTextBlock?
        var footerOrigin = CGPoint.zero
        var footerRect = CGRect.zero
        var footerIconRect = CGRect.zero
        var footerChevronRect = CGRect.zero
        if let footerParts {
            y += TimelineMetrics.forwardLineGap
            let time = snapshot.sentAt.map { input.settings.timestampLabel($0, calendar: input.calendar) }
            let words = [footerParts.label, time].compactMap(\.self).joined(separator: "  \u{2022}  ")
            let iconSide = TimelineMetrics.forwardFooterIconSide
            let chevronSide = TimelineMetrics.forwardGlyphSide - 2
            let iconRoom = footerParts.iconURL == nil ? 0 : iconSide + Spacing.tight
            let attributed = NSAttributedString(
                string: words,
                attributes: [
                    .font: NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .medium),
                    .foregroundColor: style.tertiaryColor,
                ]
            )
            // **The words' own width**, so the chevron follows the time rather
            // than standing at the far edge of the block.
            let room = max(40, contentWidth - iconRoom - chevronSide - Spacing.tight)
            let block = TimelineTextBlock(
                text: .plain(attributed),
                width: min(room, attributed.size().width.rounded(.up) + 1),
                style: style
            )
            footer = block
            footerOrigin = CGPoint(x: contentX + iconRoom, y: y)
            if footerParts.iconURL != nil {
                footerIconRect = CGRect(
                    x: contentX, y: y + (block.size.height - iconSide) / 2, width: iconSide, height: iconSide
                )
            }
            footerChevronRect = CGRect(
                x: footerOrigin.x + block.size.width + Spacing.tight,
                y: y + (block.size.height - chevronSide) / 2,
                width: chevronSide,
                height: chevronSide
            )
            footerRect = CGRect(
                x: contentX, y: y,
                width: footerChevronRect.maxX - contentX, height: block.size.height
            )
            y += block.size.height
        }

        let height = y + TimelineMetrics.forwardTopPadding - origin.y
        return ForwardedSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: availableWidth, height: height),
            ruleRect: CGRect(
                x: origin.x,
                y: origin.y,
                width: TimelineMetrics.forwardRuleWidth,
                height: height
            ),
            glyphRect: glyphRect,
            label: label,
            labelOrigin: labelOrigin,
            body: body,
            bodyOrigin: bodyOrigin,
            attachments: attachments,
            embeds: embeds,
            stickers: stickers,
            footer: footer,
            footerOrigin: footerOrigin,
            footerRect: footerRect,
            footerIconURL: footerParts?.iconURL,
            footerIconRect: footerIconRect,
            footerChevronRect: footerChevronRect,
            jump: footerParts == nil ? nil : snapshot.channelID.flatMap { channelID in
                snapshot.messageID.map {
                    ForwardJump(guildID: snapshot.guildID, channelID: channelID, messageID: $0)
                }
            }
        )
    }

    /// What a forward's breadcrumb names, and the server icon before it —
    /// Discord's `getForwardInfo`. Nil where it names nothing.
    static func forwardOrigin(
        of snapshot: ForwardedMessage,
        in input: Input
    ) -> (label: String, iconURL: URL?)? {
        let mentions = input.mentions
        func server(_ guildID: GuildID) -> (label: String, iconURL: URL?)? {
            guard let name = mentions.guildNames[guildID] else { return nil }
            let icon = mentions.guildIconHashes[guildID].flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: TimelineMetrics.forwardFooterIconSide)
            }
            return (name, icon)
        }
        // In this message's own server: the channel, when the reader may see
        // it; the server, when the channel is one this account does not know.
        if let guildID = snapshot.guildID, guildID == mentions.currentGuildID {
            guard let channelID = snapshot.channelID, let channel = mentions.channels[channelID] else {
                return server(guildID)
            }
            guard channel.canView else { return nil }
            return ((channel.kind == .directMessage || channel.kind == .groupDirectMessage ? "@" : "#")
                + channel.name, nil)
        }
        // Another server's: its name and icon, when this account knows it.
        if let guildID = snapshot.guildID { return server(guildID) }
        return nil
    }

    // MARK: A forum post's bar

    /// Discord's bar under a post's opening message (`rg`): React to Post while
    /// it has no reactions, Follow or Following, and Copy Link — a bare link
    /// glyph, then a tick and "Copied".
    private static func postActions(
        _ actions: PostActions,
        input: Input
    ) -> (slot: PostActionsSlot, height: CGFloat) {
        let style = input.style
        let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize + 1, weight: .medium)
        let glyphSide = TimelineMetrics.componentGlyphSide
        let padding = TimelineMetrics.componentPadding
        let height = TimelineMetrics.componentHeight
        let gap = TimelineMetrics.conversationStartLineGap + 2
        let top: CGFloat = TimelineMetrics.conversationStartLineGap
        var x = TimelineMetrics.contentInset
        var buttons: [PostActionsSlot.Button] = []

        func add(_ action: PostActionsSlot.Action, symbol: String, title: String?, lit: Bool, spoken: String) {
            let label = title.map { words in
                TimelineTextBlock(
                    text: .plain(NSAttributedString(
                        string: words,
                        attributes: [.font: font, .foregroundColor: lit ? style.linkColor : style.primaryColor]
                    )),
                    width: Self.measure(words, font: font) + 2,
                    style: style
                )
            }
            let width = label.map { padding + glyphSide + TimelineMetrics.componentGlyphGap + $0.size.width + padding }
                ?? height
            let rect = CGRect(x: x, y: top, width: width, height: height)
            let glyphX = label == nil ? rect.midX - glyphSide / 2 : rect.minX + padding
            buttons.append(.init(
                action: action,
                rect: rect,
                symbolName: symbol,
                glyphRect: CGRect(x: glyphX, y: rect.midY - glyphSide / 2, width: glyphSide, height: glyphSide),
                label: label,
                labelOrigin: CGPoint(
                    x: rect.minX + padding + glyphSide + TimelineMetrics.componentGlyphGap,
                    y: rect.midY - (label?.size.height ?? 0) / 2
                ),
                isLit: lit,
                accessibilityLabel: spoken
            ))
            x = rect.maxX + gap
        }

        if actions.offersReaction {
            add(.react, symbol: "face.smiling", title: "React to Post", lit: false, spoken: "React to Post")
        }
        if actions.offersFollow {
            add(
                .follow,
                symbol: actions.isFollowing ? "checkmark" : "bell",
                title: actions.isFollowing ? "Following" : "Follow",
                lit: false,
                spoken: actions.isFollowing ? "Following" : "Follow"
            )
        }
        if actions.isLinkCopied {
            add(.copyLink, symbol: "checkmark", title: "Copied", lit: true, spoken: "Copied")
        } else {
            add(.copyLink, symbol: "link", title: nil, lit: false, spoken: "Copy Link")
        }

        return (PostActionsSlot(buttons: buttons), top + height + TimelineMetrics.runBottomPadding)
    }

    // MARK: The head of a channel

    /// Lays out the welcome block at the top of a channel.
    private static func conversationStart(
        _ input: Input,
        width: CGFloat,
        parser: MarkdownParser
    ) -> (slot: ConversationStartSlot, height: CGFloat) {
        let style = input.style
        let margin = TimelineMetrics.horizontalMargin
        // A conversation with people opens on a face, at Discord's 80; a
        // channel on its tile.
        let avatar: (url: URL?, monogram: String?)? = switch input.head {
        case .directMessage(let head): (head.avatarURL, head.monogram)
        case .groupDirectMessage(let iconURL): (iconURL, nil)
        case .systemDirectMessage(let avatarURL): (avatarURL, nil)
        case .channel, .thread, .post: nil
        }
        let side = avatar == nil ? TimelineMetrics.conversationStartIconSide : 80
        let available = max(80, width - margin * 2)

        var y = TimelineMetrics.conversationStartTopPadding
        let iconRect = CGRect(x: margin, y: y, width: side, height: side)
        let glyphSide = side * 0.5
        let glyphRect = CGRect(
            x: iconRect.midX - glyphSide / 2,
            y: iconRect.midY - glyphSide / 2,
            width: glyphSide,
            height: glyphSide
        )
        y = iconRect.maxY + TimelineMetrics.conversationStartGap

        // A channel name can hold emoji — "🗳 | voting" is an ordinary name —
        // so it goes through the same run builder the body does rather than
        // through a bare `drawText`, which would draw a custom one as literal
        // angle brackets.
        let titleText: String = switch input.head {
        // Discord's own words, exclamation and all.
        case .channel: "Welcome to #\(input.channelName)!"
        // A thread's head is its name, and a conversation's its people's.
        case .thread, .post, .directMessage, .groupDirectMessage, .systemDirectMessage: input.channelName
        }
        let title = TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: titleText,
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: style.bodyFont.pointSize * 1.65, weight: .bold
                    ),
                    .foregroundColor: style.primaryColor,
                ]
            )),
            width: available,
            style: style
        )
        let titleOrigin = CGPoint(x: margin, y: y)
        y += title.size.height

        func line(_ string: NSAttributedString) -> (TimelineTextBlock, CGPoint) {
            y += TimelineMetrics.conversationStartLineGap
            let block = TimelineTextBlock(text: .plain(string), width: available, style: style)
            let origin = CGPoint(x: margin, y: y)
            y += block.size.height
            return (block, origin)
        }
        func plain(_ string: String, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: style.bodyFont, .foregroundColor: color])
        }
        /// Discord's sentences with a name in bold (`$b`) between two runs.
        func emphasised(_ before: String, _ name: String, _ after: String) -> NSAttributedString {
            let text = NSMutableAttributedString(attributedString: plain(before, color: style.secondaryColor))
            text.append(NSAttributedString(
                string: name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
                    .foregroundColor: style.primaryColor,
                ]
            ))
            text.append(plain(after, color: style.secondaryColor))
            return text
        }

        var subtitle: TimelineTextBlock?
        var subtitleOrigin = CGPoint.zero
        var note: TimelineTextBlock?
        var noteOrigin = CGPoint.zero
        switch input.head {
        case .channel:
            (subtitle, subtitleOrigin) = line(plain(
                "This is the start of the #\(input.channelName) channel.", color: style.secondaryColor
            ))
        case .thread(let startedBy, let isPrivate):
            // Discord's `imPXd5`, the author's name in the reader's ink.
            let started = NSMutableAttributedString(attributedString: plain("Started by ", color: style.secondaryColor))
            started.append(NSAttributedString(
                string: startedBy ?? "???",
                attributes: [
                    .font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
                    .foregroundColor: style.primaryColor,
                ]
            ))
            (subtitle, subtitleOrigin) = line(started)
            if isPrivate {
                (note, noteOrigin) = line(plain(
                    "@mention users to add them to this private thread.", color: style.secondaryColor
                ))
            }
        case .post(_, let openerDeleted):
            if openerDeleted {
                (note, noteOrigin) = line(plain("Original message was deleted", color: style.secondaryColor))
            }
        case .directMessage(let head):
            if let username = head.username {
                (subtitle, subtitleOrigin) = line(NSAttributedString(
                    string: username,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: style.bodyFont.pointSize * 1.25, weight: .medium),
                        .foregroundColor: style.primaryColor,
                    ]
                ))
            }
            // Discord's `Qvg+6+`, and an incoming request's `uIomXw` under it.
            let sentence = NSMutableAttributedString(attributedString: emphasised(
                "This is the beginning of your direct message history with ", input.channelName, "."
            ))
            if let requester = head.incomingRequestFrom {
                sentence.append(plain("\n", color: style.secondaryColor))
                sentence.append(emphasised("", requester, " sent you a friend request."))
            }
            (note, noteOrigin) = line(sentence)
        case .groupDirectMessage:
            (subtitle, subtitleOrigin) = line(emphasised(
                "Welcome to the beginning of the ", input.channelName, " group."
            ))
        case .systemDirectMessage:
            (subtitle, subtitleOrigin) = line(plain(
                "This is an official message from Team Discord. Please be advised that Discord will "
                    + "never ask you for your password or account token.",
                color: style.secondaryColor
            ))
        }

        // The servers in common and the controls, under a person's head.
        var mutuals: ConversationStartSlot.Mutuals?
        var buttons: [ConversationStartSlot.HeadButton] = []
        if case .directMessage(let head) = input.head {
            y += TimelineMetrics.conversationStartButtonGap
            let iconSide: CGFloat = 20
            var x = margin
            var icons: [(mark: DirectMessageHead.MutualMark, rect: CGRect)] = []
            for mark in head.mutualIcons.prefix(3) {
                icons.append((mark, CGRect(x: x, y: y, width: iconSide, height: iconSide)))
                x += iconSide - 4
            }
            if !icons.isEmpty { x += 4 + TimelineMetrics.conversationStartLineGap }
            let words = head.mutualCount == 0
                ? "No servers in common"
                : head.mutualCount == 1 ? "1 Mutual Server" : "\(head.mutualCount) Mutual Servers"
            let label = TimelineTextBlock(
                text: .plain(NSAttributedString(
                    string: words,
                    attributes: [.font: style.bodyFont, .foregroundColor: style.secondaryColor]
                )),
                width: Self.measure(words, font: style.bodyFont) + 2,
                style: style
            )
            let labelOrigin = CGPoint(x: x, y: y + (iconSide - label.size.height) / 2)
            mutuals = .init(
                icons: icons,
                label: label,
                labelOrigin: labelOrigin,
                rect: CGRect(x: margin, y: y, width: labelOrigin.x + label.size.width - margin, height: iconSide)
            )
            y += iconSide
        }

        let actions = input.head.actions
        if !actions.isEmpty {
            y += TimelineMetrics.conversationStartButtonGap
            let font = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .medium)
            let padding = TimelineMetrics.componentPadding
            let height = TimelineMetrics.componentHeight + 4
            var bx = margin
            for action in actions {
                let label = TimelineTextBlock(
                    text: .plain(NSAttributedString(
                        string: action.title,
                        attributes: [
                            .font: font,
                            .foregroundColor: action.isProminent || action.isCritical ? NSColor.white : style.primaryColor,
                        ]
                    )),
                    width: Self.measure(action.title, font: font) + 2,
                    style: style
                )
                let rect = CGRect(x: bx, y: y, width: label.size.width + padding * 2, height: height)
                buttons.append(.init(
                    action: action,
                    rect: rect,
                    label: label,
                    labelOrigin: CGPoint(x: rect.minX + padding, y: rect.midY - label.size.height / 2)
                ))
                bx = rect.maxX + TimelineMetrics.conversationStartLineGap + 2
            }
            y += height
        }

        // A post's tags, as Discord's `iJ` row wraps them under the title.
        var tags: [ConversationStartSlot.Tag] = []
        if case .post(let postTags, _) = input.head, !postTags.isEmpty {
            y += TimelineMetrics.conversationStartLineGap * 2
            let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .medium)
            let padding = TimelineMetrics.componentPadding
            let height = TimelineMetrics.componentHeight - 4
            let gap = TimelineMetrics.conversationStartLineGap
            var x = margin
            for tag in postTags {
                let words = [tag.emoji.flatMap { $0.id == nil ? $0.name : nil }, tag.name]
                    .compactMap(\.self)
                    .joined(separator: " ")
                let label = TimelineTextBlock(
                    text: .plain(NSAttributedString(
                        string: words,
                        attributes: [.font: font, .foregroundColor: style.secondaryColor]
                    )),
                    width: Self.measure(words, font: font) + 2,
                    style: style
                )
                let width = min(available, label.size.width + padding * 2)
                if x > margin, x + width > margin + available {
                    x = margin
                    y += height + gap
                }
                let rect = CGRect(x: x, y: y, width: width, height: height)
                tags.append(.init(
                    rect: rect,
                    label: label,
                    labelOrigin: CGPoint(x: rect.minX + padding, y: rect.midY - label.size.height / 2)
                ))
                x = rect.maxX + gap
            }
            y += height
        }

        var topic: TimelineTextBlock?
        var topicOrigin = CGPoint.zero
        if case .channel = input.head,
           let text = input.channelTopic?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            y += TimelineMetrics.conversationStartLineGap
            let document = parser.parse(text)
            // The topic is prose in the quiet ink, not body text: it is a
            // caption under a heading, and at full strength it competes with
            // the welcome above it.
            var topicStyle = style
            topicStyle.primaryColor = style.secondaryColor
            let block = TimelineTextBlock(
                text: MessageTextBuilder.build(
                    document: document,
                    context: input.mentions,
                    style: topicStyle
                ),
                width: available,
                style: style
            )
            topic = block
            topicOrigin = CGPoint(x: margin, y: y)
            y += block.size.height
        }

        // Discord's Edit Channel, under the welcome, for a reader who may
        // manage the channel: a pencil and the words on the row's quiet plate.
        // A thread's head has none — its edit is the thread's own menu.
        var editButton: ConversationStartSlot.EditButton?
        if input.canEditChannel, case .channel = input.head {
            y += TimelineMetrics.conversationStartButtonGap
            let font = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .medium)
            let label = TimelineTextBlock(
                text: .plain(NSAttributedString(
                    string: "Edit Channel",
                    attributes: [.font: font, .foregroundColor: style.primaryColor]
                )),
                width: Self.measure("Edit Channel", font: font) + 2,
                style: style
            )
            let glyphSide = TimelineMetrics.componentGlyphSide
            let padding = TimelineMetrics.componentPadding
            let height = TimelineMetrics.componentHeight + 4
            let rect = CGRect(
                x: margin, y: y,
                width: padding + glyphSide + TimelineMetrics.componentGlyphGap + label.size.width + padding,
                height: height
            )
            editButton = .init(
                rect: rect,
                glyphRect: CGRect(x: rect.minX + padding, y: rect.midY - glyphSide / 2,
                                  width: glyphSide, height: glyphSide),
                label: label,
                labelOrigin: CGPoint(
                    x: rect.minX + padding + glyphSide + TimelineMetrics.componentGlyphGap,
                    y: rect.midY - label.size.height / 2
                )
            )
            y = rect.maxY
        }

        return (
            ConversationStartSlot(
                iconRect: iconRect,
                symbolName: input.channelSymbol,
                glyphRect: glyphRect,
                title: title,
                titleOrigin: titleOrigin,
                subtitle: subtitle,
                subtitleOrigin: subtitleOrigin,
                note: note,
                noteOrigin: noteOrigin,
                tags: tags,
                avatarURL: avatar?.url,
                avatarMonogram: avatar?.monogram,
                mutuals: mutuals,
                buttons: buttons,
                isRound: avatar != nil,
                topic: topic,
                topicOrigin: topicOrigin,
                editButton: editButton
            ),
            y + TimelineMetrics.conversationStartBottomPadding
        )
    }

    // MARK: Helpers

    /// Every attachment on one message, placed.
    ///
    /// **The pictures are one arrangement and everything else is a stack.**
    /// Discord partitions a message's attachments into visual media and the
    /// rest, lays the first out as a mosaic and puts the second underneath one
    /// per row — so four screenshots are a grid and a zip beside them is still
    /// a card. This client used to stack all of them, each at the column's full
    /// width, which is the whole of "the images are way too big and they are
    /// not grouped".
    ///
    /// **The returned array is in the MESSAGE's order, not the mosaic's.** The
    /// lightbox indexes `posterWidths` against `message.attachments` — see
    /// `AppModel.openMedia` — and the click that opens it carries a position in
    /// this array. Sorting the pictures to the front here would open the wrong
    /// one on every message that mixes a picture with a file.
    /// The stickers a message's attachments stand for — Vencord's animated
    /// Fake Nitro stickers, uploaded as `<sticker id>.gif` — when every one is
    /// a sticker the reader's servers know, as the plugin asks its sticker
    /// store. Nil otherwise, which leaves them attachments.
    ///
    /// **All or none**: the lightbox finds a picture by its position among the
    /// message's attachments, and taking one out of the middle would open the
    /// wrong one.
    static func fakeGIFStickers(of message: Message, in input: Input) -> [StickerRef]? {
        guard !input.fakeGIFStickers.isEmpty, !message.attachments.isEmpty else { return nil }
        var stickers: [StickerRef] = []
        for attachment in message.attachments {
            guard let id = FakeNitroLink.gifStickerID(in: attachment),
                  let sticker = input.fakeGIFStickers[id] else { return nil }
            stickers.append(sticker)
        }
        return stickers
    }

    /// A text file's preview height at this width, once its card has measured
    /// — nil leaves the file card, as it does when the fetch failed and the
    /// measure was dropped (Discord's `hadError`).
    private static func textPreviewHeight(_ attachment: Attachment, width: CGFloat, input: Input) -> CGFloat? {
        guard PlaintextPreview.isPreviewable(filename: attachment.filename) else { return nil }
        return input.hostedCardSizes[.plaintext(PlaintextCardKey(attachment))]?.height(atWidth: width.rounded(.down))
    }

    static func attachmentSlots(
        _ attachments: [Attachment],
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle,
        voiceLook: VoiceNoteLook = .capsule,
        textPreviewHeight: (Attachment, CGFloat) -> CGFloat? = { _, _ in nil }
    ) -> [AttachmentSlot] {
        guard !attachments.isEmpty else { return [] }

        var pictures: [Int] = []
        var rest: [Int] = []
        for (index, attachment) in attachments.enumerated() {
            if isVisualMedia(attachment) { pictures.append(index) } else { rest.append(index) }
        }

        var slots = [AttachmentSlot?](repeating: nil, count: attachments.count)
        var y = origin.y

        if !pictures.isEmpty {
            y += TimelineMetrics.attachmentGap
            let sizes = pictures.map { Self.pixelSize(of: attachments[$0]) }
            let frames = AttachmentMosaic.frames(sizes: sizes, width: availableWidth)
            // **Cropped only where there is more than one.** A lone picture
            // keeps its own shape; a cell in a grid is a fixed box and the
            // picture fills it, which is what makes the rows flush.
            let cropped = pictures.count > 1
            // **The offset is fixed for the whole mosaic.** The frames come
            // back relative to its own origin, so moving the cursor inside this
            // loop would shift every cell by the one before it — a grid that
            // walks down and to the right a row at a time.
            let top = y
            for (position, index) in pictures.enumerated() {
                let frame = frames[position].offsetBy(dx: origin.x, dy: top)
                slots[index] = mediaSlot(
                    attachments[index],
                    in: frame,
                    pixels: sizes[position],
                    cropped: cropped
                )
                y = max(y, frame.maxY)
            }
        }

        for index in rest {
            // Eight, not the six a picture takes — `.nonVisualMediaItem`'s own
            // `margin-top`, and twice the gap inside the grid, which is what
            // keeps a file card from reading as one more cell.
            y += pictures.isEmpty && index == rest.first
                ? TimelineMetrics.attachmentGap
                : AttachmentMosaic.stackGap
            if let height = textPreviewHeight(attachments[index], availableWidth) {
                let slot = AttachmentSlot(
                    rect: CGRect(x: origin.x, y: y, width: availableWidth.rounded(.down), height: height),
                    url: nil,
                    isSpoiler: attachments[index].isSpoiler,
                    altText: nil,
                    decodeWidth: 0,
                    kind: .textPreview,
                    filename: attachments[index].filename
                )
                slots[index] = slot
                y = slot.rect.maxY
                continue
            }
            let slot = nonVisualSlot(
                attachments[index],
                origin: CGPoint(x: origin.x, y: y),
                availableWidth: availableWidth,
                style: style,
                voiceLook: voiceLook
            )
            slots[index] = slot
            y = slot.rect.maxY
        }

        return slots.compactMap { $0 }
    }

    /// Whether an attachment belongs in the mosaic.
    ///
    /// **A voice note is audio and is not media here**, which is the same split
    /// Discord makes: it has a waveform and a duration and it is one line tall,
    /// and dropping it into a grid cell would crop a control.
    static func isVisualMedia(_ attachment: Attachment) -> Bool {
        if attachment.waveform != nil || attachment.durationSeconds != nil,
           attachment.contentType?.hasPrefix("audio/") ?? false
        {
            return false
        }
        return attachment.isImage || attachment.isVideo
    }

    /// The picture's own pixel dimensions, or nil where the attachment carried
    /// none.
    private static func pixelSize(of attachment: Attachment) -> CGSize? {
        guard let width = attachment.width, let height = attachment.height,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A voice note or a file — the two that are not pictures.
    ///
    /// **The kind is decided once, here.** A picture, a clip, a voice note
    /// and a document are four rectangles, and a painter that worked it out
    /// per frame would branch inside every repaint of every row carrying one.
    private static func nonVisualSlot(
        _ attachment: Attachment,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle,
        voiceLook: VoiceNoteLook
    ) -> AttachmentSlot {
        if attachment.waveform != nil || attachment.durationSeconds != nil,
           attachment.contentType?.hasPrefix("audio/") ?? false
        {
            return voiceSlot(attachment, origin: origin, availableWidth: availableWidth, look: voiceLook)
        }
        return fileSlot(attachment, origin: origin, availableWidth: availableWidth, style: style)
    }

    /// A picture or a clip, in the box the mosaic gave it.
    ///
    /// **The box comes in; this decides what goes in it.** Where the message
    /// carries one picture the box is its own shape and nothing is cropped;
    /// where it carries several the box is a grid cell and the picture fills
    /// it — which is why `decodeWidth` is the *cover* width rather than the
    /// cell's. Asking for the cell's width would fetch a rendition that then
    /// has to be upscaled to cover, and it would be softest in exactly the
    /// cells that are cropped most.
    private static func mediaSlot(
        _ attachment: Attachment,
        in rect: CGRect,
        pixels: CGSize?,
        cropped: Bool
    ) -> AttachmentSlot {
        let box = rect.size
        let decodeWidth = cropped
            ? AttachmentMosaic.coverWidth(pixels, in: box)
            : box.width
        let isVideo = attachment.isVideo
        // **A picture moves in the transcript by Discord's own rule** — a
        // `.gif` always, a WebP when Discord marked it animated; see
        // `CDN.playsAsAnimated` — and it comes through the resizing proxy like
        // any picture: a resized GIF keeps every frame, and a WebP does when
        // asked. See `CDN.resizedAttachment` for both measurements.
        let isAnimated = !isVideo && !attachment.isSpoiler && attachment.playsAsAnimated
        // The height the picture is drawn at, from its own shape: a cover crop
        // is wider than its box, and fitting it to the box's height would
        // fetch it too small.
        let decodeHeight = pixels.flatMap { $0.width > 0 ? decodeWidth * $0.height / $0.width : nil }
        let url: URL? = if isVideo {
            // A clip on this Mac — a `--demo` fixture — is its own poster:
            // `ImageStore` takes its first frame (`posterFrame(of:)`).
            CDN.videoPoster(proxyURL: attachment.proxyURL, width: decodeWidth, height: decodeHeight)
                ?? URL(string: attachment.proxyURL).flatMap { $0.isFileURL ? $0 : nil }
        } else {
            CDN.resizedAttachment(
                proxyURL: attachment.proxyURL, width: decodeWidth, height: decodeHeight, animated: isAnimated
            )
        }
        return AttachmentSlot(
            rect: rect,
            url: url,
            isSpoiler: attachment.isSpoiler,
            altText: attachment.description,
            decodeWidth: decodeWidth,
            kind: isVideo ? .video : .image,
            cropsToFill: cropped,
            filename: attachment.filename,
            durationLabel: isVideo ? Self.durationLabel(attachment.durationSeconds) : "",
            isAnimated: isAnimated,
            favorite: isAnimated ? Self.favorite(for: attachment) : nil,
            favoriteRect: favoriteBadgeRect(in: rect),
            placeholder: attachment.placeholder,
            clip: isVideo ? attachment.clip.map { ClipTileHeader($0, width: rect.width) } : nil
        )
    }

    /// The box a picture of these pixel dimensions occupies.
    ///
    /// Its own function because it is the one piece of attachment geometry a
    /// test can check against a table, and because the bare-image embed needs
    /// exactly the same rule — two copies is two places for the ratio to drift.
    static func mediaBox(
        width: Int?,
        height: Int?,
        availableWidth: CGFloat,
        maximumHeight: CGFloat = Metrics.attachmentMaxHeight
    ) -> CGSize {
        // A missing aspect ratio is a real state, not something to substitute a
        // square for: reserving a square for a panorama makes the transcript
        // jump when the picture arrives.
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: min(availableWidth, 320), height: 180)
        }
        return mediaBox(
            ratio: CGFloat(width) / CGFloat(height),
            // Never upscaled past its own pixels.
            availableWidth: min(availableWidth, CGFloat(width)),
            maximumHeight: maximumHeight
        )
    }

    /// The same rule, from a shape rather than from a pixel count.
    ///
    /// **One copy, two callers.** The mosaic's lone picture and an unfurled
    /// bare image are the same question asked with different caps, and this
    /// file's own comment on the embed side already says what a second copy
    /// costs: the ratio drifts in one of them and the symptom is a picture of
    /// the wrong shape in one surface only.
    static func mediaBox(
        ratio: CGFloat,
        availableWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGSize {
        guard ratio > 0 else {
            return CGSize(width: min(availableWidth, 320), height: 180)
        }
        var boxWidth = availableWidth
        var boxHeight = boxWidth / ratio
        if boxHeight > maximumHeight {
            boxHeight = maximumHeight
            boxWidth = boxHeight * ratio
        }
        return CGSize(width: boxWidth.rounded(), height: boxHeight.rounded())
    }

    /// A voice note: a disc, its bars, how long it runs, and how fast.
    ///
    /// **As wide as it is long**, as Discord's: half a second is a stub and anything
    /// from 45 seconds on is the full width. A panel narrower than that takes bars away
    /// rather than squeezing them, and `bars(_:count:)` averages what's left.
    ///
    /// - Parameter look: whether it's in a bubble, which brings its own padding.
    static func voiceSlot(
        _ attachment: Attachment,
        origin: CGPoint,
        availableWidth: CGFloat,
        look: VoiceNoteLook = .capsule
    ) -> AttachmentSlot {
        typealias Metric = TimelineMetrics
        let duration = attachment.durationSeconds ?? 0
        let isBare = look != .capsule
        let inset = isBare ? Metric.voiceNoteBareInset : Metric.voiceNoteInset
        let height = Metric.voiceNoteDisc + inset * 2
        // The disc and the time and the pill are fixed, and the bars take what's left.
        let fixed = inset + Metric.voiceNoteDisc + Metric.voiceNoteGap
            + Metric.voiceNoteGap + Metric.voiceNoteTimeWidth
            + Metric.voiceNoteGap / 2 + Metric.voiceNotePill.width + inset
        let room = max(Metric.voiceNoteMinimumBars, availableWidth - fixed)
        let count = VoiceWaveform.barCount(forWidth: min(VoiceWaveform.width(forDuration: duration), room))
        let barsWidth = CGFloat(count) * VoiceWaveform.barStep - (VoiceWaveform.barStep - VoiceWaveform.barWidth)
        let width = min(availableWidth, fixed + barsWidth)
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)

        let disc = CGRect(
            x: rect.minX + inset,
            y: rect.midY - Metric.voiceNoteDisc / 2,
            width: Metric.voiceNoteDisc,
            height: Metric.voiceNoteDisc
        )
        let barsRect = CGRect(
            x: disc.maxX + Metric.voiceNoteGap,
            y: rect.midY - VoiceWaveform.barMaximumHeight / 2,
            width: barsWidth,
            height: VoiceWaveform.barMaximumHeight
        )
        let timeRect = CGRect(
            x: barsRect.maxX + Metric.voiceNoteGap,
            y: rect.midY - 9,
            width: Metric.voiceNoteTimeWidth,
            height: 18
        )
        let pill = CGRect(
            x: rect.maxX - inset - Metric.voiceNotePill.width,
            y: rect.midY - Metric.voiceNotePill.height / 2,
            width: Metric.voiceNotePill.width,
            height: Metric.voiceNotePill.height
        )
        return AttachmentSlot(
            rect: rect,
            url: nil,
            isSpoiler: attachment.isSpoiler,
            altText: attachment.description,
            decodeWidth: width,
            kind: .voice,
            filename: attachment.filename,
            durationLabel: Self.durationLabel(attachment.durationSeconds),
            voice: VoiceNoteSlot(
                attachmentID: attachment.id,
                source: URL(string: attachment.url),
                duration: duration,
                bars: VoiceWaveform.displayed(
                    VoiceWaveform.bars(VoiceWaveform.decode(attachment.waveform), count: count)
                ),
                disc: disc,
                barsRect: barsRect,
                timeRect: timeRect,
                pill: pill,
                isBare: isBare,
                isOnAccent: look == .accentBubble
            )
        )
    }

    /// Anything with no picture in it: a card with a glyph, a name and a size.
    ///
    /// **A card rather than a grey rectangle.** A zip file has no dimensions, so
    /// the picture path reserved 320x180 for it and then drew nothing there for
    /// ever — an empty box that looks exactly like a picture that failed to
    /// load, which is what "previews are broken for other types of attachments"
    /// describes.
    private static func fileSlot(
        _ attachment: Attachment,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> AttachmentSlot {
        let sizeLabel = DiscordFileSize.text(attachment.size)
        let textX = origin.x + TimelineMetrics.fileCardInset + TimelineMetrics.fileCardIcon.width
            + TimelineMetrics.fileCardIconGap
        // Discord's card is 432 whatever its name, and less only where the
        // column is.
        let width = min(availableWidth, TimelineMetrics.fileCardMaxWidth)
        let height = TimelineMetrics.fileCardHeight
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        // Two lines stacked about the card's middle: the name on the upper
        // baseline, the size on the lower.
        let block = style.bodyFont.pointSize + style.metadataFont.pointSize + 4
        let top = origin.y + (height - block) / 2
        let button = TimelineMetrics.fileCardHoverButton
        let overhang = TimelineMetrics.fileCardHoverOverhang
        return AttachmentSlot(
            rect: rect,
            url: nil,
            isSpoiler: attachment.isSpoiler,
            altText: attachment.description,
            decodeWidth: width,
            kind: .file,
            filename: attachment.filename,
            sizeLabel: sizeLabel,
            fileKind: AttachmentFileKind(filename: attachment.filename, contentType: attachment.contentType),
            downloadRect: CGRect(x: rect.maxX + overhang - button, y: rect.minY - overhang, width: button, height: button),
            titleOrigin: CGPoint(x: textX, y: top),
            subtitleOrigin: CGPoint(x: textX, y: top + style.bodyFont.pointSize + 4)
        )
    }

    /// A request's hidden media: a file card's height per piece, stacked, and
    /// the note's line under them.
    private static func hiddenMediaSlot(
        count: Int,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> HiddenMediaSlot {
        let width = min(availableWidth, TimelineMetrics.attachmentCardMaxWidth)
        let height = TimelineMetrics.hiddenMediaTileHeight
        var tiles: [CGRect] = []
        tiles.reserveCapacity(count)
        var y = origin.y
        for _ in 0..<count {
            tiles.append(CGRect(x: origin.x, y: y, width: width, height: height))
            y += height + TimelineMetrics.hiddenMediaGap
        }
        let note = CGRect(x: origin.x, y: y, width: width, height: style.bodyFont.pointSize + 6)
        return HiddenMediaSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: width, height: note.maxY - origin.y),
            tiles: tiles,
            noteRect: note
        )
    }

    /// An upload's card: a file card's geometry, with a bar where its size
    /// line would be and a cancel at its trailing edge.
    private static func uploadSlot(
        _ summary: UploadSummary,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> UploadCardSlot {
        let inset = TimelineMetrics.fileCardInset
        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: min(availableWidth, TimelineMetrics.fileCardMaxWidth),
            height: TimelineMetrics.fileCardHeight
        )
        let cancelSide = TimelineMetrics.uploadCancelSide
        let cancelRect = CGRect(
            x: rect.maxX - inset - cancelSide,
            y: rect.midY - cancelSide / 2,
            width: cancelSide,
            height: cancelSide
        )
        let textX = rect.minX + inset + TimelineMetrics.fileCardIcon.width + TimelineMetrics.fileCardIconGap
        let room = max(0, cancelRect.minX - Spacing.base - textX)
        let sizeLabel = "— \(DiscordFileSize.text(summary.size))"
        let sizeWidth = measure(sizeLabel, font: style.metadataFont)
        // The name gives way to the size, never the other way round: how big
        // the upload is says how long the bar will take.
        let titleWidth = min(measure(summary.title, font: style.bodyFont), max(0, room - sizeWidth - 4))
        // Two lines stacked about the card's middle, as a file card's are: the
        // name on the upper, the bar on the lower.
        let lineGap: CGFloat = 4
        let block = style.bodyFont.pointSize + lineGap + style.metadataFont.pointSize
        let top = rect.minY + (rect.height - block) / 2
        let barLine = top + style.bodyFont.pointSize + lineGap
        let barHeight = TimelineMetrics.uploadBarHeight
        return UploadCardSlot(
            rect: rect,
            fileKind: AttachmentFileKind(filename: summary.title, contentType: nil),
            title: summary.title,
            titleOrigin: CGPoint(x: textX, y: top),
            titleWidth: titleWidth,
            sizeLabel: sizeLabel,
            sizeOrigin: CGPoint(
                x: textX + titleWidth + 4,
                y: top + style.bodyFont.pointSize - style.metadataFont.pointSize
            ),
            progressRect: CGRect(
                x: textX,
                y: barLine + (style.metadataFont.pointSize - barHeight) / 2,
                width: room,
                height: barHeight
            ),
            cancelRect: cancelRect
        )
    }

    /// Where the star sits on a picture: the leading top corner, inset.
    ///
    /// Shared by the layout and the hit test, because a control drawn in one
    /// place and clicked in another is the defect this kind of geometry
    /// produces and the only kind a test can catch.
    static func favoriteBadgeRect(in picture: CGRect) -> CGRect {
        CGRect(
            x: picture.minX + TimelineMetrics.favoriteBadgeInset,
            y: picture.minY + TimelineMetrics.favoriteBadgeInset,
            width: TimelineMetrics.favoriteBadgeSide,
            height: TimelineMetrics.favoriteBadgeSide
        )
    }

    /// The GIF an attachment would be starred as.
    ///
    /// **The `cdn.discordapp.com` URL is the key**, exactly as the capture
    /// shows: `gif favorite unfavorite.har` stores an attachment favourite under
    /// its CDN address with the proxied rendition in `src`. Sending that URL
    /// back into a channel is what every client unfurls into the same GIF.
    private static func favorite(for attachment: Attachment) -> GIF? {
        guard let url = URL(string: attachment.url), url.scheme == "https" else { return nil }
        return GIF(
            url: url,
            previewURL: URL(string: attachment.proxyURL),
            width: attachment.width,
            height: attachment.height
        )
    }

    /// "1:04", or empty when Discord sent no duration.
    private static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Text width, measured through CoreText rather than through `NSString`
    /// sizing.
    ///
    /// `NSAttributedString.size()` builds a text container and a layout manager;
    /// `CTLineGetTypographicBounds` measures one line and nothing else, which is
    /// all a name or a timestamp ever is.
    static func measure(_ string: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// One plain string for one accessibility node.
    ///
    /// **Four of these are muteable, and each one is a real string somebody has
    /// to listen to on every message in the channel.** A timestamp per row, an
    /// attachment count per row and a reaction tally per row are useful the
    /// first time and noise the hundredth, which is why the accessibility pane
    /// offers them individually rather than as one "verbose" switch.
    ///
    /// **Edited and reactions used not to be spoken at all**, which was a plain
    /// gap: a sighted reader sees the pencil and the chips, and a VoiceOver
    /// reader was told neither.
    private static func accessibilityLabel(
        author: String,
        time: String,
        body: String,
        attachments: Int,
        stickers: [String],
        extra: String,
        isEphemeral: Bool,
        isEdited: Bool,
        isFailed: Bool = false,
        reactions: [Reaction],
        muted: SpokenDetail.Set
    ) -> String {
        var label = muted.contains(.timestamps) ? author : "\(author), \(time)"
        if !body.isEmpty { label += ". \(body)" }
        if isEdited, !muted.contains(.editedStatus) { label += ". Edited" }
        // **A components-only message and a poll have no `content` at all**, so
        // a label folded from the body alone leaves VoiceOver reading a name and
        // a timestamp over what is, to a sighted reader, a whole card.
        if !extra.isEmpty { label += ". \(extra)" }
        // Named rather than counted: a sticker's name is what it says, and
        // "1 sticker" is the one description that tells a reader nothing.
        for name in stickers where !name.isEmpty {
            label += ". Sticker, \(name)"
        }
        if attachments > 0, !muted.contains(.attachmentTypes) {
            label += attachments == 1 ? ". 1 attachment" : ". \(attachments) attachments"
        }
        // The total rather than each emoji: "six reactions" is the fact, and
        // naming all six is a sentence nobody listens to the end of.
        if !reactions.isEmpty, !muted.contains(.reactionCounts) {
            // The two kinds are spoken apart, as they are drawn apart. `count`
            // is the plain tally alone, so summing only it would leave a
            // message with nothing but super reactions saying it has none.
            let plain = reactions.reduce(0) { $0 + $1.count }
            let burst = reactions.reduce(0) { $0 + $1.burstCount }
            if plain > 0 { label += plain == 1 ? ". 1 reaction" : ". \(plain) reactions" }
            if burst > 0 { label += burst == 1 ? ". 1 super reaction" : ". \(burst) super reactions" }
        }
        // Spoken, not only drawn. Whether a message is private to the reader is
        // exactly the kind of fact a note in the quietest ink on the row is the
        // easiest to miss, and it is the one that changes what somebody does
        // next.
        if isEphemeral { label += ". \(ephemeralNoteText)" }
        // Messages' red mark, said: the one thing about a refused send that
        // changes what the reader does next. Resend is in the row's actions.
        if isFailed { label += ". Not delivered" }
        return label
    }
}

// MARK: - The interaction header

nonisolated extension TimelineLayoutEngine {
    /// "alex used **launch**".
    ///
    /// Laid out against the reply header's own metrics so the two lines sit at
    /// the same height with the same elbow — see `InteractionHeaderSlot`.
    ///
    /// Placed as the reply header is — see `layoutReplyHeader`'s parameters.
    static func layoutInteractionHeader(
        _ interaction: MessageInteraction,
        chip: CommandHeaderChip,
        y: CGFloat,
        leadingX: CGFloat,
        maxX: CGFloat,
        elbowX: CGFloat?,
        style: MessageTextStyle,
        author: AuthorInfo?
    ) -> InteractionHeaderSlot {
        let height = TimelineMetrics.replyHeight
        let avatarRect = CGRect(
            x: leadingX,
            y: y + (height - TimelineMetrics.replyAvatarSide) / 2,
            width: TimelineMetrics.replyAvatarSide,
            height: TimelineMetrics.replyAvatarSide
        )

        let font = style.metadataFont
        // **The name without an `@`.** A reply quotes somebody, so it reads
        // `@name`; this is a sentence about them, and "@alex used launch" is
        // not one.
        let name = author?.name ?? "Unknown"
        let lead = chip == .startedActivity ? "\(name) started an" : "\(name) used"
        let face = author?.nameFace.map {
            NSFont(descriptor: $0.fontDescriptor, size: font.pointSize) ?? font
        }
        let tracking = face == nil
            ? 0
            : (author?.nameTracking ?? 0) * (font.pointSize / max(1, style.authorFont.pointSize))
        let leadWidth = measure(lead, font: face ?? font, tracking: tracking)
        let leadRect = CGRect(
            x: avatarRect.maxX + TimelineMetrics.replyItemGap,
            y: y,
            width: leadWidth,
            height: height
        )
        let nameRect = CGRect(
            x: leadRect.minX,
            y: y,
            width: measure(name, font: face ?? font, tracking: tracking),
            height: height
        )

        // **Discord's chip is a mention's plate** (`.appLauncherOnboardingCommandName`:
        // `--mention-background`, 3 pixels, the link's ink) with the apps icon at
        // its head. A context-menu command is its name and nothing else, and a
        // label has no padding to reach out with.
        let title = chip.title(of: interaction)
        let commandFont = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
        let commandWidth = measure(title, font: commandFont, tracking: 0)
        let padding = chip.hasPlate ? TimelineMetrics.interactionChipPadding : 0
        let glyphRoom = chip.hasPlate
            ? TimelineMetrics.interactionGlyphSide + TimelineMetrics.interactionGlyphGap
            : 0
        let chipRect = CGRect(
            x: leadRect.maxX + (chip.hasPlate ? TimelineMetrics.replyItemGap : 4),
            y: y + (height - TimelineMetrics.interactionChipHeight) / 2,
            width: glyphRoom + commandWidth + padding * 2,
            height: TimelineMetrics.interactionChipHeight
        )
        let glyphRect = chip.hasPlate
            ? CGRect(
                x: chipRect.minX + padding,
                y: chipRect.midY - TimelineMetrics.interactionGlyphSide / 2,
                width: TimelineMetrics.interactionGlyphSide,
                height: TimelineMetrics.interactionGlyphSide
            )
            : nil
        let commandRect = CGRect(
            x: chipRect.minX + padding + glyphRoom,
            y: y,
            width: commandWidth,
            height: height
        )

        let start = elbowX ?? leadingX
        return InteractionHeaderSlot(
            rect: CGRect(
                x: start,
                y: y,
                width: max(0, min(chipRect.maxX, maxX) - start),
                height: height
            ),
            elbowBottom: elbowX.map { _ in y + height },
            avatarRect: avatarRect,
            avatarURL: author?.avatarURL,
            monogram: author?.monogram ?? "?",
            lead: lead,
            leadRect: leadRect,
            leadFace: face,
            leadTracking: tracking,
            leadColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            userID: interaction.userID,
            nameRect: nameRect,
            command: title,
            commandFont: commandFont,
            commandRect: commandRect,
            chipRect: chipRect,
            chip: chip,
            glyphRect: glyphRect
        )
    }
}
