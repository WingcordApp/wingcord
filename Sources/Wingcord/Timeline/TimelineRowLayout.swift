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

/// A message row, laid out.
nonisolated struct MessageRow: @unchecked Sendable {
    var id: MessageID
    var authorID: UserID
    var isRunHead: Bool
    var mentionsMe: Bool
    var isPending: Bool
    var isFailed: Bool

    /// Present only on a run head. Everything else in the run leaves the gutter
    /// empty and reveals a compact timestamp there on hover.
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

    var isBot: Bool
    /// Whether the app is one Discord verified, which puts a check in its
    /// badge — see `AppBadge`.
    var isVerifiedBot = false

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
    /// The invites the text links to, drawn as Discord's invite cards.
    var inviteCards: [InviteCardSlot] = []
    /// The profiles the text links to — Discord's user profile embed. Hosted
    /// over the canvas, not drawn by it; see `UserCardSlot`.
    var userCards: [UserCardSlot] = []
    var reactions: [ReactionSlot]
    /// Add-a-reaction and bookmark, at the end of the reaction row.
    ///
    /// Empty where the message carries no reaction: the row exists because
    /// there is something on it, and two controls floating under a message
    /// nobody has reacted to is chrome the hover bar already offers.
    var reactionControls: [ReactionControlSlot] = []
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
    /// "#general · 4 Aug 2026", when the source channel is one this account can
    /// name. Nil otherwise — inventing a name for a channel the reader has no
    /// access to is a claim the client cannot support.
    var footer: TimelineTextBlock?
    var footerOrigin: CGPoint
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
    /// The channel's own symbol — `#`, a speaker, a megaphone.
    var symbolName: String
    /// Where the glyph sits inside the tile.
    var glyphRect: CGRect
    var title: TimelineTextBlock
    var titleOrigin: CGPoint
    var subtitle: TimelineTextBlock
    var subtitleOrigin: CGPoint
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
    /// Where the name and the size sit inside a file card.
    var titleOrigin: CGPoint = .zero
    var subtitleOrigin: CGPoint = .zero
    /// "0:14", under a clip's play badge. Empty when Discord sent no duration.
    var durationLabel: String = ""
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
    }

    /// Whether the slot draws a picture at all. What decides if the prefetch
    /// should ask for bytes.
    var carriesArtwork: Bool { kind == .image || kind == .video }
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
    /// agree about the strip's own foot.
    var elbowBottom: CGFloat
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
    var elbowBottom: CGFloat
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
    /// The command's name, drawn in a chip.
    var command: String
    var commandRect: CGRect
    /// The chip's own box: the text's rect grown by its padding.
    var chipRect: CGRect
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

    /// The emoji's box inside the chip — where the picture is drawn, where an
    /// animated one's frames are repainted, and what an effect is centred on.
    var glyphRect: CGRect {
        let side = TimelineMetrics.reactionGlyphSide
        return CGRect(
            x: rect.minX + TimelineMetrics.reactionLeadingInset,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
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
    /// Discord's rule (`17256`'s reaction row): the add control is always
    /// shown where a new reaction may be started, and is not rendered at all
    /// where it may not; the bookmark is shown when the message is kept, and
    /// otherwise only while the pointer is on the reactions. **Showing controls
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

    struct Input: Sendable {
        var items: [TimelineItem]
        var width: CGFloat
        var style: MessageTextStyle
        var mentions: MentionContext
        var channelName: String
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
        /// The profile cards the reader has opened past Discord's fold.
        var expandedInvites: Set<InviteCardFold> = []
        /// The colours taken from pictures, by picture — a server card's banner
        /// is its icon's colour where the server chose none. See
        /// `AppModel.derivedPalettes`.
        var palettes: [URL: [UInt32]] = [:]
        /// What each profile card measured — see `AppModel.userCardSizes`.
        var userCardSizes: [UserCardKey: CGSize] = [:]
        /// The server this transcript is in, which the profile cards in it
        /// wear. Nil in a direct message.
        var guildID: GuildID?
        /// Whether the reader may manage this channel, which puts Discord's
        /// Edit Channel button under its welcome header.
        var canEditChannel = false
        /// The reader's sends whose files are going up, by their echo's id.
        /// Empty for nearly every transcript at nearly every moment.
        var uploads: [MessageID: UploadSummary] = [:]
        /// A message request not yet accepted: words only, the media counted
        /// — see `Message.restrictedPreview`.
        var hidesMedia = false
        /// The listening parties still on, by party id — whether a listen-along
        /// card is the live one or Discord's "The listening party is over!".
        var listenAlongLive: Set<String> = []
    }

    /// `@unchecked` for the same reason `MessageTextStyle` is: it carries a
    /// resolved `NSFont`, which is immutable in practice but not marked
    /// `Sendable`. **Resolved on the main actor where this is built**, because
    /// the registry is main-actor state and the layout deliberately is not — and
    /// because resolving here means only the faces actually on screen are ever
    /// registered.
    struct AuthorInfo: @unchecked Sendable {
        var name: String
        var colorValue: UInt32?
        var avatarURL: URL?
        var monogram: String
        var decorationURL: URL?
        var isBot: Bool
        /// A verified app's badge carries a check — `AppBadge`.
        var isVerifiedBot = false
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
        /// What the mention table was at, which is also what a name, a nickname
        /// and a role colour move with — all three are drawn into the row.
        var identityToken: UInt64
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
        var message: Message
        var row: MessageRow

        func matches(
            _ message: Message,
            width: Int,
            presentationRevision: UInt64,
            identityToken: UInt64,
            cardRevision: UInt64,
            isRunHead: Bool,
            isFailed: Bool,
            hidesMedia: Bool,
            listenAlongLive: Bool?
        ) -> Bool {
            self.width == width
                && self.presentationRevision == presentationRevision
                && self.identityToken == identityToken
                && (!carriesCards || self.cardRevision == cardRevision)
                && self.isRunHead == isRunHead
                && self.isFailed == isFailed
                && self.hidesMedia == hidesMedia
                && self.listenAlongLive == listenAlongLive
                && self.message == message
        }
    }

    var presentationRevision: UInt64
    /// Moves when a Spotify card lands. See `CacheEntry.cardRevision`.
    var cardRevision: UInt64 = 0

    /// Whether a message can draw a card that resolves after it is laid out:
    /// an invite or profile link in its text, or a Spotify embed in it or in
    /// what it forwards. The same two gates the builders use, so the answer cannot
    /// disagree with what the row draws.
    static func carriesCards(_ message: Message) -> Bool {
        !InviteCard.codes(in: message.content).isEmpty
            || !UserLink.userIDs(in: message.content).isEmpty
            || message.embeds.contains { $0.providerName == "Spotify" }
            || message.forwarded?.embeds.contains { $0.providerName == "Spotify" } == true
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

            case .message(let message):
                used.insert(message.message.id)
                let isFailed = message.flags.contains(.failed)
                let listenAlongLive = message.message.listenAlong.map { input.listenAlongLive.contains($0.partyID) }
                if let cached = cache[message.message.id],
                   cached.matches(
                       message.message,
                       width: width,
                       presentationRevision: presentationRevision,
                       identityToken: input.mentions.token,
                       cardRevision: cardRevision,
                       isRunHead: message.isRunHead,
                       isFailed: isFailed,
                       hidesMedia: input.hidesMedia,
                       listenAlongLive: listenAlongLive
                   )
                {
                    // Painted, so carried over rather than keyed on.
                    var row = cached.row
                    row.isPending = message.flags.contains(.pending)
                    rows.append(TimelineRow(height: rowHeight(of: row), kind: .message(row)))
                    continue
                }
                let row = message.message.isSystemEvent
                    ? buildSystemMessage(message, input: input)
                    : buildMessage(message, input: input, parser: parser)
                cache[message.message.id] = CacheEntry(
                    width: width,
                    presentationRevision: presentationRevision,
                    identityToken: input.mentions.token,
                    cardRevision: cardRevision,
                    carriesCards: Self.carriesCards(message.message),
                    isRunHead: message.isRunHead,
                    isFailed: isFailed,
                    hidesMedia: input.hidesMedia,
                    listenAlongLive: listenAlongLive,
                    message: message.message,
                    row: row
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
        for slot in row.stickers { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.attachments { bottom = max(bottom, slot.rect.maxY) }
        if let upload = row.upload { bottom = max(bottom, upload.rect.maxY) }
        if let hiddenMedia = row.hiddenMedia { bottom = max(bottom, hiddenMedia.rect.maxY) }
        for slot in row.embeds { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.components { bottom = max(bottom, slot.rect.maxY) }
        if let poll = row.poll { bottom = max(bottom, poll.rect.maxY) }
        if let invite = row.activityInvite { bottom = max(bottom, invite.rect.maxY) }
        if let listenAlong = row.listenAlong { bottom = max(bottom, listenAlong.rect.maxY) }
        for card in row.inviteCards { bottom = max(bottom, card.rect.maxY) }
        for card in row.userCards { bottom = max(bottom, card.rect.maxY) }
        for slot in row.reactions { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.reactionControls { bottom = max(bottom, slot.rect.maxY) }
        if let chip = row.threadChip { bottom = max(bottom, chip.rect.maxY) }
        if let note = row.ephemeralNote { bottom = max(bottom, note.rect.maxY) }
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
        let contentX = TimelineMetrics.contentInset
        let contentWidth = max(80, input.width - contentX - TimelineMetrics.horizontalMargin)

        var y: CGFloat = item.isRunHead ? input.settings.runSpacing : TimelineMetrics.lineSpacing
        var avatarRect: CGRect?
        var authorRect = CGRect(x: contentX, y: y, width: 0, height: 0)
        var timestampRect = CGRect.zero

        // The quoted line, above everything. A reply always breaks its run — see
        // `TimelineReducer` — so the header and the author line below it are
        // always drawn together and the elbow always has a face to rise out of.
        var replyHeader: ReplyHeaderSlot?
        if let reference = message.reference {
            let slot = Self.layoutReplyHeader(
                reference,
                y: y,
                width: input.width,
                style: input.style,
                author: reference.authorID.flatMap { input.authors[$0] }
            )
            replyHeader = slot
            y = slot.rect.maxY + TimelineMetrics.replyGap
        }

        // **Only on the run head.** A run of three answers from one app draws
        // the line once, exactly as the author line is drawn once — repeating
        // "alex used launch" above each is three statements of one fact.
        var interactionHeader: InteractionHeaderSlot?
        if item.isRunHead, let interaction = message.interaction {
            let slot = Self.layoutInteractionHeader(
                interaction,
                y: y,
                width: input.width,
                style: input.style,
                author: input.authors[interaction.userID]
            )
            interactionHeader = slot
            y = slot.rect.maxY + TimelineMetrics.replyGap
        }

        var tagRect = CGRect.zero
        var roleIconRect = CGRect.zero
        if item.isRunHead {
            avatarRect = CGRect(
                x: TimelineMetrics.horizontalMargin,
                y: y,
                width: Metrics.avatarMessage,
                height: Metrics.avatarMessage
            )
            let name = author?.name ?? "Unknown"
            // **Measured in the face it will be DRAWN in.** The bot badge and
            // the timestamp are placed off this width, so measuring in the
            // default face and drawing in another puts both in the wrong place.
            let nameWidth = Self.measure(
                name,
                font: author?.nameFace ?? input.style.authorFont,
                tracking: author?.nameTracking ?? 0
            )
            authorRect = CGRect(
                x: contentX,
                y: y,
                width: nameWidth,
                height: TimelineMetrics.headerHeight
            )
            let stampWidth = Self.measure(
                input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
                font: input.style.metadataFont
            )
            // The server tag, in the same chip the roster draws — see
            // `MemberRowGeometry.tagChipWidth`, which both the reservation and
            // the draw call so the padding cannot end up pooled on one side.
            var afterName = authorRect.maxX
                + (author?.isBot == true ? AppBadge.width(isVerified: author?.isVerifiedBot == true) + 4 : 0)
            if let tag = author?.tag {
                let width = MemberRowGeometry.tagChipWidth(
                    textWidth: Self.measure(tag, font: MemberRowGeometry.tagChipFont),
                    hasBadge: author?.tagBadgeURL != nil
                )
                tagRect = CGRect(
                    x: afterName + 6,
                    // Centred on the name's own line box rather than pinned to
                    // its top: the chip is 15 points and the header is taller.
                    y: y + (TimelineMetrics.headerHeight - MemberRowGeometry.tagChipHeight) / 2,
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
                    y: y + (TimelineMetrics.headerHeight - side) / 2,
                    width: side,
                    height: side
                )
                afterName = roleIconRect.maxX
            }
            timestampRect = CGRect(
                x: afterName + 8,
                y: y,
                width: stampWidth,
                height: TimelineMetrics.headerHeight
            )
            y += TimelineMetrics.headerHeight + TimelineMetrics.headerGap
        }

        // The message this one forwards, quoted. **Above the body**, because a
        // forward that carries a note is "here is a thing, and here is what I
        // think of it" — the thing comes first, which is the order every client
        // draws it in.
        var forwarded: ForwardedSlot?
        if let snapshot = message.forwarded {
            let slot = Self.layoutForward(
                snapshot,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                input: input,
                parser: parser
            )
            forwarded = slot
            y = slot.rect.maxY + TimelineMetrics.attachmentGap
        }

        // Body text.
        //
        // A message that is nothing but emoji is drawn large — the rule every
        // client shares, and the one that decides whether a lone thumbs-up
        // reads as a reply or as punctuation. The decision is made on the
        // PARSED tree, because `<:blobcat:123>` is not emoji by any character
        // test and `:thumbsup:` was expanded server-side long before this.
        var textBlock: TimelineTextBlock?
        let textOrigin = CGPoint(x: contentX, y: y)
        // **`displayedContent`, not `content`.** A message that is nothing but a
        // link to a picture draws the picture — see `Message.displayedContent`.
        // Display only: the words the message actually carries are still what a
        // copy, a search and an accessibility label get.
        let drawnContent = input.settings.showsEmbeds ? message.displayedContent : message.content
        if !drawnContent.isEmpty {
            let document = parser.parse(drawnContent)
            let sized = document.jumboEmojiCount == nil ? input.style : input.style.jumbo
            // A refused send's words are Discord's critical ink — `.isFailed`.
            let style = item.flags.contains(.failed) ? sized.failed : sized
            let text = MessageTextBuilder.build(
                document: document,
                context: input.mentions,
                style: style
            )
            let block = TimelineTextBlock(text: text, width: contentWidth, style: style)
            textBlock = block
            y += block.size.height
        }

        // Stickers, above attachments: a sticker IS the message, and one drawn
        // under a screenshot reads as a caption on it.
        var stickers: [StickerSlot] = []
        for sticker in message.stickers {
            y += TimelineMetrics.attachmentGap
            let side = min(Metrics.stickerInline, contentWidth)
            stickers.append(StickerSlot(
                rect: CGRect(x: contentX, y: y, width: side, height: side),
                sticker: sticker,
                url: CDN.sticker(id: sticker.id, format: sticker.format),
                isVector: sticker.format == .lottie,
                isAnimated: sticker.format.isAnimated
            ))
            y += side
        }

        // Attachments.
        let attachments = Self.attachmentSlots(
            message.attachments,
            origin: CGPoint(x: contentX, y: y),
            availableWidth: contentWidth,
            style: input.style
        )
        for slot in attachments { y = max(y, slot.rect.maxY) }

        var upload: UploadCardSlot?
        if let summary = input.uploads[message.id] {
            y += TimelineMetrics.attachmentGap
            let slot = Self.uploadSlot(
                summary,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            upload = slot
            y = slot.rect.maxY
        }

        var hiddenMedia: HiddenMediaSlot?
        if hiddenMediaCount > 0 {
            y += TimelineMetrics.attachmentGap
            let slot = Self.hiddenMediaSlot(
                count: hiddenMediaCount,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            hiddenMedia = slot
            y = slot.rect.maxY
        }

        // A poll IS the message: it arrives beside an empty body, so a renderer
        // that does not know about one draws an author line over a blank row.
        var poll: PollSlot?
        if let value = message.poll {
            y += TimelineMetrics.attachmentGap
            let slot = PollLayoutEngine.layout(
                value,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            poll = slot
            y = slot.rect.maxY
        }

        // An activity invitation, for the same reason a poll is here: the
        // launch message has no content, no embed and no component, so a
        // renderer that does not know about one draws an author line over a
        // blank row.
        var activityInvite: ActivityInviteSlot?
        if let value = message.activityInvite {
            y += TimelineMetrics.attachmentGap
            let slot = ActivityInviteLayoutEngine.layout(
                value,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            activityInvite = slot
            y = slot.rect.maxY
        }

        // An invitation to listen along, for the same reason: content `""`,
        // and the card is the message.
        var listenAlong: ListenAlongSlot?
        if let value = message.listenAlong {
            y += TimelineMetrics.attachmentGap
            let slot = ListenAlongLayoutEngine.layout(
                value,
                isLive: input.listenAlongLive.contains(value.partyID),
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            listenAlong = slot
            y = slot.rect.maxY
        }

        // Embeds. A link unfurl, a bot's status card, a release note — all the
        // same object with different subsets populated, which is why the layout
        // branches on what is present rather than on the `kind` string.
        // Skipped WHOLESALE when the reader has turned unfurls off — not laid
        // out and then hidden. An embed is a framesetting pass over a title, a
        // markdown description and a field grid; measuring one nobody will see
        // is the most expensive way to draw nothing.
        var embeds: [EmbedSlot] = []
        // **A poll result's embed is not drawn**: it is a bag of *fields* — the
        // question, the winner, the counts — that the row's own sentence already
        // says, and drawn as an ordinary card it is a grey box listing
        // `victor_answer_id` at somebody. See `Message.pollResult`.
        // Filled by a Components V2 tree — the message's own, below, or an
        // embed's — and by rows of buttons.
        var components: [ComponentSlot] = []
        for embed in input.settings.showsEmbeds ? message.drawableEmbeds : [] {
            // A profile link's unfurl, where its profile card is drawn instead —
            // Discord shows the card and not both.
            if let url = embed.url, let userID = UserLink.userID(inURL: url),
               input.userCardSizes[UserCardKey(userID: userID, guildID: input.guildID)] != nil
            {
                continue
            }
            y += TimelineMetrics.attachmentGap
            // **An embed of type `components` is its components**: Discord
            // draws the tree in place of a card, and it is laid out exactly as
            // a message's own is, cards and controls both.
            if embed.kind == "components", !embed.components.isEmpty {
                let tree = ComponentsLayoutEngine.layout(
                    embed.components,
                    origin: CGPoint(x: contentX, y: y),
                    width: min(Metrics.embedMaxWidth, contentWidth),
                    context: ComponentsLayoutEngine.Context(
                        style: input.style,
                        mentions: input.mentions,
                        parser: parser
                    )
                )
                embeds.append(contentsOf: tree.cards)
                components.append(contentsOf: tree.controls)
                y = tree.bottom
                continue
            }
            let slot = EmbedLayoutEngine.layout(
                embed,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style,
                mentions: input.mentions,
                parser: parser,
                spotify: Self.spotifyCard(for: embed, in: input)
            )
            embeds.append(slot)
            y = slot.rect.maxY
        }

        // The invites the text links to — Discord's invite card, one per code,
        // once the answer has arrived. Until then the link is only a link.
        var inviteCards: [InviteCardSlot] = []
        for code in InviteCard.codes(in: message.content) {
            guard let lookup = input.invites[code] else { continue }
            y += TimelineMetrics.attachmentGap
            let slot = InviteCardLayoutEngine.layout(
                code: code,
                lookup: lookup,
                sentByReader: input.mentions.selfIDs.contains(message.authorID.rawValue),
                selfIDs: input.mentions.selfIDs,
                isExpanded: input.expandedInvites.contains(InviteCardFold(message: message.id, code: code)),
                palettes: input.palettes,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            inviteCards.append(slot)
            y = slot.rect.maxY
        }

        // The profiles the text links to, once each card has measured itself.
        // Until then the link is only a link, exactly as an invite is.
        var userCards: [UserCardSlot] = []
        if !input.userCardSizes.isEmpty {
            for userID in UserLink.userIDs(in: message.content) {
                let key = UserCardKey(userID: userID, guildID: input.guildID)
                guard let size = input.userCardSizes[key] else { continue }
                y += TimelineMetrics.attachmentGap
                let slot = UserCardSlot(rect: CGRect(x: contentX, y: y, width: size.width, height: size.height), key: key)
                userCards.append(slot)
                y = slot.rect.maxY
            }
        }

        // A Components V2 tree, which is the whole body of the message it
        // arrives on. It produces the same two things an embed does — cards and
        // controls — so nothing downstream needs a case for it.
        if !message.displayComponents.isEmpty {
            y += TimelineMetrics.attachmentGap
            let tree = ComponentsLayoutEngine.layout(
                message.displayComponents,
                origin: CGPoint(x: contentX, y: y),
                width: min(Metrics.embedMaxWidth, contentWidth),
                context: ComponentsLayoutEngine.Context(
                    style: input.style,
                    mentions: input.mentions,
                    parser: parser
                )
            )
            embeds.append(contentsOf: tree.cards)
            components.append(contentsOf: tree.controls)
            y = tree.bottom
        } else if !message.components.isEmpty {
            // The ordinary flat form: rows of buttons under a body or an embed.
            y += TimelineMetrics.componentGap
            y = Self.layoutComponents(
                message.components,
                contentX: contentX,
                y: y,
                width: contentWidth,
                style: input.style,
                into: &components
            )
        }

        // Reaction chips.
        var reactions: [ReactionSlot] = []
        var reactionControls: [ReactionControlSlot] = []
        y = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: y,
            width: contentWidth,
            style: input.style,
            // Discord never offers a bookmark on the reader's own message.
            offersBookmark: !input.mentions.selfIDs.contains(message.authorID.rawValue),
            into: &reactions,
            controls: &reactionControls
        )

        // The thread this message started, under its content and above the
        // ephemeral note — it is about the message, and the note is about the
        // whole row.
        let chip = Self.layoutThreadChip(
            message.thread,
            contentX: contentX,
            y: y,
            width: contentWidth,
            style: input.style
        )
        y = chip.bottom

        // "Only you can see this", last — under everything, which is where a
        // note about the whole message belongs and where Discord's own is.
        var ephemeralNote: EphemeralNoteSlot?
        if message.isEphemeral {
            let font = input.style.metadataFont
            let noteWidth = Self.measure(Self.ephemeralNoteText, font: font)
            let dismissWidth = Self.measure(Self.ephemeralDismissText, font: font)
            let noteEnd = contentX + TimelineMetrics.ephemeralNoteGlyphRoom + noteWidth
            let top = y + TimelineMetrics.ephemeralNoteGap
            // The control's own rect, measured rather than derived from the
            // line's: it is the only part that takes a click, and a target that
            // spans the note would dismiss the message on a click meant for
            // nothing at all.
            let dismissRect = CGRect(
                x: noteEnd + TimelineMetrics.ephemeralNoteSeparatorRoom,
                y: top,
                width: dismissWidth,
                height: TimelineMetrics.ephemeralNoteHeight
            )
            ephemeralNote = EphemeralNoteSlot(
                rect: CGRect(
                    x: contentX,
                    y: top,
                    width: dismissRect.maxX - contentX,
                    height: TimelineMetrics.ephemeralNoteHeight
                ),
                text: Self.ephemeralNoteText,
                dismissRect: dismissRect,
                dismissText: Self.ephemeralDismissText
            )
        }

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            isRunHead: item.isRunHead,
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
            authorFace: author?.nameFace,
            authorTracking: author?.nameTracking ?? 0,
            authorGradient: item.isRunHead
                ? author?.gradient.map { $0.map { NSColor(Color(hex: $0)) } }
                : nil,
            authorStyle: item.isRunHead ? author?.nameStyle : nil,
            authorColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            authorRect: authorRect,
            timestampText: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
            timestampRect: timestampRect,
            gutterTimestampText: input.settings.time(message.sentAt),
            isBot: author?.isBot ?? false,
            isVerifiedBot: author?.isVerifiedBot ?? false,
            tag: item.isRunHead ? author?.tag : nil,
            tagBadgeURL: item.isRunHead ? author?.tagBadgeURL : nil,
            tagRect: tagRect,
            roleIconURL: item.isRunHead ? author?.roleIconURL : nil,
            roleEmoji: item.isRunHead ? author?.roleEmoji : nil,
            roleIconRect: roleIconRect,
            forwarded: forwarded,
            textBlock: textBlock,
            textOrigin: textOrigin,
            attachments: attachments,
            upload: upload,
            hiddenMedia: hiddenMedia,
            stickers: stickers,
            embeds: embeds,
            components: components,
            poll: poll,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            inviteCards: inviteCards,
            userCards: userCards,
            reactions: reactions,
            reactionControls: reactionControls,
            threadChip: chip.slot,
            accessibilityLabel: Self.accessibilityLabel(
                author: author?.name ?? "Unknown",
                time: input.settings.time(message.sentAt),
                body: textBlock?.text.plainLabel ?? "",
                attachments: message.attachments.count,
                stickers: stickers.map(\.sticker.name),
                extra: Self.spokenBody(of: message),
                isEphemeral: message.isEphemeral,
                isEdited: message.editedAt != nil,
                reactions: message.reactions,
                muted: input.settings.mutedSpokenDetails
            )
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
        let author = input.authors[message.authorID]
        let name = author?.name ?? "Someone"
        let sentence = SystemMessageText.sentence(for: message, name: name)
        let contentX = TimelineMetrics.contentInset
        let contentWidth = max(80, input.width - contentX - TimelineMetrics.horizontalMargin)
        let y = input.settings.runSpacing

        let text = Self.systemText(
            sentence,
            authorID: message.authorID,
            colorValue: author?.colorValue,
            time: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
            style: input.style
        )
        let block = TimelineTextBlock(text: text, width: contentWidth, style: input.style)

        // A join message can be reacted to like any other, and dropping them
        // would be dropping data the payload already carries.
        var reactions: [ReactionSlot] = []
        var reactionControls: [ReactionControlSlot] = []
        let reactionsBottom = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: y + block.size.height,
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

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            isRunHead: false,
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
            isBot: false,
            textBlock: block,
            textOrigin: CGPoint(x: contentX, y: y),
            attachments: [],
            stickers: [],
            embeds: [],
            components: [],
            poll: nil,
            activityInvite: nil,
            reactions: reactions,
            reactionControls: reactionControls,
            threadChip: systemChip.slot,
            systemSymbol: sentence?.symbolName ?? "circle",
            systemTint: Self.tintColor(sentence?.tint),
            accessibilityLabel: text.plainLabel
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
        time: String,
        style: MessageTextStyle
    ) -> MessageText {
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
            output.append(NSAttributedString(string: sentence.name, attributes: [
                .font: style.boldFont,
                .foregroundColor: colorValue.map { NSColor(Color(hex: $0)) }
                    ?? style.primaryColor,
            ]))
            links.append(.init(
                range: NSRange(location: start, length: output.length - start),
                target: .user(authorID)
            ))
        }
        output.append(NSAttributedString(string: sentence.suffix, attributes: body))
        output.append(NSAttributedString(string: "  " + time, attributes: [
            .font: style.metadataFont,
            .foregroundColor: style.tertiaryColor,
        ]))
        return .plain(output, links: links)
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
    private static func layoutReplyHeader(
        _ reference: MessageReference,
        y: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        author: AuthorInfo?
    ) -> ReplyHeaderSlot {
        let height = TimelineMetrics.replyHeight
        let avatarRect = CGRect(
            x: TimelineMetrics.contentInset,
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
        // rather than leaving a blank strip nobody can read.
        let quote: String
        if isUnavailable {
            quote = "Original message was deleted"
        } else if !reference.excerpt.isEmpty {
            quote = reference.excerpt
        } else if reference.hasAttachment {
            quote = "Click to see attachment"
        } else {
            quote = ""
        }
        let excerptX = isUnavailable
            ? avatarRect.maxX + TimelineMetrics.replyItemGap
            : nameRect.maxX + TimelineMetrics.replyItemGap
        let trailing = width - TimelineMetrics.horizontalMargin
        let excerptRect = CGRect(
            x: excerptX,
            y: y,
            width: max(0, trailing - excerptX),
            height: height
        )

        // The strip's own bounds: from the elbow to wherever the quote ends, so
        // a click anywhere along the line it draws lands on it.
        let quoteWidth = quote.isEmpty
            ? 0
            : min(excerptRect.width, measure(quote, font: quoteFont))
        let rect = CGRect(
            x: TimelineMetrics.replyElbowX,
            y: y,
            width: max(0, excerptX + quoteWidth - TimelineMetrics.replyElbowX),
            height: height
        )

        return ReplyHeaderSlot(
            rect: rect,
            // The elbow's leg drops to the top of the avatar under it, which is
            // where the author line begins — the connector then reads as coming
            // out of the face rather than as a bracket floating beside it.
            elbowBottom: y + height + TimelineMetrics.replyGap,
            avatarRect: isUnavailable ? .zero : avatarRect,
            avatarURL: author?.avatarURL,
            monogram: author?.monogram ?? "?",
            name: name,
            nameRect: nameRect,
            nameFace: face,
            nameTracking: tracking,
            nameColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            excerpt: quote,
            excerptRect: excerptRect,
            isBot: reference.isAuthorBot,
            targetID: isUnavailable ? nil : reference.messageID
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

    private static func layoutReactions(
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
                countWidth: measure("\(count)", font: style.metadataFont)
            )
            if x + chipWidth > contentX + width, x > contentX {
                x = contentX
                y += TimelineMetrics.reactionChipHeight + 4
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
            x += chipWidth + 4
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

        // The two controls wrap with the chips rather than being pinned to the
        // row's end: a message with eight reactions on a narrow column ends its
        // last line wherever it ends, and a control pinned to the right of the
        // measure would sit alone under a gap.
        let kinds: [ReactionControlSlot.Kind] = offersBookmark ? [.addReaction, .bookmark] : [.addReaction]
        for kind in kinds {
            let side = TimelineMetrics.reactionControlSide
            if x + side > contentX + width, x > contentX {
                x = contentX
                y += TimelineMetrics.reactionChipHeight + 4
            }
            controls.append(ReactionControlSlot(
                rect: CGRect(x: x, y: y, width: side, height: side),
                kind: kind
            ))
            x += side + 4
        }
        return y + TimelineMetrics.reactionChipHeight
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
        let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold)

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
                    spotify: Self.spotifyCard(for: embed, in: input)
                )
                embeds.append(slot)
                y = slot.rect.maxY
            }
        }

        // Where it came from. **Only when this account can name the channel** —
        // a forward out of a server the reader is not in has a snowflake and no
        // name, and inventing one is a claim the client cannot support.
        var footer: TimelineTextBlock?
        var footerOrigin = CGPoint.zero
        if let channelID = snapshot.channelID,
           let channel = input.mentions.channels[channelID]
        {
            y += TimelineMetrics.forwardLineGap
            footer = TimelineTextBlock(
                text: .plain(NSAttributedString(
                    string: (channel.isConversation ? "@" : "#") + channel.name,
                    attributes: [
                        .font: style.metadataFont,
                        .foregroundColor: style.tertiaryColor,
                    ]
                )),
                width: contentWidth,
                style: style
            )
            footerOrigin = CGPoint(x: contentX, y: y)
            y += footer?.size.height ?? 0
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
            footer: footer,
            footerOrigin: footerOrigin
        )
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
        let side = TimelineMetrics.conversationStartIconSide
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
        let title = TimelineTextBlock(
            text: .plain(NSAttributedString(
                // Discord's own words, exclamation and all.
                string: "Welcome to #\(input.channelName)!",
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
        y += title.size.height + TimelineMetrics.conversationStartLineGap

        let subtitle = TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: "This is the start of the #\(input.channelName) channel.",
                attributes: [
                    .font: style.bodyFont,
                    .foregroundColor: style.secondaryColor,
                ]
            )),
            width: available,
            style: style
        )
        let subtitleOrigin = CGPoint(x: margin, y: y)
        y += subtitle.size.height

        var topic: TimelineTextBlock?
        var topicOrigin = CGPoint.zero
        if let text = input.channelTopic?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        var editButton: ConversationStartSlot.EditButton?
        if input.canEditChannel {
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
    static func attachmentSlots(
        _ attachments: [Attachment],
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
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
            let slot = nonVisualSlot(
                attachments[index],
                origin: CGPoint(x: origin.x, y: y),
                availableWidth: availableWidth,
                style: style
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
        style: MessageTextStyle
    ) -> AttachmentSlot {
        if attachment.waveform != nil || attachment.durationSeconds != nil,
           attachment.contentType?.hasPrefix("audio/") ?? false
        {
            return voiceSlot(attachment, origin: origin, availableWidth: availableWidth)
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
            CDN.videoPoster(proxyURL: attachment.proxyURL, width: decodeWidth, height: decodeHeight)
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
            placeholder: attachment.placeholder
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

    /// A voice note: a waveform and how long it runs.
    private static func voiceSlot(
        _ attachment: Attachment,
        origin: CGPoint,
        availableWidth: CGFloat
    ) -> AttachmentSlot {
        let width = min(availableWidth, TimelineMetrics.voiceNoteMaxWidth)
        return AttachmentSlot(
            rect: CGRect(
                x: origin.x, y: origin.y, width: width, height: TimelineMetrics.voiceNoteHeight
            ),
            url: nil,
            isSpoiler: attachment.isSpoiler,
            altText: attachment.description,
            decodeWidth: width,
            kind: .voice,
            filename: attachment.filename,
            durationLabel: Self.durationLabel(attachment.durationSeconds)
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
        let sizeLabel = AttachmentLimits.describe(bytes: attachment.size)
        let inset = TimelineMetrics.attachmentCardInset
        let textX = origin.x + inset + TimelineMetrics.attachmentCardGlyphSide + Spacing.base
        let intrinsic = max(
            measure(attachment.filename, font: style.bodyFont),
            measure(sizeLabel, font: style.metadataFont)
        )
        let width = min(
            min(availableWidth, TimelineMetrics.attachmentCardMaxWidth),
            (textX - origin.x) + intrinsic + inset
        )
        let height = TimelineMetrics.attachmentCardHeight
        // Two lines stacked about the card's middle: the name on the upper
        // baseline, the size on the lower.
        let block = style.bodyFont.pointSize + style.metadataFont.pointSize + 4
        let top = origin.y + (height - block) / 2
        return AttachmentSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: max(120, width), height: height),
            url: nil,
            isSpoiler: attachment.isSpoiler,
            altText: attachment.description,
            decodeWidth: width,
            kind: .file,
            filename: attachment.filename,
            sizeLabel: sizeLabel,
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
        let inset = TimelineMetrics.attachmentCardInset
        let rect = CGRect(
            x: origin.x,
            y: origin.y,
            width: min(availableWidth, TimelineMetrics.attachmentCardMaxWidth),
            height: TimelineMetrics.attachmentCardHeight
        )
        let cancelSide = TimelineMetrics.uploadCancelSide
        let cancelRect = CGRect(
            x: rect.maxX - inset - cancelSide,
            y: rect.midY - cancelSide / 2,
            width: cancelSide,
            height: cancelSide
        )
        let textX = rect.minX + inset + TimelineMetrics.attachmentCardGlyphSide + Spacing.base
        let room = max(0, cancelRect.minX - Spacing.base - textX)
        let sizeLabel = "— \(AttachmentLimits.describe(bytes: summary.size))"
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
        return label
    }
}

// MARK: - The interaction header

nonisolated extension TimelineLayoutEngine {
    /// "alex used **launch**".
    ///
    /// Laid out against the reply header's own metrics so the two lines sit at
    /// the same height with the same elbow — see `InteractionHeaderSlot`.
    static func layoutInteractionHeader(
        _ interaction: MessageInteraction,
        y: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        author: AuthorInfo?
    ) -> InteractionHeaderSlot {
        let height = TimelineMetrics.replyHeight
        let avatarRect = CGRect(
            x: TimelineMetrics.contentInset,
            y: y + (height - TimelineMetrics.replyAvatarSide) / 2,
            width: TimelineMetrics.replyAvatarSide,
            height: TimelineMetrics.replyAvatarSide
        )

        let font = style.metadataFont
        // **The name without an `@`.** A reply quotes somebody, so it reads
        // `@name`; this is a sentence about them, and "@alex used launch" is
        // not one.
        let name = author?.name ?? "Unknown"
        let lead = "\(name) used"
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

        let commandWidth = measure(interaction.name, font: font, tracking: 0)
        let chipRect = CGRect(
            x: leadRect.maxX + TimelineMetrics.replyItemGap,
            y: y + (height - TimelineMetrics.interactionChipHeight) / 2,
            width: commandWidth + TimelineMetrics.interactionChipPadding * 2,
            height: TimelineMetrics.interactionChipHeight
        )
        let commandRect = CGRect(
            x: chipRect.minX + TimelineMetrics.interactionChipPadding,
            y: y,
            width: commandWidth,
            height: height
        )

        return InteractionHeaderSlot(
            rect: CGRect(
                x: TimelineMetrics.replyElbowX,
                y: y,
                width: max(0, min(chipRect.maxX, width) - TimelineMetrics.replyElbowX),
                height: height
            ),
            elbowBottom: y + height,
            avatarRect: avatarRect,
            avatarURL: author?.avatarURL,
            monogram: author?.monogram ?? "?",
            lead: lead,
            leadRect: leadRect,
            leadFace: face,
            leadTracking: tracking,
            leadColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            command: interaction.name,
            commandRect: commandRect,
            chipRect: chipRect
        )
    }
}
