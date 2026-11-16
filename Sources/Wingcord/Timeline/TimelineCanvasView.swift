import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// The view that paints the transcript.
///
/// **It is viewport-sized, not document-sized, and that is the entire
/// virtualisation.** The document view above it is the full content height, so
/// the scroller is correct; this view is a window onto it, sized to the viewport
/// plus an overscan margin, with `bounds.origin` kept equal to `frame.origin` so
/// drawing stays in document coordinates and nothing downstream has to convert.
///
/// The consequence is the point: it only moves when it is about to run out of
/// overscan. Between moves — hundreds of points of travel — **nothing happens at
/// all**. The clip view slides over a static layer and the compositor does the
/// whole scroll on the GPU. A document-sized layer instead means a backing store
/// proportional to the history and a redraw every time it resizes.
///
/// Two layer settings are load-bearing and both are easy to lose:
///
///  - `layerContentsRedrawPolicy = .onSetNeedsDisplay`. AppKit's default redraws
///    a layer-backed view merely because its frame resized, which turns every
///    page of history into a full-layer display transaction.
///  - `layer.drawsAsynchronously = false`. Pointer-driven state has to paint in
///    the same pass as the event that caused it; asynchronously, hit testing has
///    already moved on while the previous row's hover is still on screen.
final class TimelineCanvasView: NSView {

    // MARK: Content

    private(set) var rows: [TimelineRow] = []
    /// Cumulative top offsets, one longer than `rows`, so `offsets[i]` is row
    /// *i*'s top and `offsets[count]` is the content height. One array and a
    /// binary search answers "which row is at this y" in log time; a linear walk
    /// answers it in a scroll's worth of time.
    private(set) var offsets: [CGFloat] = [0]

    var style: MessageTextStyle {
        didSet { stickyFaces.style = style }
    }
    /// Whether a continuation row draws its gutter time without being pointed
    /// at. Set beside `style` from the same revision, for the same reason.
    var alwaysShowsTimestamps = false
    /// View › Hide Times: no time drawn unless pointed at, the one beside an
    /// author's name included. From the same revision.
    var hidesTimes = false
    var contentHeight: CGFloat { offsets[offsets.count - 1] }
    /// The empty space above the first row — `TimelineViewportPolicy
    /// .leadingSpace`. It is the first offset, so every rectangle, every hit
    /// test and every layer placed from a row's frame follows it with nothing
    /// to remember.
    var leadingSpace: CGFloat { offsets[0] }

    // MARK: Interaction state

    private var hoveredRow: Int?
    /// The hovered run head's prepared name, and the key it was built under.
    /// Held rather than rebuilt per frame — see `styledAuthorName(for:)`.
    private var styledName: (key: StyledNameKey, prepared: DisplayNameEffectPainter.Prepared)?

    /// The moving face and decoration on the row under the pointer.
    ///
    /// **One row at a time**, shared with the member list which has the
    /// identical problem — see `HoverAvatarFilm`. A channel of four hundred
    /// messages from a decorated server is otherwise dozens of filmstrips
    /// resident and dozens of layers rewritten every tick, for faces nobody is
    /// looking at.
    private let avatarFilm = HoverAvatarFilm()

    /// Wires that film to this view. Called once, from `init`.
    ///
    /// A strip that lands after a hop has to repaint the row *and* re-ask for
    /// the clock: `hasVisibleFilm` was false when the pointer arrived, so
    /// nothing is subscribed yet and the first frame would be the only one.
    private func adoptAvatarFilm() {
        avatarFilm.onFrameChange = { [weak self] in
            guard let self else { return }
            self.invalidateRow(self.hoveredRow)
            // A bubble's face plays on its own layer, wherever it is riding.
            self.stickyFaces.refreshContents()
            self.refreshStickerAnimation()
        }
    }

    /// Wires the effects to this view. Called once, from `init`.
    ///
    /// An effect appearing or ending changes what its chip draws — its emoji
    /// goes to the effect, and the chip shakes — so the chip is repainted and
    /// the clock re-asked: the shake is the one part of an effect this view
    /// draws itself.
    private func adoptBurstEffects() {
        burstEffects.locate = { [weak self] key in
            guard let self, let chip = self.burstChip(for: key) else { return nil }
            let glyph = chip.slot.glyphRect.offsetBy(dx: chip.rowFrame.minX, dy: chip.rowFrame.minY)
            return CGPoint(x: glyph.midX, y: glyph.midY)
        }
        burstEffects.onChange = { [weak self] key in
            guard let self else { return }
            self.invalidateBurstChip(key)
            self.refreshStickerAnimation()
            // A chip lends its emoji to the effect and takes it back after.
            self.reconcileFilms()
        }
    }

    /// The channel these rows are in. A different one ends every effect and
    /// forgets which chips have had their ambient play.
    func apply(channelID: ChannelID) {
        guard self.channelID != channelID else { return }
        self.channelID = channelID
        selection = nil
        isSelecting = false
        burstEffects.stopAll()
        ambientPlayed.removeAll()
        pendingArrivals.removeAll()
        hoveredBurst = nil
        clearTooltips()
    }

    /// The message whose reaction picker is open, or nil. Its row keeps its
    /// two controls drawn while the pointer is away on the picker.
    func apply(pinnedReactionMessage: MessageID?) {
        guard pinnedReactionMessage != self.pinnedReactionMessage else { return }
        let previous = self.pinnedReactionMessage
        self.pinnedReactionMessage = pinnedReactionMessage
        for id in [previous, pinnedReactionMessage] {
            if let id { invalidateMessage(id) }
        }
    }

    /// Whether a new reaction may be started in this channel — the add
    /// control at the end of every reaction row. See `canAddReactions`.
    func apply(canAddReactions: Bool) {
        guard self.canAddReactions != canAddReactions else { return }
        self.canAddReactions = canAddReactions
        // Every reaction row's controls move up a slot or back.
        setNeedsDisplay(visibleRect)
        updateHover(at: currentPointerLocation())
    }

    /// Whether the reader may send super reactions. See `canSuperReact`.
    func apply(canSuperReact: Bool) {
        guard self.canSuperReact != canSuperReact else { return }
        self.canSuperReact = canSuperReact
        // The chip under the pointer may have just become a control, or
        // stopped being one.
        updateHover(at: currentPointerLocation())
    }

    /// A super reaction chip, by the reaction it shows: its slot and the frame
    /// of the row it sits in.
    private func burstChip(
        for key: SuperReactionEffects.Key
    ) -> (slot: ReactionSlot, rowFrame: CGRect)? {
        guard let index = rows.firstIndex(where: { $0.messageID == key.messageID }),
              case .message(let row) = rows[index].kind,
              let slot = row.reactions.first(where: {
                  $0.kind == .burst && $0.emoji.reactionKey == key.emoji
              })
        else { return nil }
        return (slot, rowFrame(at: index))
    }

    /// Repaints one super reaction chip, glow and shake included.
    private func invalidateBurstChip(_ key: SuperReactionEffects.Key) {
        guard let chip = burstChip(for: key) else { return }
        setNeedsDisplay(
            chip.slot.rect
                .offsetBy(dx: chip.rowFrame.minX, dy: chip.rowFrame.minY)
                .insetBy(dx: -Self.burstBleed, dy: -Self.burstBleed)
        )
    }

    /// How far a super reaction chip's drawing reaches past the chip: its glow,
    /// plus the two points and one degree of its shake.
    private static let burstBleed = (TimelineMetrics.superReactionGlowBlur * 1.5).rounded(.up) + 3

    /// Starts `slot`'s effect, if it has one to play.
    private func playEffect(
        _ slot: ReactionSlot,
        on row: MessageRow,
        trigger: SuperReactionEffects.Trigger
    ) {
        guard AnimationClock.playsAnimatedEmoji, let channelID,
              let palette = slot.palette
        else { return }
        burstEffects.play(
            SuperReactionEffects.Request(
                key: SuperReactionEffects.Key(messageID: row.id, emoji: slot.emoji.reactionKey),
                emoji: slot.emoji,
                channelID: channelID,
                accent: palette.style(isLight: ThemeInk.current.isLight).accent
            ),
            trigger: trigger
        )
    }

    /// A super reaction landed somewhere. Played when it landed on a chip the
    /// reader can see — an effect nobody can see is a layer for nothing.
    private func superReactionArrived(_ emoji: EmojiRef, on messageID: MessageID) {
        guard let index = rows.firstIndex(where: { $0.messageID == messageID }),
              case .message(let row) = rows[index].kind
        else { return }
        guard let slot = row.reactions.first(where: {
            $0.kind == .burst && $0.emoji.isSameReaction(as: emoji)
        }) else {
            pendingArrivals.append((messageID, emoji, CACurrentMediaTime() + 1.5))
            return
        }
        guard slot.rect.offsetBy(dx: 0, dy: offsets[index]).intersects(visibleRect) else { return }
        playEffect(slot, on: row, trigger: .arrival)
    }

    /// Plays the arrivals whose chips have now been laid out, and forgets the
    /// ones that waited too long to still be news.
    private func playPendingArrivals() {
        guard !pendingArrivals.isEmpty else { return }
        let now = CACurrentMediaTime()
        let waiting = pendingArrivals
        pendingArrivals.removeAll()
        for arrival in waiting where arrival.until > now {
            guard let index = rows.firstIndex(where: { $0.messageID == arrival.messageID }),
                  case .message(let row) = rows[index].kind
            else { continue }
            guard let slot = row.reactions.first(where: {
                $0.kind == .burst && $0.emoji.isSameReaction(as: arrival.emoji)
            }) else {
                pendingArrivals.append(arrival)
                continue
            }
            if slot.rect.offsetBy(dx: 0, dy: offsets[index]).intersects(visibleRect) {
                playEffect(slot, on: row, trigger: .arrival)
            }
        }
    }

    /// Schedules the ambient roll while a super reaction chip is within the
    /// canvas, and drops it the moment none is.
    ///
    /// **Five seconds, like Discord's**, and each tick costs a walk of the
    /// visible rows' chips. A transcript with no super reaction on it holds no
    /// timer at all.
    private func refreshAmbient() {
        let wanted = window != nil && visibleRowRange().contains { index in
            guard case .message(let row) = rows[index].kind else { return false }
            return row.reactions.contains { $0.kind == .burst && $0.palette != nil }
        }
        if wanted, ambientTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rollAmbient() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .default)
            ambientTimer = timer
        } else if !wanted, let timer = ambientTimer {
            timer.invalidate()
            ambientTimer = nil
        }
    }

    /// Discord's ambient roll, per chip on screen: a digit, plus up to four
    /// for a busier chip, and above seven plays — so a lone super reaction
    /// plays by itself about one tick in five and a chip of five or more about
    /// three in five. Each chip plays this way at most once per channel visit.
    ///
    /// **Gated harder than Discord's**, which checks only the animated-emoji
    /// setting. An effect nobody asked for is exactly what Reduce Motion is
    /// for, so it is honoured here too, and nothing rolls for a window that
    /// is hidden or an app in the background.
    private func rollAmbient() {
        guard AnimationClock.playsAnimatedEmoji, !isScrolling, NSApp.isActive,
              window?.occlusionState.contains(.visible) == true
        else { return }
        let visible = visibleRect
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            for slot in row.reactions where slot.kind == .burst && slot.palette != nil {
                let key = SuperReactionEffects.Key(messageID: row.id, emoji: slot.emoji.reactionKey)
                guard !ambientPlayed.contains(key), burstEffects.shownAt(key) == nil,
                      slot.rect.offsetBy(dx: 0, dy: offsets[index]).intersects(visible)
                else { continue }
                let roll = Int.random(in: 0..<10) + min(slot.count - 1, 4)
                guard roll > 7 else { continue }
                ambientPlayed.insert(key)
                playEffect(slot, on: row, trigger: .ambient)
            }
        }
    }
    /// The origin, in row space, of the button under the pointer.
    ///
    /// Identified by its origin rather than by an index: the index of a button
    /// only means anything beside the array it came from, and the canvas keeps
    /// no such array between passes.
    private var hoveredComponent: CGPoint?
    /// The body's plated link or concealed spoiler under the pointer — see
    /// `TimelineRowPainter.TextState`.
    private var hoveredPlate: Int?
    private var hoveredSpoiler: Int?
    /// Which attachment the pointer is over. Its own field for the reason
    /// `TimelineRowPainter.State.hoveredAttachment` gives.
    private var hoveredAttachment: Int?
    /// The link or the name under the pointer, for their underline.
    private var hoveredLink: MessageText.LinkTarget?
    private var isAuthorNameHovered = false
    /// Which unfurled embed the pointer is over. Its own field beside the
    /// attachment's, because a message can carry both a pasted `.gif` file and a
    /// Tenor link and one field would put the star on the wrong one.
    private var hoveredEmbed: Int?
    private var highlightedMessageID: MessageID?
    private var revealedSpoilers: [MessageID: Set<Int>] = [:]
    /// Which spoilered attachments have been uncovered, keyed the same way and
    /// deliberately in a separate table — see `TimelineRowPainter.State`.
    private var revealedAttachments: [MessageID: Set<Int>] = [:]
    /// A forward's uncovered files, by message — a list of their own.
    private var revealedForwardAttachments: [MessageID: Set<Int>] = [:]
    /// The picture the media viewer has out of its box — on stage, or flying
    /// there or back — whose box is left empty, so the picture is never in two
    /// places (REDESIGN.md D8). See `MediaSources`.
    var liftedAttachment: MediaSources.Key? {
        didSet {
            guard liftedAttachment != oldValue else { return }
            if let oldValue { invalidateMessage(oldValue.messageID) }
            if let liftedAttachment { invalidateMessage(liftedAttachment.messageID) }
        }
    }
    /// An application id → the colour its invitation card is ruled with.
    ///
    /// Pushed in rather than read from the store: the painter is `nonisolated`
    /// so a render test can drive it, and a draw loop must not reach for a
    /// main-actor singleton.
    private var activityAccents: [ApplicationID: (primary: CGColor, secondary: CGColor)] = [:]
    /// What `activityAccents` was built from, kept so the comparison above can
    /// be an equality rather than a count.
    private var packedActivityAccents: [ApplicationID: ActivityCardTint] = [:]
    /// The live line each invitation draws, by application, and whether the
    /// reader is in it. Pushed in and redrawn — never laid out. See
    /// `ActivityInviteSlot.statusOrigin`.
    private var activityInviteStatuses: [ApplicationID: ActivityInviteStatus] = [:]
    /// The listen-along cards' hosts, by party — painted, see
    /// `ListenAlongCard`.
    private var listenAlongCards: [String: ListenAlongCard] = [:]
    /// Repaints the live cards each second, while there are any: their clock
    /// is read at paint time, and a clock read is not a subscription.
    private var listenAlongClock: Task<Void, Never>?
    /// How far each of the reader's uploads has got, by its echo's id — see
    /// `apply(uploadProgress:)`.
    private var uploadProgress: [MessageID: Double] = [:]
    /// Suppressed while a scroll is running. `.onContinuousHover`-shaped work is
    /// worst exactly during a scroll: a trackpad flick moves no pointer at all
    /// yet drags every row in the list underneath a stationary one, so the
    /// canvas would compute hover for rows nobody is pointing at during the one
    /// stretch with least to spare.
    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue else { return }
            if isScrolling { clearTooltips() }
            if isScrolling, hoveredRow != nil {
                let previous = hoveredRow
                hoveredRow = nil
                hoveredComponent = nil
                hoveredPlate = nil
                hoveredSpoiler = nil
                hoveredLink = nil
                isAuthorNameHovered = false
                styledName = nil
                invalidateRow(previous)
                publishHover()
                updateAvatarPlayback()
            } else if !isScrolling {
                updateHover(at: currentPointerLocation())
            }
        }
    }

    // MARK: Callbacks
    //
    // Weakly held by construction: the coordinator owns this view, so a strong
    // closure back to the coordinator is a cycle. Every one of these is assigned
    // with `[weak coordinator]` at the call site.

    var onWidthChange: ((CGFloat) -> Void)?
    var onDocumentHeightChange: ((CGFloat) -> Void)?
    var onOpenLink: ((MessageText.LinkTarget, CGRect) -> Void)?
    /// A video's Play: the message, the player, and the thumbnail's rect in
    /// this canvas, which the player is laid over.
    var onPlayVideo: ((MessageID, EmbedVideo, CGRect) -> Void)?
    var onVisibleRangeChange: ((Range<Int>) -> Void)?
    var onActivateMessage: ((MessageID) -> Void)?
    /// A face or a name was clicked. The rect is in this view's own space; the
    /// coordinator converts it for the popover.
    var onOpenProfile: ((UserID, CGRect) -> Void)?
    var onOpenEmoji: ((EmojiRef, CGRect) -> Void)?
    var onOpenSticker: ((StickerRef, CGRect) -> Void)?
    /// A picture, a GIF or a video in a message was clicked.
    ///
    /// The widths travel with it because the viewer opens on the rendition the
    /// transcript already decoded, and that cache entry is keyed by the size it
    /// was drawn at — a peek built from any other number looks in a slot nothing
    /// was ever put in.
    /// A picture clicked: the message, its place, and each attachment's drawn
    /// width and URL — the thumbnail the viewer opens on, peeked by the exact
    /// key the transcript cached it under.
    var onOpenAttachment: ((MessageID, Int, [CGFloat], [URL?]) -> Void)?
    /// An embed's pictures, and which of them was clicked.
    var onOpenEmbedPictures: ((MessageID, [EmbedPicture], Int) -> Void)?
    /// A spoilered attachment was uncovered — its picture is wanted now.
    var onRevealAttachment: (() -> Void)?

    /// The spoilered attachments uncovered in a message, for the fetch.
    func revealedAttachmentIndexes(of messageID: MessageID) -> Set<Int> {
        revealedAttachments[messageID] ?? []
    }
    /// The same among a forward's own files.
    func revealedForwardAttachmentIndexes(of messageID: MessageID) -> Set<Int> {
        revealedForwardAttachments[messageID] ?? []
    }
    /// A forward's picture clicked: the message, its place among the forward's
    /// files, and each one's drawn width and URL, as `onOpenAttachment`.
    var onOpenForwardedAttachment: ((MessageID, Int, [CGFloat], [URL?]) -> Void)?
    /// A forward's breadcrumb clicked: the original.
    var onJumpToForwarded: ((ForwardJump) -> Void)?
    /// A file card's Download, by message and attachment.
    var onDownloadAttachment: ((MessageID, Int) -> Void)?
    /// Stars or un-stars a GIF in the transcript.
    var onToggleFavoriteGIF: ((GIF) -> Void)?
    /// Starts or stops a music card's thirty-second clip.
    var onTogglePreview: ((URL) -> Void)?
    /// A voice note's disc: plays it, or pauses it.
    var onToggleVoiceNote: ((VoiceNoteSlot) -> Void)?
    /// A press on a note's bars, and each move of the drag after it.
    var onScrubVoiceNote: ((VoiceNoteSlot, Double, VoiceNoteScrub) -> Void)?
    /// A note's speed pill, which is every note's speed.
    var onCycleVoiceRate: (() -> Void)?
    /// Where the notes stand, asked at paint time, since it moves every frame.
    var voicePlayback: (() -> VoiceNotePlayback)?
    /// The note being dragged across, and where its row starts.
    private var voiceScrub: (voice: VoiceNoteSlot, rowX: CGFloat)?
    /// Repaints the playing note, and nothing else, while it plays.
    private var voiceLink: CADisplayLink?
    /// The message whose reaction picker is open — `apply(pinnedReactionMessage:)`.
    private var pinnedReactionMessage: MessageID?
    /// Counts rolling on a layer over their chips — see `ReactionCountRolls`.
    private let countRolls = ReactionCountRolls()
    /// Chips that are popping, and when each started.
    private var reactionPops: [ReactionChipKey: CFTimeInterval] = [:]
    /// Repaints the popping chips and a moving fold, and nothing else, while
    /// either moves.
    private var popLink: CADisplayLink?
    /// A fold opening or shutting: its rows by their place down it, when it
    /// began, and which way — see `FoldReveal`.
    private var foldMotion: (order: [MessageID: Int], start: CFTimeInterval, closing: Bool)?
    /// A fold the reader has just pressed Show on, until its rows arrive.
    private var pendingFoldOpen: (ids: [MessageID], until: CFTimeInterval)?
    /// The shut that follows a fold's rows leaving.
    private var foldClose: Task<Void, Never>?
    private var voiceRevision: UInt64 = 0
    private var isVoiceLive = false

    /// Something changed about the notes: redraw them, and keep the clock going for as
    /// long as a bar could be moving.
    func apply(voiceRevision revision: UInt64, isLive: Bool) {
        if voiceRevision != revision {
            voiceRevision = revision
            invalidateVoiceRows()
        }
        isVoiceLive = isLive
        reconcileVoiceLink()
    }

    /// A link holds its target, so one left running keeps a canvas that's left its window.
    private func reconcileVoiceLink() {
        if isVoiceLive, window != nil {
            guard voiceLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(stepVoiceNote))
            // Thirty is enough for bars this size, and sixty is all they could use.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            voiceLink = link
        } else if let link = voiceLink {
            link.invalidate()
            voiceLink = nil
        }
    }

    /// Whether this transcript has a note on it, laid out, in sight or not.
    func holdsVoiceNote(_ id: AttachmentID) -> Bool {
        rows.contains { row in
            guard case .message(let message) = row.kind else { return false }
            return message.attachments.contains { $0.voice?.attachmentID == id }
        }
    }

    /// Only the row with the note on it, and only while it's in sight.
    @objc private func stepVoiceNote(_ link: CADisplayLink) {
        guard let current = voicePlayback?().current else { return }
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            for slot in row.attachments where slot.voice?.attachmentID == current {
                let frame = rowFrame(at: index)
                setNeedsDisplay(slot.rect.offsetBy(dx: frame.minX, dy: frame.minY))
            }
        }
    }

    private func invalidateVoiceRows() {
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind,
                  row.attachments.contains(where: { $0.voice != nil })
            else { continue }
            invalidateRow(index)
        }
    }
    /// Raises Spotify's own player beside the card, with the card's rect.
    var onOpenMusicPlayer: ((SpotifyUnfurl, CGRect) -> Void)?
    /// Which clip is playing, so the chip that started it can offer to stop it.
    ///
    /// **Applied like the activity accents, not read from a store**: this view
    /// is a drawn `NSView` and holds no model reference, so anything that has to
    /// reach it is handed to it.
    private var playingPreview: URL?

    func apply(playingPreview url: URL?) {
        guard playingPreview != url else { return }
        playingPreview = url
        needsDisplay = true
    }
    /// Whether the account already keeps this one, asked at paint time.
    ///
    /// **A closure, not a set copied into the canvas.** The favourites live on
    /// the store and change from three places — the picker, this badge, another
    /// client — and a snapshot handed to the canvas is a snapshot that goes
    /// stale. It is called once per hovered attachment per repaint, which is at
    /// most one.
    var isFavoriteGIF: ((GIF) -> Bool)?
    /// The Play button on an activity invitation was pressed.
    var onPlayActivity: ((MessageID) -> Void)?
    /// A listen-along card's Join.
    var onListenAlong: ((MessageID) -> Void)?
    /// An invite card's button was pressed.
    var onInviteButton: ((InviteCard) -> Void)?
    /// A voice invite card's "Server / channel" line.
    var onOpenInviteChannel: ((ChannelID) -> Void)?
    /// A profile card was opened past its fold, or folded again.
    var onToggleInviteFold: ((InviteCardFold) -> Void)?
    /// A profile invite card's "+ N more" chip: the traits it stands for, and
    /// its rect in the hosting root's space.
    var onShowTraits: (([GuildTrait], CGRect) -> Void)?
    /// Whether the reader is already where an invite leads — Join or Go to
    /// Server, Add Friend or Send a Message — decided at paint time so joining
    /// is a repaint, not a relayout.
    var isInviteSettled: ((InviteCard) -> Bool)?
    /// A shared theme card's two states — being previewed, and kept.
    var isThemePreviewing: ((SharedClientTheme) -> Bool)?
    var isThemeSaved: ((SharedClientTheme) -> Bool)?
    /// A shared theme card's Preview and Save.
    var onPreviewSharedTheme: ((SharedClientTheme) -> Void)?
    var onSaveSharedTheme: ((SharedClientTheme, String) -> Void)?
    /// A poll answer was chosen.
    var onVote: ((MessageID, Int) -> Void)?
    /// A button an application attached, pressed. Carries the message it sits on
    /// and the `custom_id` the interaction has to echo — the canvas knows both
    /// and the store knows neither.
    var onPressComponent: ((MessageID, String) -> Void)?
    /// A select menu clicked, with its rect in this view — the list of its
    /// options hangs off it.
    var onOpenSelect: ((MessageID, String, CGRect) -> Void)?
    /// "Dismiss message" on an ephemeral row. A real removal: the message exists
    /// only in this session, so taking it out of the store destroys the only
    /// copy the reader can reach.
    var onDismissEphemeral: ((MessageID) -> Void)?
    /// The cancel on one of the reader's uploads, by its echo's id.
    var onCancelUpload: ((MessageID) -> Void)?
    /// A reaction chip was clicked. The reader's own reaction of that chip's
    /// kind is toggled.
    var onToggleReaction: ((MessageID, EmojiRef, ReactionKind) -> Void)?
    /// The add-a-reaction control at the end of the reaction row was clicked.
    /// The rect is in the hosting root's space, so the picker opens beside the
    /// control rather than at the window's corner.
    var onAddReaction: ((MessageID, CGRect) -> Void)?
    /// The bookmark control beside it was clicked: keep the message, or let it
    /// go.
    var onToggleBookmark: ((MessageID) -> Void)?
    /// A refused send's red disc was clicked: send it again.
    var onResend: ((MessageID) -> Void)?
    /// A reply's quoted line was clicked: go to what it quotes.
    var onOpenReplyTarget: ((MessageID) -> Void)?
    /// The chip on a "used" line was pressed, with its rect in the hosting
    /// root's space: `AppModel.pressCommandChip` says what that does.
    var onOpenCommand: ((MessageID, CGRect) -> Void)?
    /// The open topic's marker was clicked: bring its panel back.
    var onOpenTopicMarker: (() -> Void)?
    /// The welcome header's Edit Channel button.
    var onEditChannel: (() -> Void)?
    /// A fold's Show or Hide: open the fold, or shut it again.
    var onToggleCollapsedGroup: ((CollapsedGroup) -> Void)?
    /// A button on a forum post's bar, with its rect in the SwiftUI root's
    /// space for the reaction picker to hang off.
    var onPostAction: ((PostActionsSlot.Action, CGRect) -> Void)?
    /// A crosspost's author was clicked: the server that published it, not a
    /// person — Discord's server card, or its Community Updates card.
    var onOpenCrosspostAuthor: ((MessageID, CGRect) -> Void)?
    /// A press on the server tag beside a name: whose tag, and the chip's rect.
    var onOpenServerTag: ((UserID, CGRect) -> Void)?
    /// A control in a direct message's head — Add Friend, Block, the servers
    /// in common — with its rect in the SwiftUI root's space.
    var onHeadAction: ((HeadAction, CGRect) -> Void)?
    /// The thread chip under a message was clicked: open that thread.
    var onOpenThread: ((ChannelID) -> Void)?
    /// The pointer moved onto, or off, a message row. Its rect is in the CLIP
    /// VIEW's space, because what reads it is a floating pill overlaid on the
    /// scroll view rather than anything in document coordinates.
    var onHoverMessage: ((MessageHover?) -> Void)?
    /// The full menu was asked for — a right-click, or the pill's own button.
    var onOpenMenu: ((MessageID, CGRect) -> Void)?
    /// A right-click on a name or a face: the person menu, at that rect.
    var onOpenPersonMenu: ((UserID, CGRect) -> Void)?
    /// The pointer moved onto, or off, a reaction chip. The chip's frame is in
    /// the CLIP VIEW's space, for the reason `onHoverMessage`'s is: what reads
    /// it is the tooltip overlaid on the scroll view.
    var onHoverReaction: ((ReactionHover?) -> Void)?
    /// The chip last published through `onHoverReaction`.
    private var hoveredReaction: ReactionHover?
    /// The pointer moved onto, or off, a server's mark on an invite card —
    /// Discord's flyout for it. The mark's frame is in the CLIP VIEW's space,
    /// for the reason `onHoverReaction`'s is.
    var onHoverMark: ((GuildMarkHover?) -> Void)?
    /// The mark last published through `onHoverMark`.
    private var hoveredMark: GuildMarkHover?
    /// A control on a drawn card — AutoMod's, a safety notice's — with the
    /// message it is on and its rect in the SwiftUI root's space.
    var onCardAction: ((MessageID, DrawnCardAction, CGRect) -> Void)?
    /// The pointer moved onto, or off, the mark of something a moderator did
    /// on an AutoMod alert. Its frame is in the CLIP VIEW's space, for the
    /// reason `onHoverReaction`'s is.
    var onHoverAutoModAction: ((AutoModActionHover?) -> Void)?
    /// The mark last published through `onHoverAutoModAction`.
    private var hoveredAutoModAction: AutoModActionHover?
    /// The pointer moved onto, or off, the "(edited)" after a message's
    /// words — Discord's tooltip saying when. Its frame is in the CLIP VIEW's
    /// space, for the reason `onHoverReaction`'s is.
    var onHoverEditedMark: ((EditedMarkHover?) -> Void)?
    /// The marker last published through `onHoverEditedMark`.
    private var hoveredEditedMark: EditedMarkHover?

    private var trackingArea: NSTrackingArea?
    /// See `apply(isCovered:)`.
    private var isCovered = false
    /// See `apply(bookmarks:)`.
    private var bookmarkedMessageIDs: Set<MessageID> = []

    // MARK: Super reactions

    /// The channel these rows belong to. An effect is chosen by hashing it with
    /// the message and the emoji, so the canvas has to know it; see
    /// `apply(channelID:)`.
    private var channelID: ChannelID?
    /// Whether the reader may add or take back a super reaction — Nitro.
    ///
    /// **A super reaction chip is still a hover target without it**: its effect
    /// plays under the pointer for everybody, as it does in Discord. What goes
    /// is the control — no hand, no lift, and a click that does nothing,
    /// because a chip that looks pressable and cannot be pressed is the inert
    /// control `INVARIANTS.md` §5.5 forbids.
    private var canSuperReact = false
    /// Whether a new reaction may be started here — `apply(canAddReactions:)`.
    private var canAddReactions = false
    /// Whether the pointer is on the hovered row's reactions, which shows its
    /// bookmark control. Part of the hover, so it is cleared with it.
    private var isPointerOnReactions = false
    /// The effects playing over this transcript's super reactions.
    private lazy var burstEffects = SuperReactionEffects(host: self)
    /// The super reaction chip under the pointer, so entering one plays its
    /// effect once rather than on every move across it.
    private var hoveredBurst: SuperReactionEffects.Key?
    /// Chips that have already played their ambient effect in this channel —
    /// Discord's per-chip latch: each one plays at most once by itself.
    private var ambientPlayed: Set<SuperReactionEffects.Key> = []
    /// The chips that were shaking on the last tick, so the tick after a shake
    /// ends repaints them at rest.
    private var shakingChips: Set<SuperReactionEffects.Key> = []
    /// The five-second ambient roll. Scheduled only while a super reaction
    /// chip is within the canvas; see `refreshAmbient`.
    private var ambientTimer: Timer?
    /// Super reactions announced before their chip was laid out.
    ///
    /// **A first super reaction on an emoji is announced before the row that
    /// shows it exists**: the store changes at once and the transcript lays
    /// itself out a moment later, off the main actor. Discord's store keeps an
    /// effect until the chip that plays it mounts; this keeps one for a
    /// moment, and plays it when the rows land.
    private var pendingArrivals: [(messageID: MessageID, emoji: EmojiRef, until: CFTimeInterval)] = []

    // MARK: Moving pictures
    //
    // **Stickers, GIFs and animated emoji play on layers over this canvas** —
    // see `TranscriptFilms`, which says why the canvas stopped drawing their
    // frames. What is left on the clock here is what only the painter can draw:
    // the hovered row's moving face, a styled name, a shaking chip.

    /// Names one moving picture in the transcript.
    ///
    /// **The message plus its position, never the asset's own id.** The same GIF
    /// posted twice is two boxes on screen, and a key on the URL would let the
    /// first one's repaint mark the second as up to date — so the second would
    /// sit on whichever frame it happened to land on.
    struct FilmSlot: Hashable {
        enum Kind: UInt8 { case sticker, attachment, embed, emoji, reaction }
        var messageID: MessageID
        var kind: Kind
        var index: Int
    }

    /// The layers the moving pictures play on.
    let films = TranscriptFilms()
    /// The bubbles' faces, which ride the scroll. See `StickyFaces`.
    let stickyFaces: StickyFaces
    /// Where the pointer last was, in the document: which face, if any, it is on.
    private var pointer: CGPoint?
    /// The run whose face the pointer is on, so moving onto one within a row
    /// starts its film as moving onto its row does.
    private var pointerFace: MessageID?
    private var isAnimatingStickers = false
    /// The rate the clock was last asked for. See `clockRate`.
    private var subscribedRate: Double = 0
    private var animationToken: ObjectIdentifier { ObjectIdentifier(self) }

    init(style: MessageTextStyle) {
        self.style = style
        stickyFaces = StickyFaces(style: style)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        layer?.drawsAsynchronously = false
        // Under any subview's layer, over this view's own drawing.
        layer?.insertSublayer(films.container, at: 0)
        layer?.insertSublayer(stickyFaces.container, above: films.container)
        stickyFaces.filmFrames = { [weak self] id in
            (self?.avatarFilm.avatarFrame(forRow: id.rawValue), self?.avatarFilm.decorationFrame(forRow: id.rawValue))
        }
        postsFrameChangedNotifications = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Message transcript")
        adoptAvatarFilm()
        adoptBurstEffects()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    /// Transparent: the reading surface is painted by SwiftUI behind this, so
    /// the canvas only draws what it has.
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Rows

    /// The invitation colours, when they change.
    ///
    /// **Its own entry point, and it only redraws.** The colour is quantised
    /// from an app's icon asynchronously and arrives after the row is laid out
    /// and cached — pushing it through `apply(rows:)` would re-lay-out the whole
    /// transcript for something that changes no geometry at all.
    /// The invitation lines, when presence moves.
    ///
    /// **A redraw, not a re-layout.** The status turns on presence — the most
    /// frequent event in the app — and the card's height does not depend on it,
    /// so re-measuring the transcript for it would be the most expensive way to
    /// change two words. Without this the line was frozen until the reader
    /// switched channels, which is what made it look broken.
    /// The messages the reader has kept.
    ///
    /// **An input, and a redraw rather than a relayout.** §4.5: the bookmark
    /// changes a glyph and nothing about the row's geometry, so it belongs on
    /// the paint path — a flag taken at layout time would freeze the moment the
    /// row was measured. Only the visible rect is invalidated, which is where
    /// the control that changed can be.
    func apply(bookmarks: Set<MessageID>) {
        guard bookmarks != bookmarkedMessageIDs else { return }
        bookmarkedMessageIDs = bookmarks
        setNeedsDisplay(visibleRect)
    }

    func apply(activityInviteStatuses statuses: [ApplicationID: ActivityInviteStatus]) {
        guard statuses != activityInviteStatuses else { return }
        activityInviteStatuses = statuses
        setNeedsDisplay(visibleRect)
    }

    /// The listen-along cards' painted state. Their pictures come from
    /// presence, not from a laid-out slot, so they are asked for here — the
    /// row's image pass cannot see them — and the canvas repaints once they
    /// land.
    func apply(listenAlongCards cards: [String: ListenAlongCard]) {
        guard cards != listenAlongCards else { return }
        listenAlongCards = cards
        setNeedsDisplay(visibleRect)
        let scale = window?.backingScaleFactor ?? 2
        var keys: [ImageStore.Key] = []
        for card in cards.values {
            if let url = card.artworkURL {
                keys.append(ImageStore.Key(url: url, maximumPixelSize: Int(ListenAlongLayoutEngine.artSide * scale)))
            }
            for url in card.faces.compactMap({ $0 }) {
                keys.append(ImageStore.Key(url: url, maximumPixelSize: Int(ListenAlongLayoutEngine.faceSide * scale)))
            }
        }
        let missing = keys.filter { ImageStore.shared.cached($0, bucket: .thumbnail) == nil }
        if !missing.isEmpty {
            Task { [weak self] in
                for key in missing { _ = await ImageStore.shared.image(for: key, bucket: .thumbnail) }
                guard let self else { return }
                self.setNeedsDisplay(self.visibleRect)
            }
        }
        // A live card's clock moves every second; nothing else on the row does.
        if cards.isEmpty {
            listenAlongClock?.cancel()
            listenAlongClock = nil
        } else if listenAlongClock == nil {
            listenAlongClock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.repaintLiveListenAlongCards()
                }
            }
        }
    }

    private func repaintLiveListenAlongCards() {
        let visible = visibleRect
        for (index, row) in rows.enumerated() {
            guard case .message(let message) = row.kind, let card = message.listenAlong, card.isLive else { continue }
            let frame = rowFrame(at: index)
            guard frame.intersects(visible) else { continue }
            setNeedsDisplay(card.rect.offsetBy(dx: frame.minX, dy: frame.minY))
        }
    }

    /// An upload's bar, which moves a hundred times an upload and changes no
    /// row — so it is paint state, and only the rows it moved repaint.
    func apply(uploadProgress progress: [MessageID: Double]) {
        guard progress != uploadProgress else { return }
        let moved = Set(progress.keys).union(uploadProgress.keys)
            .filter { progress[$0] != uploadProgress[$0] }
        uploadProgress = progress
        for id in moved {
            guard let index = rows.firstIndex(where: { $0.messageID == id }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func apply(activityAccents accents: [ApplicationID: ActivityCardTint]) {
        // Compared as packed values, which are `Equatable`; a `CGColor`
        // dictionary is not, and this runs on every update.
        guard accents != packedActivityAccents else { return }
        packedActivityAccents = accents
        activityAccents = accents.mapValues {
            (InviteCardColours.cgColor($0.primary), InviteCardColours.cgColor($0.secondary))
        }
        // A card's colours and its cover are paint state: the rows that carry
        // one are redrawn, and nothing is measured again.
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind, row.activityInvite != nil else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    /// Installs a new row list and recomputes the offset table.
    ///
    /// Returns the content height so the coordinator can resize the document in
    /// the same pass, rather than through a callback that would land a frame
    /// later and leave the scroller briefly wrong.
    @discardableResult
    func apply(rows: [TimelineRow], leadingSpace: CGFloat = 0) -> CGFloat {
        // What the chips in sight said before the rows moved, so the ones that
        // changed can show it — see `animateReactionChanges`.
        let countsBefore = visibleReactionCounts()
        countRolls.removeAll()
        self.rows = rows
        offsets.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(rows.count + 1)
        var running: CGFloat = leadingSpace
        offsets.append(leadingSpace)
        for row in rows {
            running += row.height
            offsets.append(running)
        }
        // Clear any hover that referred to a row index that no longer exists.
        if let hoveredRow, hoveredRow >= rows.count { self.hoveredRow = nil }
        messageRows.removeAll(keepingCapacity: true)
        for (index, row) in rows.enumerated() {
            if let id = row.messageID { messageRows[id] = index }
        }
        stickyFaces.update(runs: StickyFaceRun.runs(in: rows, offsets: offsets))
        placeStickyFaces()
        // A selection whose message is gone has nothing left to point at.
        if let selection, messageRows[selection.anchor.messageID] == nil
            || messageRows[selection.focus.messageID] == nil
        {
            self.selection = nil
            isSelecting = false
        }
        // An index survives a rows change; the message at it may not. Republish
        // so the pill cannot end up offering another message's actions.
        if hoveredRow != nil { publishHover() }
        // The row under the pointer may now be a different message — an edit,
        // a new message arriving, a channel switch — so the face playing on it
        // has to be re-asked rather than left on the person who was there.
        updateAvatarPlayback()
        // A playing effect follows its chip when the rows move under it, and
        // ends when its chip is gone; one announced before its chip existed
        // plays now that it does.
        burstEffects.follow()
        playPendingArrivals()
        refreshAmbient()
        animateReactionChanges(from: countsBefore)
        followFold()
        needsDisplay = true
        refreshStickerAnimation()
        reconcileFilms()
        return running
    }

    /// Puts the bubbles' faces where the viewport wants them: on each run's
    /// last bubble, or riding the bottom above the composer. Called from every
    /// scroll step (`TimelineView.viewportDidChange`) and whenever the rows
    /// change. Nothing to do in columns, which have no runs here.
    func placeStickyFaces() {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.contentView.bounds
        stickyFaces.place(
            visible: visible,
            readableBottom: visible.maxY - scrollView.contentInsets.bottom - StickyFaces.composerGap,
            scale: window?.backingScaleFactor ?? 2
        )
    }

    /// Subscribes to the clock while something the painter draws is moving,
    /// and stops the moment nothing is.
    ///
    /// Called from every place the answer can change. Idempotent, so they can
    /// call it freely.
    func refreshStickerAnimation() {
        let wanted = window != nil && hasVisibleFilm
        let rate = wanted ? clockRate : 0
        guard wanted != isAnimatingStickers || rate != subscribedRate else { return }
        isAnimatingStickers = wanted
        subscribedRate = rate
        if wanted {
            AnimationClock.shared.subscribe(animationToken, rate: rate) { [weak self] in
                self?.advanceFilm()
            }
        } else {
            AnimationClock.shared.unsubscribe(animationToken)
        }
    }

    /// How often the painter's moving things need a look: the hovered face's
    /// own frame rate, and sixty for a name or a chip that moves continuously —
    /// Discord animates both as CSS, at the display's rate.
    private var clockRate: Double {
        let continuous = hoveredNameEffectAnimates || nameGradientPhase != nil
            || burstEffects.isShaking(at: AnimationClock.shared.time) || !shakingChips.isEmpty
        return continuous ? 60 : (avatarFilm.isPlaying ? avatarFilm.rate : AnimationClock.defaultRate)
    }

    /// Releases the clock subscription and every picture's layer. Idempotent.
    func stopStickerAnimation() {
        avatarFilm.cancel()
        films.removeAll()
        guard isAnimatingStickers else { return }
        isAnimatingStickers = false
        AnimationClock.shared.unsubscribe(animationToken)
    }

    private var hasVisibleFilm: Bool {
        if avatarFilm.isPlaying { return true }
        // Five and six. Neither is a filmstrip — nothing swaps a bitmap for
        // them — but both are the same question: something on screen is moving,
        // so this view needs a tick. A run head shows one or the other and
        // never both: a server suppresses the account's own name colours and
        // lends its role's instead.
        if hoveredNameEffectAnimates { return true }
        if nameGradientPhase != nil { return true }
        // A super reaction chip shaking. Not a filmstrip either, and for half
        // a second at a time.
        return burstEffects.isShaking(at: AnimationClock.shared.time) || !shakingChips.isEmpty
    }

    /// Repaints just the hovered name, effect bleed included.
    ///
    /// Nothing at all when the name is not moving, which is the common case —
    /// an unstyled row under the pointer must not cost a rect per tick.
    private func invalidateHoveredName(force: Bool = false) {
        guard force || hoveredNameEffectAnimates,
              let index = hoveredRow, rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else { return }
        let frame = rowFrame(at: index)
        // A travelling role gradient paints strictly inside the glyphs and has
        // no prepared run behind it — only a name effect does.
        guard let prepared = styledName?.prepared else {
            setNeedsDisplay(
                CGRect(
                    x: frame.minX + row.authorRect.minX,
                    y: frame.minY + row.authorRect.minY,
                    width: row.authorRect.width + 8,
                    height: row.authorRect.height
                )
                // The glow `drawText` casts for a travelling ramp is a 4-point
                // blur, so the box it is repainted in has to hold it.
                .insetBy(dx: -6, dy: -6)
            )
            return
        }
        // The width is the prepared run's rather than the layout's: a truncated
        // name is narrower than the box reserved for it, and a lit name that
        // is wider than its box cannot exist — `maximumWidth` saw to that.
        let box = CGRect(
            x: frame.minX + row.authorRect.minX,
            y: frame.minY + row.authorRect.minY,
            width: min(row.authorRect.width + 8, prepared.run.size.width),
            height: prepared.run.size.height
        )
        setNeedsDisplay(box.insetBy(dx: -prepared.bleed - 1, dy: -prepared.bleed - 1))
    }

    /// Whether a styled name may move at all.
    ///
    /// **Reduce Motion only, not `playsAnimatedContent`.** That setting's own
    /// label names emoji and avatars, and a name effect is neither — it is how
    /// somebody chose to be written. `StyledDisplayName` draws the profile's
    /// copy on the same rule, and two surfaces disagreeing about one person's
    /// name in one window is the thing to avoid.
    private var playsNameEffects: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Where the hovered author's role gradient has travelled to, `0..<1`, or
    /// nil when nothing is travelling.
    ///
    /// **The member list's own arithmetic, to the constant.** `MemberListCanvas`
    /// runs the same ramp on a 1.5-second cycle so a short name and a long one
    /// come round together, and the two surfaces drawing one person's name at
    /// different speeds is exactly what this feature exists to avoid.
    private var nameGradientPhase: CGFloat? {
        guard !isScrolling, let hoveredRow, rows.indices.contains(hoveredRow),
              case .message(let row) = rows[hoveredRow].kind,
              row.hasAuthorLine, (row.authorGradient?.count ?? 0) >= 2
        else { return nil }
        let cycle = AnimationClock.shared.time / Self.nameGradientCycle
        return CGFloat(cycle - cycle.rounded(.down))
    }

    /// Matches `MemberListCanvas.gradientCycle`.
    private static let nameGradientCycle = 1.5

    /// Whether the hovered row is a run head whose owner chose a moving name
    /// effect.
    ///
    /// **Only the hovered row**, which is the rule the member list's
    /// `gradientPhase` already states and for the same reason: four hundred
    /// messages in a channel carry dozens of styled names, and running all of
    /// them is a page of moving text where a conversation should be — every one
    /// of them a row-sized invalidation per frame.
    ///
    /// Reduce Motion stops the movement and **not the effect**: the still
    /// picture is each effect's own first keyframe, which is the design rather
    /// than a frozen frame of it. That is `StyledDisplayName`'s rule, restated
    /// here because a canvas has no SwiftUI environment to read `\.motion` from.
    private var hoveredNameEffectAnimates: Bool {
        guard !isScrolling, playsNameEffects,
              let hoveredRow, rows.indices.contains(hoveredRow),
              case .message(let row) = rows[hoveredRow].kind,
              let style = row.hasAuthorLine ? row.authorStyle : row.systemName?.style
        else { return false }
        return DisplayNameEffectPainter.animates(style)
    }

    /// One clock tick: repaint only what the painter draws that moved.
    private func advanceFilm() {
        let time = AnimationClock.shared.time

        // Nothing happens on the ticks that resolve to the frame already on
        // screen, which at 24 ticks over a 12-frame-a-second asset is half.
        if avatarFilm.advance(to: time) { invalidateRow(hoveredRow) }

        // The hovered author's travelling role gradient, which the member
        // list runs on the same clock and the same cycle.
        if nameGradientPhase != nil { invalidateHoveredName(force: true) }

        // A name effect has no frames to skip — it is continuous, so every tick
        // is a new picture. **Its own box, not the row**: a message carrying a
        // photograph is four hundred points tall and the name is twenty, and
        // repainting the picture sixty times a second to move a rainbow across
        // fourteen letters is the cost this whole per-box arrangement exists to
        // avoid.
        invalidateHoveredName()

        // Shaking chips, and the ones that stopped shaking since the last
        // tick — a shake that ends between ticks would otherwise leave its chip
        // drawn a point off and a degree askew until something else repainted
        // it.
        let shaking = Set(burstEffects.shaking(at: time))
        for key in shaking.union(shakingChips) { invalidateBurstChip(key) }
        if shaking != shakingChips {
            shakingChips = shaking
            if shaking.isEmpty { refreshStickerAnimation() }
        }
    }

    /// Brings the layers over the canvas in line with the moving pictures near
    /// the viewport — the rows on screen and half a screen either side, so a
    /// picture is playing before it scrolls in. See `TranscriptFilms`.
    func reconcileFilms() {
        let scale = window?.backingScaleFactor ?? 2
        guard window != nil else {
            films.removeAll()
            return
        }
        let reach = bounds.insetBy(dx: 0, dy: -bounds.height / 2)
        var requests: [TranscriptFilms.Request] = []
        if var index = rowIndex(at: max(0, reach.minY)) {
            let playsEmoji = AnimationClock.playsAnimatedEmoji
            while index < rows.count, offsets[index] < reach.maxY {
                if case .message(let row) = rows[index].kind {
                    appendFilms(
                        of: row, at: rowFrame(at: index).origin, scale: scale,
                        playsEmoji: playsEmoji, into: &requests
                    )
                }
                index += 1
            }
        }
        films.reconcile(requests, scale: scale)
        films.setBadge(filmBadge(), scale: scale)
    }

    /// The moving pictures in one message, by the painter's own rules for
    /// what it would have shown moving.
    ///
    /// **What a spoiler covers gets no layer**: a layer sits over the canvas's
    /// drawing, and one over a concealed picture would show it through its
    /// plate. Nor does the emoji a super reaction has borrowed for its effect,
    /// or a chip that is shaking — the painter moves those.
    private func appendFilms(
        of row: MessageRow,
        at origin: CGPoint,
        scale: CGFloat,
        playsEmoji: Bool,
        into requests: inout [TranscriptFilms.Request]
    ) {
        func key(_ url: URL, side: CGFloat) -> FilmPlayer.Key {
            FilmPlayer.Key(url: url, maximumPixelSize: Int((side * scale).rounded(.up)))
        }
        for (offset, slot) in row.stickers.enumerated() where slot.isAnimated {
            guard let url = slot.url else { continue }
            requests.append(.init(
                slot: FilmSlot(messageID: row.id, kind: .sticker, index: offset),
                source: slot.isVector
                    ? .vector(url)
                    : .film(key(url, side: max(slot.rect.width, slot.rect.height))),
                frame: slot.rect.offsetBy(dx: origin.x, dy: origin.y)
            ))
        }
        let loadsArtwork = AppSettings.shared.loadsImagesAutomatically
        let revealed = revealedAttachments[row.id] ?? []
        for (offset, slot) in row.attachments.enumerated() where slot.isAnimated && loadsArtwork {
            guard let url = slot.url, !slot.isSpoiler || revealed.contains(offset) else { continue }
            requests.append(.init(
                slot: FilmSlot(messageID: row.id, kind: .attachment, index: offset),
                source: .film(key(url, side: max(slot.decodeWidth, slot.rect.width, slot.rect.height))),
                frame: slot.rect.offsetBy(dx: origin.x, dy: origin.y),
                gravity: slot.cropsToFill ? .resizeAspectFill : .resize,
                cornerRadius: 8,
                placeholder: ThemeInk.current.surfaceRaised,
                placeholderImage: PlaceholderImages.shared.image(slot.placeholder)
            ))
        }
        var embedImage = 0
        for embed in row.embeds {
            for image in embed.images {
                defer { embedImage += 1 }
                guard loadsArtwork else { continue }
                let source: TranscriptFilms.Request.Source
                if case .loop(let video) = image.video {
                    source = .video(video)
                } else if image.isAnimated, let url = image.url {
                    source = .film(key(url, side: max(image.decodeWidth, image.rect.width, image.rect.height)))
                } else {
                    continue
                }
                requests.append(.init(
                    slot: FilmSlot(messageID: row.id, kind: .embed, index: embedImage),
                    source: source,
                    frame: image.rect.offsetBy(dx: origin.x, dy: origin.y),
                    gravity: image.cropsToFill ? .resizeAspectFill : .resize,
                    cornerRadius: image.isCircle ? image.rect.width / 2 : image.corner,
                    placeholder: ThemeInk.current.placeholderFill,
                    placeholderImage: PlaceholderImages.shared.image(image.placeholder)
                ))
            }
        }
        // **A forward's moving pictures, on layers like the message's own.**
        // The transcript's request pass leaves every moving picture to these
        // layers (`filmsOnLayers`), so a forwarded GIF, sticker or looping
        // card that no layer was asked for had no picture at all. Numbered
        // past the message's own (`MediaSources.forwardedIndexBase`) so the
        // two never share a slot.
        if let forward = row.forwarded {
            let base = MediaSources.forwardedIndexBase
            for (offset, slot) in forward.stickers.enumerated() where slot.isAnimated {
                guard let url = slot.url else { continue }
                requests.append(.init(
                    slot: FilmSlot(messageID: row.id, kind: .sticker, index: base + offset),
                    source: slot.isVector
                        ? .vector(url)
                        : .film(key(url, side: max(slot.rect.width, slot.rect.height))),
                    frame: slot.rect.offsetBy(dx: origin.x, dy: origin.y)
                ))
            }
            let shownFiles = revealedForwardAttachments[row.id] ?? []
            for (offset, slot) in forward.attachments.enumerated() where slot.isAnimated && loadsArtwork {
                guard let url = slot.url, !slot.isSpoiler || shownFiles.contains(offset) else { continue }
                requests.append(.init(
                    slot: FilmSlot(messageID: row.id, kind: .attachment, index: base + offset),
                    source: .film(key(url, side: max(slot.decodeWidth, slot.rect.width, slot.rect.height))),
                    frame: slot.rect.offsetBy(dx: origin.x, dy: origin.y),
                    gravity: slot.cropsToFill ? .resizeAspectFill : .resize,
                    cornerRadius: 8,
                    placeholder: ThemeInk.current.surfaceRaised,
                    placeholderImage: PlaceholderImages.shared.image(slot.placeholder)
                ))
            }
            var forwardImage = 0
            for embed in forward.embeds {
                for image in embed.images {
                    defer { forwardImage += 1 }
                    guard loadsArtwork else { continue }
                    let source: TranscriptFilms.Request.Source
                    if case .loop(let video) = image.video {
                        source = .video(video)
                    } else if image.isAnimated, let url = image.url {
                        source = .film(key(url, side: max(image.decodeWidth, image.rect.width, image.rect.height)))
                    } else {
                        continue
                    }
                    requests.append(.init(
                        slot: FilmSlot(messageID: row.id, kind: .embed, index: base + forwardImage),
                        source: source,
                        frame: image.rect.offsetBy(dx: origin.x, dy: origin.y),
                        gravity: image.cropsToFill ? .resizeAspectFill : .resize,
                        cornerRadius: image.isCircle ? image.rect.width / 2 : image.corner,
                        placeholder: ThemeInk.current.placeholderFill,
                        placeholderImage: PlaceholderImages.shared.image(image.placeholder)
                    ))
                }
            }
        }
        guard playsEmoji else { return }
        // A bubble in flight carries its words, emoji and all, until it lands.
        if let block = row.textBlock, !isFlying(row.id) {
            let textOrigin = CGPoint(x: origin.x + row.textOrigin.x, y: origin.y + row.textOrigin.y)
            let shown = revealedSpoilers[row.id] ?? []
            let concealed = block.spoilerRects.filter { !shown.contains($0.spoiler) }.map(\.rect)
            for (offset, entry) in block.emojiRects.enumerated() where entry.emoji.isAnimated {
                guard let id = entry.emoji.id,
                      !concealed.contains(where: { $0.intersects(entry.rect) }),
                      let url = CDN.emoji(id: id, animated: true, side: entry.rect.width)
                else { continue }
                requests.append(.init(
                    slot: FilmSlot(messageID: row.id, kind: .emoji, index: offset),
                    source: .film(key(url, side: entry.rect.width)),
                    frame: entry.rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
                ))
            }
        }
        let bursting = burstEffects.isEmpty ? [:] : burstEffects.showing(on: row.id)
        for (offset, slot) in row.reactions.enumerated() where slot.emoji.isAnimated {
            guard let url = slot.imageURL, bursting[slot.emoji.reactionKey] == nil else { continue }
            requests.append(.init(
                slot: FilmSlot(messageID: row.id, kind: .reaction, index: offset),
                source: .film(key(url, side: TimelineMetrics.reactionGlyphSide)),
                frame: slot.glyphRect.offsetBy(dx: origin.x, dy: origin.y)
            ))
        }
    }

    /// The favourite star over the hovered GIF, when that GIF is on a layer.
    private func filmBadge() -> TranscriptFilms.Badge? {
        guard let index = hoveredRow, !isScrolling, rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else { return nil }
        let origin = rowFrame(at: index).origin
        if let attachment = hoveredAttachment, row.attachments.indices.contains(attachment),
           let gif = row.attachments[attachment].favorite
        {
            let slot = row.attachments[attachment]
            return TranscriptFilms.Badge(
                state: isFavoriteGIF?(gif) == true ? .starred : .unstarred,
                frame: slot.favoriteRect.offsetBy(dx: origin.x, dy: origin.y),
                slot: FilmSlot(messageID: row.id, kind: .attachment, index: attachment)
            )
        }
        if let embed = hoveredEmbed, row.embeds.indices.contains(embed),
           let gif = row.embeds[embed].favorite,
           let image = row.embeds[embed].images.firstIndex(where: { $0.isAnimated || $0.video?.isLoop == true })
        {
            let first = row.embeds[..<embed].reduce(0) { $0 + $1.images.count }
            return TranscriptFilms.Badge(
                state: isFavoriteGIF?(gif) == true ? .starred : .unstarred,
                frame: row.embeds[embed].favoriteRect.offsetBy(dx: origin.x, dy: origin.y),
                slot: FilmSlot(messageID: row.id, kind: .embed, index: first + image)
            )
        }
        return nil
    }

    /// The clock holds a closure over this view, so leaving the window has to
    /// release it — a canvas that outlives its window as a clock subscriber is a
    /// display link running for a transcript nobody can see.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileVoiceLink()
        refreshStickerAnimation()
        reconcileFilms()
        // A transcript hears about super reactions arriving while it is in a
        // window, and plays nothing once it has left one.
        let token = ObjectIdentifier(self)
        if window != nil {
            SuperReactionStage.shared.subscribe(token) { [weak self] messageID, emoji in
                self?.superReactionArrived(emoji, on: messageID)
            }
        } else {
            SuperReactionStage.shared.unsubscribe(token)
            burstEffects.stopAll()
        }
        refreshAmbient()
    }

    /// The row containing a document-space y, by binary search.
    func rowIndex(at y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard y >= 0 else { return 0 }
        guard y < contentHeight else { return rows.count - 1 }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func rowFrame(at index: Int) -> CGRect {
        CGRect(
            x: 0,
            y: offsets[index],
            width: bounds.width,
            height: rows[index].height
        )
    }

    /// The profile cards in `rect`, in the canvas's coordinates — what
    /// `HostedCardHosts` keeps a live card over. A binary search to the first row
    /// and a walk to the last, so the cost is the rows in view.
    func hostedCardPlacements(in rect: CGRect) -> [HostedCardPlacement] {
        guard !rows.isEmpty, var index = rowIndex(at: max(0, rect.minY)) else { return [] }
        var placements: [HostedCardPlacement] = []
        while index < rows.count, offsets[index] < rect.maxY {
            if case .message(let row) = rows[index].kind, !row.hostedCards.isEmpty {
                let origin = rowFrame(at: index).origin
                for (position, card) in row.hostedCards.enumerated() {
                    placements.append(HostedCardPlacement(
                        id: .init(message: row.id, index: position),
                        key: card.key,
                        frame: card.rect.offsetBy(dx: origin.x, dy: origin.y)
                    ))
                }
            }
            index += 1
        }
        return placements
    }

    /// Marks one row for redraw, in the canvas's own coordinates.
    ///
    /// Invalidating the whole view for a hover change repaints every visible row
    /// to change one; a rect invalidation repaints one.
    private func invalidateRow(_ index: Int?) {
        guard let index, rows.indices.contains(index) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    func invalidateMessage(_ messageID: MessageID) {
        guard let index = rows.firstIndex(where: { $0.messageID == messageID }) else { return }
        invalidateRow(index)
    }

    /// Where one of a message's pictures is drawn, in window coordinates — the
    /// box the media viewer flies it out of and back into — or nil when its row
    /// is not laid out or the box is out of sight.
    func attachmentThumbnail(_ key: MediaSources.Key) -> MediaSources.Thumbnail? {
        guard let index = rows.firstIndex(where: { $0.messageID == key.messageID }),
              case .message(let message) = rows[index].kind
        else { return nil }
        // An embed's pictures are numbered past a forward's — see
        // `MediaSources.embedIndexBase`.
        if key.attachmentIndex >= MediaSources.embedIndexBase {
            let place = key.attachmentIndex - MediaSources.embedIndexBase
            let (embedIndex, imageIndex) = (place / 100, place % 100)
            guard message.embeds.indices.contains(embedIndex),
                  message.embeds[embedIndex].images.indices.contains(imageIndex)
            else { return nil }
            let image = message.embeds[embedIndex].images[imageIndex]
            let row = rowFrame(at: index)
            let frame = image.rect.offsetBy(dx: row.minX, dy: row.minY)
            guard frame.intersects(visibleRect), window != nil else { return nil }
            return MediaSources.Thumbnail(
                frame: convert(frame, to: nil),
                cornerRadius: image.corner,
                cropsToFill: image.cropsToFill,
                window: window
            )
        }
        // A forward's own files are numbered past the message's — see
        // `MediaSources.forwardedIndexBase`.
        let isForwarded = key.attachmentIndex >= MediaSources.forwardedIndexBase
        let slots = isForwarded ? (message.forwarded?.attachments ?? []) : message.attachments
        let position = isForwarded ? key.attachmentIndex - MediaSources.forwardedIndexBase : key.attachmentIndex
        guard slots.indices.contains(position) else { return nil }
        let slot = slots[position]
        guard slot.kind == .image || slot.kind == .video else { return nil }
        let row = rowFrame(at: index)
        let frame = slot.rect.offsetBy(dx: row.minX, dy: row.minY)
        guard frame.intersects(visibleRect), window != nil else { return nil }
        return MediaSources.Thumbnail(
            frame: convert(frame, to: nil),
            // `drawAttachmentArtwork`'s corner.
            cornerRadius: 8,
            cropsToFill: slot.cropsToFill,
            window: window
        )
    }

    // MARK: A send's flight

    /// Sends on their way from the composer into their bubbles — see
    /// `BubbleFlight`. Each row's own bubble is left unpainted until its
    /// flight lands. Empty for nearly every moment of a session.
    private var flights: [BubbleFlight] = []

    /// The sends in the air, for the coordinator to follow through Discord's
    /// swap of each echo for its own copy.
    var flyingNonces: [MessageID] { flights.map(\.nonce) }

    /// Whether `messageID`'s bubble is in the air rather than in its row — the
    /// one question the painter and the films both ask of a flight.
    func isFlying(_ messageID: MessageID) -> Bool {
        !flights.isEmpty && flights.contains { $0.messageID == messageID }
    }

    /// Flies the bubble of the row `nonce` names, from where its words were in
    /// the composer. Nothing flies for a row with no bubble.
    func launchBubble(nonce: MessageID, from launch: SendLaunch, reducesMotion: Bool) {
        guard let index = messageRows[nonce], case .message(let row) = rows[index].kind,
              let bubble = row.bubbles?.bubble, let window
        else { return }
        // Words, or the one thing that flies without any: a voice note, whose picture
        // travels where words would.
        let block = row.textBlock
        let voice = block == nil ? row.attachments.first(where: { $0.voice != nil }) : nil
        guard block != nil || voice != nil else { return }
        let frame = rowFrame(at: index)
        let scale = window.backingScaleFactor
        let ink = ThemeInk.current
        let tint = BubbleTint.current
        let onAccent = bubble.ground == .accent
        // The frost the row will show, which an accent bubble covers.
        let frost = onAccent || !BubbleTint.showsFrost ? nil : WallpaperFrost.shared.image
        let fill: CGColor = switch bubble.ground {
        case .accent: ink.ownBubble
        case .own: tint.own
        case .neutral: tint.other
        }
        let flight = BubbleFlight(
            nonce: nonce,
            landing: BubbleFlight.Landing(
                body: bubble.rect.offsetBy(dx: frame.minX, dy: frame.minY),
                radius: BubbleMetrics.cornerRadius(for: style.bodyFont),
                tail: bubble.hasTail ? row.bubbles?.side : nil,
                fill: fill,
                rim: onAccent ? nil : tint.rim,
                frost: frost,
                window: frost == nil ? nil : windowInCanvas,
                words: block.map {
                    BubbleFlight.wordsImage(
                        $0, style: style, plates: onAccent ? ink.ownBubblePlates : nil, scale: scale
                    )
                } ?? voice.flatMap { TimelineRowPainter.voiceNoteImage($0, style: style, scale: scale) },
                wordsFrame: block.map {
                    CGRect(
                        x: row.textOrigin.x - bubble.rect.minX,
                        y: row.textOrigin.y - bubble.rect.minY,
                        width: $0.size.width,
                        height: $0.size.height
                    )
                } ?? voice.map { $0.rect.offsetBy(dx: -bubble.rect.minX, dy: -bubble.rect.minY) } ?? .zero,
                // A note has no baseline: its middle travels along the field's.
                firstBaseline: block?.firstBaseline ?? (voice?.rect.height ?? 0) / 2
            ),
            takeOff: BubbleFlight.TakeOff(
                firstBaseline: convert(launch.firstBaseline, from: nil),
                field: convert(launch.field, from: nil),
                // A note isn't set in the field's type, so there's nothing to grow.
                fontScale: block == nil ? 1 : launch.fontSize / style.bodyFont.pointSize,
                isOneLine: launch.isOneLine
            ),
            scale: scale,
            reducesMotion: reducesMotion
        )
        flight.onLanded = { [weak self, weak flight] in
            guard let self, let flight else { return }
            self.land(flight)
        }
        layer?.addSublayer(flight.layer)
        flights.append(flight)
        setNeedsDisplay(frame)
        reconcileFilms()
        onBubbleOutlinesChange?()
    }

    /// Keeps each flight on its row as the rows change under it: `landing`
    /// answers the row a send's nonce is now — its echo, or Discord's copy —
    /// and a flight whose row is gone lands where it is.
    func followFlights(_ landing: (MessageID) -> MessageID?) {
        for flight in flights {
            guard let id = landing(flight.nonce), let index = messageRows[id],
                  case .message(let row) = rows[index].kind, let bubble = row.bubbles?.bubble
            else {
                land(flight)
                continue
            }
            flight.messageID = id
            let origin = rowFrame(at: index).origin
            flight.retarget(to: CGPoint(x: origin.x + bubble.rect.minX, y: origin.y + bubble.rect.minY))
        }
    }

    /// The window's content, in this canvas's space — where the wallpaper and
    /// its frost are laid.
    private var windowInCanvas: CGRect? {
        guard let content = window?.contentView else { return nil }
        return convert(content.bounds, from: content)
    }

    /// The window moved over the rows — a scroll tick, a resize: each flight's
    /// frost follows, as `BubbleFrostView`'s picture does.
    func alignFlightFrost() {
        guard !flights.isEmpty, let window = windowInCanvas else { return }
        for flight in flights { flight.alignFrost(window: window) }
    }

    /// The row paints its bubble, then the flight comes off — **in that
    /// order, in one transaction**, so no frame shows neither.
    private func land(_ flight: BubbleFlight) {
        guard let position = flights.firstIndex(where: { $0 === flight }) else { return }
        flights.remove(at: position)
        if let index = messageRows[flight.messageID] { setNeedsDisplay(rowFrame(at: index)) }
        displayIfNeeded()
        flight.remove()
        reconcileFilms()
        onBubbleOutlinesChange?()
    }

    // MARK: The frost's outlines

    /// Told when a bubble's outline appears or goes without the rows changing —
    /// a send taking off or landing — so the frost under the canvas follows.
    var onBubbleOutlinesChange: (() -> Void)?

    /// Every frosted bubble's outline in `rect`, in document coordinates — what
    /// `BubbleFrostView` is masked to — and every reaction's, which are glass
    /// too. An accent bubble is opaque and needs none, and a send still in the
    /// air has no outline until it lands.
    func bubbleOutlines(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard !rows.isEmpty, var index = rowIndex(at: max(0, rect.minY)) else { return path }
        while index < rows.count, offsets[index] < rect.maxY {
            if case .message(let row) = rows[index].kind {
                let origin = rowFrame(at: index).origin
                let place = CGAffineTransform(translationX: origin.x, y: origin.y)
                if let bubble = row.bubbles?.bubble, bubble.ground != .accent, !isFlying(row.id) {
                    path.addPath(bubble.path, transform: place)
                }
                for slot in row.reactions {
                    path.addPath(slot.outline, transform: place)
                }
            }
            index += 1
        }
        return path
    }

    // MARK: Geometry

    /// Installs the viewport window this canvas covers.
    ///
    /// Bounds first, then frame. `setFrameSize` calls `onWidthChange`
    /// synchronously and that callback can relayout and install newer geometry;
    /// installing this pass's bounds first means it cannot overwrite the
    /// corrected bounds after the callback returns.
    /// Moves the canvas, keeping its coordinate system at 1:1.
    ///
    /// **The frame goes first, and the bounds follows as SIZE and ORIGIN
    /// separately.** `bounds` is not a passive mirror of `frame`: assigning a
    /// bounds whose size differs from the frame's *defines a scale* between the
    /// two, and AppKit remembers it. Assigning the bounds first — while the
    /// frame is still the previous size, or still zero at bootstrap — therefore
    /// installs a scale factor, and every row is drawn stretched or microscopic
    /// until some later pass happens to make the two sizes agree again. That
    /// "until later" is why this looked like it corrected itself: the next
    /// scroll re-entered here with the sizes already matching.
    ///
    /// Measured in the old order from a zero-sized bootstrap, a frame of
    /// 300x800 yields a bounds of **90000x640000** and a scale of 0.003; a
    /// column resize from 300 to 240 yields a 1.25x horizontal stretch. Frame
    /// first, then bounds size, holds both axes at 1.0 through every step.
    func installViewport(frame newFrame: CGRect, bounds newBounds: CGRect) {
        // **The width callback waits until the frame AND the bounds are in.**
        // Setting the frame re-enters through `setFrameSize` → `onWidthChange`
        // → a relayout, which positions this canvas again for the NEW document
        // — and then the rest of this call used to finish, installing the
        // bounds origin computed for the OLD one. The canvas then drew a slice
        // of the document nowhere near its frame: a blank transcript, until some
        // later width change happened to put it right. The split view always
        // produced one of those after launch; the shell (REDESIGN.md) does not,
        // which is how it surfaced.
        let previousWidth = frame.width
        isInstallingViewport = true
        defer {
            isInstallingViewport = false
            if abs(previousWidth - frame.width) >= 1 {
                onWidthChange?(frame.width)
            }
        }
        if frame != newFrame {
            frame = newFrame
            needsDisplay = true
        }
        // The size is the half that can introduce a scale; `setBoundsOrigin`
        // provably cannot, which is why the two are never assigned together.
        if bounds.size != newFrame.size {
            setBoundsSize(newFrame.size)
            needsDisplay = true
            reconcileFilms()
        }
        if bounds.origin != newBounds.origin {
            setBoundsOrigin(newBounds.origin)
            // What is visible has changed, and with it whether anything on
            // screen moves — or might, on its own.
            refreshStickerAnimation()
            refreshAmbient()
            reconcileFilms()
            // A fast gesture can replace the whole overscanned window in one
            // event. Ask for the new contents explicitly so Core Animation never
            // presents an empty slice while waiting for an unrelated
            // invalidation.
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        // Inside `installViewport` the callback is that method's to make, once
        // the bounds are consistent with the frame.
        if !isInstallingViewport, abs(previousWidth - newSize.width) >= 1 {
            onWidthChange?(newSize.width)
        }
    }

    /// Set while `installViewport` is between assigning the frame and the
    /// bounds. See there.
    private var isInstallingViewport = false

    // MARK: Drawing

    /// How many rows have been painted, and in how many passes: what a test
    /// reads to know that a scroll painted the rows it revealed and no others
    /// (docs/PERFORMANCE.md, the scroll pass).
    private(set) var paintedRowCount = 0
    private(set) var paintPassCount = 0

    /// Paints whatever is waiting to be painted, now: what a measurement does
    /// in place of waiting for the next display pass.
    func paintForMeasurement() {
        layer?.displayIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        paintPassCount += 1
        // The view is transparent and layer-backed, and Core Graphics does not
        // guarantee the previous backing pixels are cleared before `draw`. Clear
        // first, or rows composite over their former positions after a scroll.
        context.clear(dirtyRect)

        guard !rows.isEmpty, var index = rowIndex(at: max(0, dirtyRect.minY)) else { return }
        let scale = window?.backingScaleFactor ?? 2
        let images = ImageStore.shared

        // **A super reaction's glow reaches past the foot of its row**, so the
        // row above this rectangle can own pixels inside it — and the clear
        // above has just erased them. That one row is drawn as well, and only
        // when it actually carries a glow: every other repaint costs what it
        // always did.
        var bleedingRow: Int?
        if index > 0, dirtyRect.minY < offsets[index] + Self.burstBleed,
           case .message(let above) = rows[index - 1].kind,
           above.reactions.contains(where: { $0.kind == .burst && $0.palette != nil })
        {
            index -= 1
            bleedingRow = index
        }

        while index < rows.count, offsets[index] < dirtyRect.maxY {
            let frame = rowFrame(at: index)
            if frame.intersects(dirtyRect) || index == bleedingRow {
                paintedRowCount += 1
                let row = rows[index]
                var state = TimelineRowPainter.State()
                // **The preference, then the pointer.** Always-on timestamps are
                // a `TimelineSettings` field and reach the canvas through the
                // presentation revision, which is what invalidates every cached
                // row when it changes — a read of `AppSettings` here would be the
                // painter reading a value its cache cannot see (§1).
                state.showsGutterTimestamp = alwaysShowsTimestamps && !hidesTimes
                state.showsHeaderTimestamp = !hidesTimes
                if hoveredRow == index, !isScrolling {
                    state.isHovered = true
                    state.showsGutterTimestamp = true
                    state.showsHeaderTimestamp = true
                }
                state.animationTime = AnimationClock.shared.time
                if case .message(let message) = row.kind {
                    state.drawsFace = message.bubbles == nil
                    state.hidesBubble = isFlying(message.id)
                    state.layered = films.layered[message.id] ?? .init()
                    // A picture the viewer has lifted leaves its box empty, as
                    // one playing on a layer does.
                    if let lifted = liftedAttachment, lifted.messageID == message.id {
                        if lifted.attachmentIndex >= MediaSources.embedIndexBase {
                            // An embed's picture: `layered` counts those across
                            // every embed in the row, in order.
                            let place = lifted.attachmentIndex - MediaSources.embedIndexBase
                            let (embed, image) = (place / 100, place % 100)
                            if message.embeds.indices.contains(embed) {
                                let before = message.embeds[..<embed].reduce(0) { $0 + $1.images.count }
                                state.layered.embedImages.insert(before + image)
                            }
                        } else {
                            state.layered.attachments.insert(lifted.attachmentIndex)
                        }
                    }
                    if selection != nil, let block = message.textBlock {
                        state.selectedRange = selectedRange(
                            of: message.id, length: block.text.selectableLength
                        )
                    }
                    state.avatarFrame = avatarFilm.avatarFrame(forRow: message.id.rawValue)
                    state.decorationFrame = avatarFilm.decorationFrame(
                        forRow: message.id.rawValue
                    )
                    if !burstEffects.isEmpty {
                        state.burstEffects = burstEffects.showing(on: message.id)
                    }
                    state.pinsReactionControls = pinnedReactionMessage == message.id
                    if !countRolls.isEmpty || !reactionPops.isEmpty {
                        let now = CACurrentMediaTime()
                        for (place, slot) in message.reactions.enumerated() {
                            let key = ReactionChipKey(
                                messageID: message.id, emoji: slot.emoji.reactionKey, kind: slot.kind
                            )
                            if countRolls.contains(key) { state.rollingReactions.insert(place) }
                            if let start = reactionPops[key] { state.reactionPops[place] = now - start }
                        }
                    }
                }
                state.playingPreviewURL = playingPreview
                if case .message(let message) = row.kind,
                   message.attachments.contains(where: { $0.voice != nil })
                {
                    state.voicePlayback = voicePlayback?()
                }
                // The welcome header carries no message, and one control; a
                // fold's line the same.
                if hoveredRow == index {
                    switch row.kind {
                    case .conversationStart, .collapsedGroup, .postActions:
                        state.hoveredComponent = hoveredComponent
                    default: break
                    }
                }
                if let messageID = row.messageID {
                    state.isHighlighted = messageID == highlightedMessageID
                    // A set lookup per visible row, and only for a row that
                    // carries a message at all.
                    state.isBookmarked = bookmarkedMessageIDs.contains(messageID)
                    state.canAddReaction = canAddReactions
                    state.revealedSpoilers = revealedSpoilers[messageID] ?? []
                    state.revealedAttachments = revealedAttachments[messageID] ?? []
                    state.revealedForwardAttachments = revealedForwardAttachments[messageID] ?? []
                    if case .message(let message) = row.kind, let card = message.sharedTheme {
                        state.isPreviewingSharedTheme = isThemePreviewing?(card.theme) == true
                        state.isSharedThemeSaved = isThemeSaved?(card.theme) == true
                    }
                    if case .message(let message) = row.kind, !message.inviteCards.isEmpty {
                        state.settledInviteCodes = Set(message.inviteCards.compactMap { slot in
                            slot.card.flatMap { isInviteSettled?($0) == true ? slot.code : nil }
                        })
                    }
                    if hoveredRow == index {
                        state.isPointerOnReactions = isPointerOnReactions
                        state.hoveredComponent = hoveredComponent
                        state.hoveredPlate = hoveredPlate
                        state.hoveredSpoiler = hoveredSpoiler
                        state.hoveredLink = hoveredLink
                        state.isAuthorNameHovered = isAuthorNameHovered
                        state.hoveredAttachment = hoveredAttachment
                        if let hoveredAttachment,
                           case .message(let message) = row.kind,
                           message.attachments.indices.contains(hoveredAttachment),
                           let gif = message.attachments[hoveredAttachment].favorite
                        {
                            state.isHoveredAttachmentFavorite = isFavoriteGIF?(gif) ?? false
                        }
                        state.hoveredEmbed = hoveredEmbed
                        if let hoveredEmbed,
                           case .message(let message) = row.kind,
                           message.embeds.indices.contains(hoveredEmbed),
                           let gif = message.embeds[hoveredEmbed].favorite
                        {
                            state.isHoveredEmbedFavorite = isFavoriteGIF?(gif) ?? false
                        }
                    }
                }
                if case .message(let message) = row.kind, let upload = message.upload {
                    state.uploadProgress = uploadProgress[message.id] ?? 0
                    state.isUploadCancelHovered = state.isHovered
                        && hoveredComponent == upload.cancelRect.origin
                }
                if case .message(let message) = row.kind, let listenAlong = message.listenAlong {
                    state.listenAlong = listenAlongCards[listenAlong.source.partyID]
                }
                if case .message(let message) = row.kind,
                   let invite = message.activityInvite {
                    let application = invite.source.applicationID
                    if let colours = activityAccents[application] {
                        state.activityAccent = colours.primary
                        state.activityAccentEnd = colours.secondary
                    }
                    state.activityCover = ActivityCardCovers.cover(for: application)
                    state.activityInviteStatus = activityInviteStatuses[application]?.line
                    state.activityInviteIsJoined =
                        activityInviteStatuses[application]?.isJoined ?? false
                }
                var preparedName: DisplayNameEffectPainter.Prepared?
                if state.isHovered, case .message(let message) = row.kind,
                   message.hasAuthorLine, message.authorStyle != nil
                {
                    preparedName = styledAuthorName(for: message)
                    state.playsNameEffect = playsNameEffects
                } else if state.isHovered, case .message(let message) = row.kind,
                          let slot = message.systemName
                {
                    // A DM's system line, lit as Discord lights it there.
                    preparedName = styledSystemName(slot)
                    state.playsNameEffect = playsNameEffects
                }
                if state.isHovered, playsNameEffects {
                    state.nameGradientPhase = nameGradientPhase
                }
                // A row of a fold that is opening or shutting is drawn where
                // `FoldReveal` says it is: part-way out of its line.
                let pose = foldPose(for: row)
                if let pose {
                    context.saveGState()
                    context.setAlpha(pose.alpha)
                    context.translateBy(x: 0, y: pose.offset)
                }
                TimelineRowPainter.draw(
                    row: row,
                    in: frame,
                    context: context,
                    style: style,
                    state: state,
                    images: images,
                    scale: scale,
                    styledAuthorName: preparedName
                )
                if pose != nil { context.restoreGState() }
            }
            index += 1
        }
    }

    /// What a prepared name was built from. A miss on any of it rebuilds.
    ///
    /// **The style is part of the key, not just the font.** Its colours decide
    /// every ramp held in the prepared value, so an account that changes one
    /// while the pointer sits on their message would otherwise keep painting
    /// the old rainbow until the pointer moved.
    private struct StyledNameKey: Hashable {
        var text: String
        var font: NSFont
        var tracking: CGFloat
        var style: DisplayNameStyle
        var maximumWidth: CGFloat
    }

    /// The hovered run head's name as outlines and ramps, and what produced it.
    ///
    /// **One entry, because one row is hovered.** Core Text runs when the
    /// pointer arrives on a name and not again until it leaves — where preparing
    /// inside the draw would be a framesetting pass, an outline per letter and
    /// a gradient, sixty times a second, for a name that cannot change while
    /// somebody is pointing at it.
    private func styledAuthorName(for row: MessageRow) -> DisplayNameEffectPainter.Prepared? {
        guard let worn = row.authorStyle else { return nil }
        // Discord's contrast step, as the profile's copy of the name takes it.
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let nameStyle = worn.legible(on: DisplayNameStyle.ground(isDark: isDark))
        let font = row.authorFace ?? style.authorFont
        let key = StyledNameKey(
            text: row.authorName,
            font: font,
            tracking: row.authorTracking,
            style: nameStyle,
            // The same bound `drawText` truncates against, so the lit name
            // cannot run wider than the plain one it replaces.
            maximumWidth: row.authorRect.width + 8
        )
        if let styledName, styledName.key == key { return styledName.prepared }
        guard let run = DisplayNameGlyphRun(
            text: key.text,
            font: font,
            tracking: key.tracking,
            // Gummy is the one effect that transforms letters independently,
            // and splitting a run nothing splits is wasted work.
            perGlyph: nameStyle.effect == .gummy,
            maximumWidth: key.maximumWidth
        ) else { return nil }
        let prepared = DisplayNameEffectPainter.prepare(
            run: run,
            style: nameStyle,
            pointSize: font.pointSize,
            // **UTF-16, not grapheme clusters.** Prism's tile is a count of
            // character slots and Discord counts them the way JavaScript does,
            // so an emoji in a name is worth two.
            characterCount: key.text.utf16.count
        )
        styledName = (key, prepared)
        return prepared
    }

    /// A hovered DM system line's name as outlines and ramps, through the same
    /// one-entry cache as a run head's — one row is hovered either way.
    private func styledSystemName(_ slot: SystemNameSlot) -> DisplayNameEffectPainter.Prepared? {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let nameStyle = slot.style.legible(on: DisplayNameStyle.ground(isDark: isDark))
        let key = StyledNameKey(
            text: slot.name,
            font: slot.face,
            tracking: slot.tracking,
            style: nameStyle,
            maximumWidth: slot.width + 8
        )
        if let styledName, styledName.key == key { return styledName.prepared }
        guard let run = DisplayNameGlyphRun(
            text: key.text,
            font: slot.face,
            tracking: key.tracking,
            perGlyph: nameStyle.effect == .gummy,
            maximumWidth: key.maximumWidth
        ) else { return nil }
        let prepared = DisplayNameEffectPainter.prepare(
            run: run,
            style: nameStyle,
            pointSize: slot.face.pointSize,
            characterCount: key.text.utf16.count
        )
        styledName = (key, prepared)
        return prepared
    }

    // MARK: Reactions that just changed

    /// Every chip in sight and its count, keyed so the same chip can be found
    /// again after the rows move.
    private func visibleReactionCounts() -> [MessageID: [ReactionChipKey: Int]] {
        guard window != nil, !rows.isEmpty else { return [:] }
        var counts: [MessageID: [ReactionChipKey: Int]] = [:]
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            var chips: [ReactionChipKey: Int] = [:]
            for slot in row.reactions {
                chips[ReactionChipKey(messageID: row.id, emoji: slot.emoji.reactionKey, kind: slot.kind)] = slot.count
            }
            counts[row.id] = chips
        }
        return counts
    }

    /// Rolls the counts that moved and pops the chips that arrived.
    ///
    /// **Only for a message that was already in sight**, so a transcript that
    /// has just loaded, or scrolled a page, animates nothing: `before` holds
    /// the visible rows of the list being replaced, and a message not in it
    /// has no "before" to have changed from.
    private func animateReactionChanges(from before: [MessageID: [ReactionChipKey: Int]]) {
        guard !before.isEmpty else { return }
        let textStyle = style
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind, let known = before[row.id] else { continue }
            let frame = rowFrame(at: index)
            for slot in row.reactions {
                let key = ReactionChipKey(messageID: row.id, emoji: slot.emoji.reactionKey, kind: slot.kind)
                guard let old = known[key] else {
                    // A chip this message did not have: it arrives with a pop.
                    if !reduceMotion { reactionPops[key] = now }
                    continue
                }
                guard old != slot.count, !slot.isTapback || slot.count > 1 else { continue }
                if !reduceMotion, slot.count > old { reactionPops[key] = now }
                let glyph = slot.glyphRect
                let x = glyph.maxX + TimelineMetrics.reactionGlyphGap
                countRolls.roll(
                    key,
                    from: old,
                    to: slot.count,
                    frame: CGRect(
                        x: frame.minX + x,
                        y: frame.minY + slot.rect.minY,
                        width: max(0, slot.rect.maxX - x),
                        height: slot.rect.height
                    ),
                    font: TimelineMetrics.reactionCountFont(textStyle),
                    color: TimelineRowPainter.reactionCountColor(slot, style: textStyle),
                    in: self,
                    reduceMotion: reduceMotion
                ) { [weak self] key in
                    self?.invalidateMessage(key.messageID)
                }
            }
        }
        reconcilePopLink()
    }

    // MARK: A fold opening and shutting

    /// Show or Hide, pressed. Opening asks for the rows and animates them in
    /// when they arrive; shutting animates them out and only then asks for
    /// them to go.
    private func toggleFold(_ group: CollapsedGroup) {
        guard group.canOpen, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            onToggleCollapsedGroup?(group)
            return
        }
        foldClose?.cancel()
        if group.isOpen {
            startFoldMotion(group.messageIDs, closing: true)
            let wait = FoldReveal.duration(rows: group.messageIDs.count, closing: true)
            foldClose = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                onToggleCollapsedGroup?(group)
            }
        } else {
            foldMotion = nil
            pendingFoldOpen = (group.messageIDs, CACurrentMediaTime() + 1)
            onToggleCollapsedGroup?(group)
        }
    }

    private func startFoldMotion(_ ids: [MessageID], closing: Bool) {
        var order: [MessageID: Int] = [:]
        for (place, id) in ids.enumerated() { order[id] = place }
        foldMotion = (order, CACurrentMediaTime(), closing)
        reconcilePopLink()
    }

    /// The rows changed: a fold that was waiting for its messages starts once
    /// they are rows, and one that was shutting is done once they are not.
    private func followFold() {
        if let pending = pendingFoldOpen {
            if let first = pending.ids.first, messageRows[first] != nil {
                pendingFoldOpen = nil
                startFoldMotion(pending.ids, closing: false)
            } else if CACurrentMediaTime() > pending.until {
                pendingFoldOpen = nil
            }
        }
        if let motion = foldMotion, motion.closing, !motion.order.keys.contains(where: { messageRows[$0] != nil }) {
            foldMotion = nil
        }
    }

    /// Where a row of a moving fold is drawn, or nil for every other row.
    private func foldPose(for row: TimelineRow) -> FoldReveal.Pose? {
        guard let motion = foldMotion, let id = row.messageID, let place = motion.order[id] else { return nil }
        let pose = FoldReveal.pose(
            order: place, of: motion.order.count,
            elapsed: CACurrentMediaTime() - motion.start, closing: motion.closing
        )
        return pose == .rest ? nil : pose
    }

    /// Repaints a moving fold's rows, and ends an opening one when it is open.
    private func stepFold(now: CFTimeInterval) {
        guard let motion = foldMotion else { return }
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        for id in motion.order.keys {
            guard let index = messageRows[id] else { continue }
            let frame = rowFrame(at: index)
            top = min(top, frame.minY)
            bottom = max(bottom, frame.maxY)
        }
        if top < bottom {
            setNeedsDisplay(CGRect(
                x: bounds.minX, y: top - FoldReveal.rise,
                width: bounds.width, height: bottom - top + FoldReveal.rise
            ))
        }
        // A shutting fold holds its last pose until its rows are taken away —
        // `followFold` — so they never flash back for a frame.
        let length = FoldReveal.duration(rows: motion.order.count, closing: motion.closing)
        // …but not for ever: a shut that was refused puts the rows back.
        if now - motion.start >= length + (motion.closing ? 0.6 : 0) {
            foldMotion = nil
        }
    }

    /// Keeps the clock going for as long as a chip is popping or a fold moves.
    private func reconcilePopLink() {
        if !reactionPops.isEmpty || foldMotion != nil, window != nil {
            guard popLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(stepReactionPops))
            link.add(to: .main, forMode: .common)
            popLink = link
        } else if let link = popLink {
            link.invalidate()
            popLink = nil
            reactionPops.removeAll()
            foldMotion = nil
        }
    }

    @objc private func stepReactionPops(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        stepFold(now: now)
        // A finished pop is repainted once more, at rest.
        let finished = reactionPops.filter { now - $0.value >= ReactionPop.duration }
        for (key, _) in reactionPops {
            guard let index = messageRows[key.messageID], case .message(let row) = rows[index].kind,
                  let slot = row.reactions.first(where: {
                      $0.kind == key.kind && $0.emoji.reactionKey == key.emoji
                  })
            else { continue }
            let frame = rowFrame(at: index)
            setNeedsDisplay(
                slot.rect.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -4, dy: -4)
            )
        }
        for key in finished.keys { reactionPops[key] = nil }
        reconcilePopLink()
    }

    /// The rows currently inside the canvas's window, as an index range.
    func visibleRowRange() -> Range<Int> {
        rowRange(from: bounds.minY, to: bounds.maxY)
    }

    /// The rows any part of which lies between two heights in the document —
    /// the canvas's window, or the reach the transcript asks pictures for.
    func rowRange(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = rowIndex(at: max(0, minY)) ?? 0
        var last = first
        while last < rows.count, offsets[last] < maxY { last += 1 }
        return first..<max(first, last)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.inVisibleRect` so AppKit keeps the area matched to what is on screen
        // without the canvas recomputing it as the viewport moves.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isScrolling, !isCovered else { return }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// Whether a floating layer is drawn over this canvas.
    ///
    /// **A tracking area is not occlusion-tested.** AppKit dispatches
    /// `mouseMoved:` from the area's own rect in window space, so a SwiftUI
    /// layer over the transcript takes every click — `hitTest:` does respect
    /// view order — and none of the moves. The transcript went on lighting rows
    /// and raising its hover action bar underneath an open profile, and the
    /// reader saw the bar sticking out from behind the card.
    func apply(isCovered: Bool) {
        guard self.isCovered != isCovered else { return }
        self.isCovered = isCovered
        // Only on the way in. Coming back out, the next move re-establishes the
        // hover by itself — and doing it here would light whichever row the
        // pointer happens to be over as the card closes.
        guard isCovered else { return }
        clearHover()
    }

    /// Lets go of the pointer: the same work whether it left the canvas or a
    /// card was drawn over it.
    private func clearHover() {
        pointer = nil
        pointerFace = nil
        applyCursor(nil)
        hoveredComponent = nil
        hoveredPlate = nil
        hoveredSpoiler = nil
        hoveredLink = nil
        isAuthorNameHovered = false
        hoveredBurst = nil
        clearTooltips()
        guard hoveredRow != nil else { return }
        let previous = hoveredRow
        hoveredRow = nil
        styledName = nil
        invalidateRow(previous)
        publishHover()
        // **The same two reconciles the hover-change path runs, and they were
        // missing here.** Everything that moves for the pointer is gated on
        // `hoveredRow`, and leaving the transcript nils it — but nothing asked
        // the clock about it again, so the display link kept firing for a face
        // and a name nobody was pointing at until the next scroll or rows
        // change happened to ask. `updateAvatarPlayback` returns early unless
        // its own film reconciled, so the second call is not redundant.
        updateAvatarPlayback()
        refreshStickerAnimation()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        clearSelection()
        guard let index = rowIndex(at: point.y), rows.indices.contains(index) else { return }
        // A topic's whole marker is its control: it is one band with one
        // meaning. A summary's mark is a label and takes no click.
        if case .marker(.topic, _) = rows[index].kind {
            onOpenTopicMarker?()
            return
        }
        if case .conversationStart(let slot) = rows[index].kind {
            let frame = rowFrame(at: index)
            if let button = slot.editButton,
               button.rect.offsetBy(dx: frame.minX, dy: frame.minY).contains(point)
            {
                onEditChannel?()
            } else if let control = slot.control(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)) {
                let rect = slot.buttons.first { $0.action == control.action }?.rect ?? slot.mutuals?.rect ?? .zero
                onHeadAction?(control.action, anchorInHostingRoot(rect.offsetBy(dx: frame.minX, dy: frame.minY)))
            }
            return
        }
        if case .postActions(let slot) = rows[index].kind {
            let frame = rowFrame(at: index)
            if let button = slot.buttons.first(where: {
                $0.rect.offsetBy(dx: frame.minX, dy: frame.minY).contains(point)
            }) {
                onPostAction?(button.action, anchorInHostingRoot(button.rect.offsetBy(dx: frame.minX, dy: frame.minY)))
            }
            return
        }
        // A fold opens and shuts from its one word, as Discord's anchor does.
        if case .collapsedGroup(let slot) = rows[index].kind {
            let frame = rowFrame(at: index)
            if let action = slot.action,
               action.rect.offsetBy(dx: frame.minX, dy: frame.minY).contains(point)
            {
                toggleFold(slot.group)
            }
            return
        }
        guard case .message(let row) = rows[index].kind else { return }
        // **The row's, bound here, because the name is taken.** A row-space rect
        // offset by a bare `frame` compiles against this view's own and anchors
        // hundreds of points away — off the window, where a popover does not
        // appear at all: Add Reaction, an invite's "+ N more" and a command's
        // chip each did nothing, with nothing to say why.
        let frame = rowFrame(at: index)

        switch target(in: row, at: point, rowIndex: index) {
        case .spoiler(let spoilerIndex):
            revealedSpoilers[row.id, default: []].insert(spoilerIndex)
            invalidateRow(index)
            // An emoji the spoiler covered can move now.
            reconcileFilms()
        case .embedImage(let embedIndex, let imageIndex):
            guard row.embeds.indices.contains(embedIndex) else { return }
            var pictures: [EmbedPicture] = []
            var clicked = 0
            for (position, image) in row.embeds[embedIndex].images.enumerated()
            where image.controls == nil && !image.isSpoiler {
                guard let media = image.viewerMedia else { continue }
                if position == imageIndex { clicked = pictures.count }
                pictures.append(EmbedPicture(
                    media: media,
                    sourceIndex: MediaSources.embedIndex(embed: embedIndex, image: position),
                    posterWidth: image.decodeWidth,
                    posterURL: image.url
                ))
            }
            onOpenEmbedPictures?(row.id, pictures, clicked)
        case .attachment(let attachmentIndex, let isHidden):
            // The first click on a spoiler uncovers it and stops there. Opening
            // it full-screen in the same press would show the picture to the
            // room before the reader had decided to.
            guard !isHidden else {
                revealedAttachments[row.id, default: []].insert(attachmentIndex)
                invalidateRow(index)
                reconcileFilms()
                // Its picture was never fetched while it was covered.
                onRevealAttachment?()
                return
            }
            onOpenAttachment?(row.id, attachmentIndex, row.attachments.map(\.decodeWidth), row.attachments.map(\.url))
        case .forwardedAttachment(let attachmentIndex, let isHidden):
            guard let forward = row.forwarded else { return }
            guard !isHidden else {
                revealedForwardAttachments[row.id, default: []].insert(attachmentIndex)
                invalidateRow(index)
                reconcileFilms()
                onRevealAttachment?()
                return
            }
            onOpenForwardedAttachment?(
                row.id, attachmentIndex, forward.attachments.map(\.decodeWidth), forward.attachments.map(\.url)
            )
        case .forwardJump(let jump):
            onJumpToForwarded?(jump)
        case .downloadAttachment(let attachmentIndex, _):
            onDownloadAttachment?(row.id, attachmentIndex)
        case .favoriteGIF(let attachmentIndex):
            guard let gif = row.attachments[attachmentIndex].favorite else { return }
            onToggleFavoriteGIF?(gif)
            invalidateRow(index)
            // The star over a GIF on a layer is the layer host's to redraw.
            films.setBadge(filmBadge(), scale: window?.backingScaleFactor ?? 2)
        case .previewClip(let url):
            onTogglePreview?(url)
        case .voiceToggle(let voice):
            onToggleVoiceNote?(voice)
        case .voiceBars(let voice):
            voiceScrub = (voice, frame.minX)
            onScrubVoiceNote?(voice, voice.fraction(atX: point.x - frame.minX), .began)
        case .voiceRate:
            onCycleVoiceRate?()
        case .voiceCard:
            break
        case .openMusicPlayer(let card, let rect):
            Log.debug(.spotify, "open chip hit, wired=\(onOpenMusicPlayer != nil)")
            onOpenMusicPlayer?(card, rect)
        case .favoriteEmbedGIF(let embedIndex):
            guard row.embeds.indices.contains(embedIndex),
                  let gif = row.embeds[embedIndex].favorite
            else { return }
            onToggleFavoriteGIF?(gif)
            invalidateRow(index)
            films.setBadge(filmBadge(), scale: window?.backingScaleFactor ?? 2)
        case .link(let destination, let rect):
            onOpenLink?(destination, rect)
        case .playVideo(let video, let rect):
            let origin = rowFrame(at: index).origin
            onPlayVideo?(row.id, video, rect.offsetBy(dx: origin.x, dy: origin.y))
        case .emoji(let emoji, let rect):
            onOpenEmoji?(emoji, rect)
        case .sticker(let sticker, let rect):
            onOpenSticker?(sticker, rect)
        case .person(let userID, let rect):
            onOpenProfile?(userID, rect)
        case .crosspostAuthor(let rect):
            onOpenCrosspostAuthor?(row.id, rect)
        case .serverTag(let userID, let rect):
            onOpenServerTag?(userID, rect)
        case .card(let action, _, let rect):
            onCardAction?(row.id, action, anchorInHostingRoot(rect))
        case .component(let url, let customID, _):
            // A disabled control consumes the click and does nothing, which is
            // what a disabled control is. A live one is exactly one of the two:
            // a link opens, an action posts an interaction.
            if let url {
                onOpenLink?(.url(url), .zero)
            } else if let customID {
                onPressComponent?(row.id, customID)
            }
        case .select(let customID, let rect):
            let origin = rowFrame(at: index).origin
            onOpenSelect?(row.id, customID, rect.offsetBy(dx: origin.x, dy: origin.y))
        case .dismissEphemeral:
            onDismissEphemeral?(row.id)
        case .cancelUpload:
            onCancelUpload?(row.id)
        case .pollAnswer(let answerID, _):
            if let answerID { onVote?(row.id, answerID) }
        case .activityInvite(let origin):
            // `.zero` means the click landed on the card but not on the button.
            if origin != .zero { onPlayActivity?(row.id) }
        case .listenAlong(let origin):
            if origin != .zero { onListenAlong?(row.id) }
        case .inviteButton(let invite, _):
            onInviteButton?(invite)
        case .inviteChannel(let channelID, _):
            onOpenInviteChannel?(channelID)
        case .sharedThemePreview(let theme, _):
            onPreviewSharedTheme?(theme)
        case .sharedThemeSave(let theme, let creator, _):
            onSaveSharedTheme?(theme, creator)
        case .inviteFold(let fold, _):
            onToggleInviteFold?(fold)
        case .inviteMark:
            // The mark answers the pointer, not a click — see `onHoverMark`.
            break
        case .inviteTraits(let traits, let rect):
            // In the hosting root's space, as the reaction picker's anchor is.
            onShowTraits?(traits, anchorInHostingRoot(rect.offsetBy(dx: frame.minX, dy: frame.minY)))
        case .reaction(let emoji, let kind, _):
            // A super reaction chip without Nitro is not a control; the click
            // lands on it and stops there. See `canSuperReact`.
            guard kind == .normal || canSuperReact else { return }
            onToggleReaction?(row.id, emoji, kind)
        case .addReaction(let rect):
            // In the hosting root's space, not the window's — see
            // `anchorInHostingRoot`, and `INVARIANTS.md` §1 for the three
            // plausible answers that are wrong first.
            onAddReaction?(
                row.id,
                anchorInHostingRoot(rect.offsetBy(dx: frame.minX, dy: frame.minY))
            )
        case .bookmark:
            onToggleBookmark?(row.id)
        case .threadChip(let threadID, _):
            onOpenThread?(threadID)
        case .resend:
            onResend?(row.id)
        case .replyHeader(let target):
            // A strip with nothing behind it still swallows the click: falling
            // through would open the profile of whoever is underneath.
            if let target { onOpenReplyTarget?(target) }
        case .interactionCommand(let rect):
            onOpenCommand?(row.id, anchorInHostingRoot(rect.offsetBy(dx: frame.minX, dy: frame.minY)))
        case nil:
            if beginSelection(in: row, rowIndex: index, at: point, clicks: event.clickCount) { return }
            if event.clickCount == 2 { onActivateMessage?(row.id) }
        }
    }

    // MARK: Text selection
    //
    // **Keyed by message and character, not by row.** Rows are rebuilt when a
    // message arrives above, and a selection stored as row indexes would slide
    // onto somebody else's words. Ordered by the rows only when it is drawn or
    // copied.

    /// A character boundary in one message's body.
    struct TextPoint: Equatable {
        var messageID: MessageID
        var index: Int
    }

    /// Where the press began and where the pointer is.
    private var selection: (anchor: TextPoint, focus: TextPoint)?
    private var isSelecting = false
    /// Each message's row, rebuilt with the rows.
    private var messageRows: [MessageID: Int] = [:]

    /// Starts a selection when a press lands on body text: one click places
    /// it, two take the word, three the whole message.
    private func beginSelection(in row: MessageRow, rowIndex: Int, at point: CGPoint, clicks: Int) -> Bool {
        guard let block = row.textBlock,
              let start = textPoint(in: row, rowIndex: rowIndex, at: point, clamped: false)
        else { return false }
        window?.makeFirstResponder(self)
        switch clicks {
        case 2:
            let word = block.wordRange(at: start.index)
            selection = (TextPoint(messageID: row.id, index: word.location),
                         TextPoint(messageID: row.id, index: NSMaxRange(word)))
        case 3...:
            selection = (TextPoint(messageID: row.id, index: 0),
                         TextPoint(messageID: row.id, index: block.text.selectableLength))
        default:
            selection = (start, start)
            isSelecting = true
        }
        invalidateRow(rowIndex)
        return true
    }

    /// A place in a row's body text: nil off the text unless `clamped`, which
    /// pins a point above the text to its start and below it to its end.
    private func textPoint(in row: MessageRow, rowIndex: Int, at point: CGPoint, clamped: Bool) -> TextPoint? {
        guard let block = row.textBlock else { return nil }
        let frame = rowFrame(at: rowIndex)
        let local = CGPoint(
            x: point.x - frame.minX - row.textOrigin.x,
            y: point.y - frame.minY - row.textOrigin.y
        )
        guard clamped || CGRect(origin: .zero, size: block.size).contains(local) else { return nil }
        return TextPoint(messageID: row.id, index: block.characterIndex(at: local))
    }

    override func mouseDragged(with event: NSEvent) {
        // The pointer's height doesn't matter once it's holding the bars.
        if let voiceScrub {
            let point = convert(event.locationInWindow, from: nil)
            let x = point.x - voiceScrub.rowX
            onScrubVoiceNote?(voiceScrub.voice, voiceScrub.voice.fraction(atX: x), .moved)
            return
        }
        guard isSelecting, let current = selection else {
            super.mouseDragged(with: event)
            return
        }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let focus = focusPoint(at: point), focus != current.focus else { return }
        let before = selectedRows()
        selection = (current.anchor, focus)
        for index in before.union(selectedRows()) { invalidateRow(index) }
    }

    override func mouseUp(with event: NSEvent) {
        if voiceScrub != nil {
            voiceScrub = nil
            return
        }
        guard isSelecting else {
            super.mouseUp(with: event)
            return
        }
        isSelecting = false
        if let selection, selection.anchor == selection.focus { clearSelection() }
    }

    /// Where a drag puts the selection's moving end: the body in the row under
    /// the pointer, or — over a row with none — the end of the nearest body
    /// above it, or the start of the nearest below.
    private func focusPoint(at point: CGPoint) -> TextPoint? {
        guard let index = rowIndex(at: point.y) else { return nil }
        if case .message(let row) = rows[index].kind,
           let hit = textPoint(in: row, rowIndex: index, at: point, clamped: true)
        {
            return hit
        }
        for above in stride(from: index - 1, through: 0, by: -1) {
            if case .message(let row) = rows[above].kind, let block = row.textBlock {
                return TextPoint(messageID: row.id, index: block.text.selectableLength)
            }
        }
        for below in (index + 1)..<rows.count {
            if case .message(let row) = rows[below].kind, row.textBlock != nil {
                return TextPoint(messageID: row.id, index: 0)
            }
        }
        return nil
    }

    /// The selection's two ends, in reading order.
    private var orderedSelection: (start: TextPoint, end: TextPoint, startRow: Int, endRow: Int)? {
        guard let selection,
              let anchorRow = messageRows[selection.anchor.messageID],
              let focusRow = messageRows[selection.focus.messageID]
        else { return nil }
        let forward = (anchorRow, selection.anchor.index) <= (focusRow, selection.focus.index)
        return forward
            ? (selection.anchor, selection.focus, anchorRow, focusRow)
            : (selection.focus, selection.anchor, focusRow, anchorRow)
    }

    private func selectedRows() -> Set<Int> {
        guard let ordered = orderedSelection else { return [] }
        return Set(ordered.startRow...ordered.endRow)
    }

    /// The part of one message's body inside the selection.
    private func selectedRange(of messageID: MessageID, length: Int) -> NSRange? {
        guard let ordered = orderedSelection, let row = messageRows[messageID],
              row >= ordered.startRow, row <= ordered.endRow
        else { return nil }
        let from = row == ordered.startRow ? ordered.start.index : 0
        let to = row == ordered.endRow ? ordered.end.index : length
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    private func clearSelection() {
        guard selection != nil else { return }
        let rows = selectedRows()
        selection = nil
        isSelecting = false
        for index in rows { invalidateRow(index) }
    }

    /// ⌘C: the selected words, one message to a line, with each custom emoji
    /// as its `:name:` — what Discord puts on the pasteboard.
    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// macOS's Look Up over the selected words — the dictionary's panel, with
    /// the words lit where they are drawn. The message menu's Look Up ends
    /// here, through `TimelineCoordinator.lookUpSelection`.
    ///
    /// **The first message's words only**: the panel looks up one run of
    /// text, and a selection across messages is several.
    func lookUpSelection() {
        guard let ordered = orderedSelection,
              rows.indices.contains(ordered.startRow),
              case .message(let row) = rows[ordered.startRow].kind,
              let block = row.textBlock,
              let range = selectedRange(of: row.id, length: block.text.selectableLength),
              let baseline = block.baselineOrigin(at: range.location)
        else { return }
        let frame = rowFrame(at: ordered.startRow)
        showDefinition(
            for: block.text.attributed.attributedSubstring(from: range),
            at: CGPoint(
                x: frame.minX + row.textOrigin.x + baseline.x,
                y: frame.minY + row.textOrigin.y + baseline.y
            )
        )
    }

    func selectedText() -> String? {
        guard let ordered = orderedSelection else { return nil }
        var parts: [String] = []
        for index in ordered.startRow...ordered.endRow {
            guard case .message(let row) = rows[index].kind, let block = row.textBlock,
                  let range = selectedRange(of: row.id, length: block.text.selectableLength)
            else { continue }
            parts.append(Self.plainText(of: block.text, in: range))
        }
        return parts.joined(separator: "\n")
    }

    /// A range of a body as text. An inline emoji's placeholder becomes its
    /// name; a chip's glyph, which is decoration, is dropped.
    static func plainText(of text: MessageText, in range: NSRange) -> String {
        let string = text.attributed.string as NSString
        var result = ""
        var run = range.location
        for location in range.location..<NSMaxRange(range) where string.character(at: location) == 0xFFFC {
            result += string.substring(with: NSRange(location: run, length: location - run))
            if let emoji = text.inlineEmoji[location] {
                result += emoji.id == nil ? emoji.name : ":\(emoji.name):"
            }
            run = location + 1
        }
        result += string.substring(with: NSRange(location: run, length: NSMaxRange(range) - run))
        return result
    }

    /// The full menu, at the pointer.
    ///
    /// **`rightMouseDown` rather than `menu(for:)`.** AppKit's own path expects
    /// an `NSMenu`, and this app's menu is a glass surface presented at the
    /// window root — the transcript is a drawn canvas and cannot host a
    /// presentation at all. What it hands up is the rect to anchor to, which is
    /// a one-point box at the pointer so the menu grows out of where the reader
    /// clicked.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else {
            super.rightMouseDown(with: event)
            return
        }
        // A right-click on somebody's name or face is about them rather than
        // the message — Discord's member menu, beside what was clicked.
        if case .person(let userID, let rect)? = target(in: row, at: point, rowIndex: index) {
            onOpenPersonMenu?(userID, rect)
            return
        }
        onOpenMenu?(row.id, CGRect(origin: point, size: CGSize(width: 1, height: 1)))
    }

    // MARK: Hit testing

    /// What is under a point in a message row.
    ///
    /// **One resolver, used by the click AND by the cursor.** A pointing hand
    /// over something that turns out not to be clickable — or a plain arrow over
    /// something that is — is the kind of drift that appears the moment the two
    /// answers are written twice.
    ///
    /// Rects come back in this view's own space, which is document space, so a
    /// popover can be anchored to the exact face or picture that was clicked.
    private enum Target {
        case spoiler(Int)
        /// A picture, a GIF or a video, and whether it is still covered.
        case attachment(index: Int, isHidden: Bool)
        /// The same, among a forward's own files.
        case forwardedAttachment(index: Int, isHidden: Bool)
        /// One of an embed's pictures, which opens in the viewer as Discord's
        /// do: the embed's index in the row and the picture's in its slot.
        case embedImage(embedIndex: Int, imageIndex: Int)
        /// A forward's breadcrumb: the way to the original.
        case forwardJump(ForwardJump)
        /// The star on a GIF. Ahead of the picture in the hit test, because it
        /// sits inside it and the picture would otherwise swallow every press.
        case favoriteGIF(index: Int)
        /// A file card's Download, in the group hanging past its corner — its
        /// rect in row space, the origin to light.
        case downloadAttachment(index: Int, rect: CGRect)
        /// The same star, on a GIF that arrived as an unfurled link rather than
        /// as a file. A separate case because the two index different arrays.
        case favoriteEmbedGIF(index: Int)
        /// A video's Play: what it starts, and the thumbnail it plays over.
        case playVideo(EmbedVideo, CGRect)
        /// The Preview chip on a music card.
        case previewClip(URL)
        /// A voice note's disc, its bars, and its speed pill.
        case voiceToggle(VoiceNoteSlot)
        case voiceBars(VoiceNoteSlot)
        case voiceRate(VoiceNoteSlot)
        /// The rest of a voice note's capsule, which does nothing and swallows the
        /// click: it isn't a picture to open.
        case voiceCard
        /// The Open chip, which raises Spotify's own player. Carries the card's
        /// rect so the panel can be anchored to it — §1.
        case openMusicPlayer(SpotifyUnfurl, CGRect)
        case link(MessageText.LinkTarget, CGRect)
        case emoji(EmojiRef, CGRect)
        case sticker(StickerRef, CGRect)
        case person(UserID, CGRect)
        /// A crosspost's name or face: its publisher's card.
        case crosspostAuthor(CGRect)
        /// The server tag beside a name: that server's card, as Discord's tag
        /// opens its guild profile.
        case serverTag(UserID, CGRect)
        /// A control on a drawn card: what it does, its origin in row space
        /// for the painter to light, and its rect in this view's space.
        case card(DrawnCardAction, origin: CGPoint, rect: CGRect)
        /// A button an app attached. Carries its origin in row space so the
        /// painter can light the one under the pointer.
        case component(url: String?, customID: String?, origin: CGPoint)
        /// A select menu this client can answer, with its rect in the row.
        case select(customID: String, rect: CGRect)
        case dismissEphemeral(origin: CGPoint)
        /// The cancel on an upload's card. Its origin, in row space.
        case cancelUpload(origin: CGPoint)
        /// One answer in a poll. `answerID` is nil where the poll cannot be
        /// voted in — the row still swallows the click rather than letting it
        /// fall through to whatever is beneath.
        case pollAnswer(answerID: Int?, origin: CGPoint)
        /// The Play button on an activity invitation. Carries its origin in row
        /// space so the painter can light it, exactly as a component button
        /// does.
        case activityInvite(origin: CGPoint)
        /// A listen-along card's button, when it may be pressed — `.zero`
        /// for the rest of the card.
        case listenAlong(origin: CGPoint)
        /// An invite card's button. Carries its origin in row space so the
        /// painter can light it; the card's own body takes no click.
        case inviteButton(InviteCard, origin: CGPoint)
        /// A voice invite card's way to its channel. Its origin, in row space.
        case inviteChannel(ChannelID, origin: CGPoint)
        /// A shared theme card's Preview — or Stop Preview. Its origin, in row space.
        case sharedThemePreview(SharedClientTheme, origin: CGPoint)
        /// A shared theme card's Save, with who shared it.
        case sharedThemeSave(SharedClientTheme, creator: String, origin: CGPoint)
        /// A folded profile card, which opens where it is clicked, or its Hide
        /// Details. The origin is the control's, in row space.
        case inviteFold(InviteCardFold, origin: CGPoint)
        /// A server's mark on an invite card. Its rect, in row space.
        case inviteMark(GuildMark, rect: CGRect)
        /// A profile invite card's "+ N more" chip: the traits behind it, and
        /// its rect in row space — the origin to light, the size to anchor.
        case inviteTraits([GuildTrait], rect: CGRect)
        /// A reaction chip. Clicking it adds or removes the reader's own of the
        /// chip's kind. Carries its origin in row space so the painter can
        /// light the one under the pointer — identified by origin, not index,
        /// for the reason `hoveredComponent` is.
        case reaction(EmojiRef, kind: ReactionKind, origin: CGPoint)
        /// The square control that opens the emoji picker for this message, at
        /// the end of its reaction row. Carries its rect in **row** space — the
        /// origin for the painter to light, and the size for the click to
        /// convert into an anchor. Converting here instead would do it on every
        /// pointer move for the one press that needs it.
        case addReaction(rect: CGRect)
        /// The square control beside it, which keeps the message or lets it go.
        case bookmark(origin: CGPoint)
        /// The chip under a message that started a thread. Carries the thread
        /// to open, and its origin in row space so the painter can light it.
        case threadChip(ChannelID, origin: CGPoint)
        /// A refused send's red disc, which sends it again. Its origin in row
        /// space, for the painter to light.
        case resend(origin: CGPoint)
        /// The quoted line above a reply. Carries where to go, or nil when the
        /// quoted message is gone — which still swallows the click, because a
        /// strip that says "original message was deleted" is not a hole in the
        /// row.
        case replyHeader(MessageID?)
        /// A pressable chip on a "used" line. Its rect in row space — the origin
        /// for the painter to light, the size for the flyout's anchor.
        case interactionCommand(rect: CGRect)
    }

    private func target(in row: MessageRow, at point: CGPoint, rowIndex index: Int) -> Target? {
        let frame = rowFrame(at: index)
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        // A bubble's face is wherever it is riding, over whichever of its
        // run's rows is under it (`StickyFaces`).
        if let face = stickyFaces.face(at: point) {
            return face.run.isCrosspost ? .crosspostAuthor(face.frame) : .person(face.run.authorID, face.frame)
        }

        // The quoted line sits above the author line and overlaps nothing, so
        // it is tested first and costs one rect containment on a reply and a
        // nil check on everything else.
        if let header = row.replyHeader, header.rect.contains(local) {
            return .replyHeader(header.targetID)
        }
        // A "used" line: the chip does what its kind does (Alex's screenshots 31
        // and 32), and the face and the name open whoever ran it, as Discord's do.
        if let header = row.interactionHeader {
            if header.chip.isPressable, header.chipRect.contains(local) {
                return .interactionCommand(rect: header.chipRect)
            }
            for rect in [header.avatarRect, header.nameRect] where rect.contains(local) {
                return .person(header.userID, rect.offsetBy(dx: frame.minX, dy: frame.minY))
            }
        }

        // A drawn card's words first — the channel's chip and the names in
        // AutoMod's sentence — then its controls, faces before the card.
        if let card = row.card, card.rect.contains(local) {
            for part in card.parts {
                guard case .text(let block, let origin) = part, !block.linkRects.isEmpty,
                      let hit = block.link(at: CGPoint(x: local.x - origin.x, y: local.y - origin.y))
                else { continue }
                return .link(hit.target, hit.rect.offsetBy(dx: origin.x + frame.minX, dy: origin.y + frame.minY))
            }
            if let control = card.control(at: local) {
                let rect = control.rect.offsetBy(dx: frame.minX, dy: frame.minY)
                if case .person(let userID) = control.action { return .person(userID, rect) }
                return .card(control.action, origin: control.rect.origin, rect: rect)
            }
        }

        // A spoiler beats everything under it: the reveal has to happen before
        // the thing underneath can be reached, or a masked link inside a spoiler
        // opens without ever being read.
        if let block = row.textBlock {
            let inBlock = CGPoint(
                x: local.x - row.textOrigin.x,
                y: local.y - row.textOrigin.y
            )
            let revealed = revealedSpoilers[row.id] ?? []
            for (rect, spoiler) in block.spoilerRects
            where !revealed.contains(spoiler) && rect.contains(inBlock) {
                return .spoiler(spoiler)
            }
            // Emoji before links, because an emoji sits inside a run that may
            // also carry a link attribute — a custom emoji written inside a
            // markdown link is rare and the picture is what was clicked.
            for entry in block.emojiRects where entry.rect.contains(inBlock) {
                return .emoji(
                    entry.emoji,
                    entry.rect
                        .offsetBy(dx: row.textOrigin.x, dy: row.textOrigin.y)
                        .offsetBy(dx: frame.minX, dy: frame.minY)
                )
            }
            // A standard emoji opens its card too — Discord's flyout for a
            // default emoji. Ahead of links for the reason the custom ones are.
            for entry in block.unicodeEmojiRects where entry.rect.contains(inBlock) {
                return .emoji(
                    entry.emoji,
                    entry.rect
                        .offsetBy(dx: row.textOrigin.x, dy: row.textOrigin.y)
                        .offsetBy(dx: frame.minX, dy: frame.minY)
                )
            }
            if let hit = block.link(at: inBlock) {
                return .link(
                    hit.target,
                    hit.rect
                        .offsetBy(dx: row.textOrigin.x, dy: row.textOrigin.y)
                        .offsetBy(dx: frame.minX, dy: frame.minY)
                )
            }
        }

        // An embed's own runs carry links: a title that is a URL, an author
        // that is one, a description full of them. The block was laid out in
        // embed space, so the point has to be brought into it the same way the
        // body's is.
        for text in row.embeds.lazy.flatMap(\.texts) {
            let inBlock = CGPoint(x: local.x - text.origin.x, y: local.y - text.origin.y)
            guard inBlock.x >= 0, inBlock.y >= 0,
                  inBlock.x <= text.block.size.width, inBlock.y <= text.block.size.height,
                  let hit = text.block.link(at: inBlock)
            else { continue }
            return .link(
                hit.target,
                hit.rect
                    .offsetBy(dx: text.origin.x, dy: text.origin.y)
                    .offsetBy(dx: frame.minX, dy: frame.minY)
            )
        }

        // Only the "Dismiss message" run, not the note beside it: a target that
        // spanned the whole line would throw the message away on a click meant
        // for nothing at all.
        if let note = row.ephemeralNote, note.dismissRect.contains(local) {
            return .dismissEphemeral(origin: note.dismissRect.origin)
        }

        // Only while there is something to stop: a full bar has nothing left
        // to cancel, and Discord takes its cancel away with "Processing...".
        if let upload = row.upload, upload.cancelRect.contains(local),
           uploadProgress[row.id] ?? 0 < 1
        {
            return .cancelUpload(origin: upload.cancelRect.origin)
        }

        // Every button is a hit, live or not: a dead one still has to swallow
        // the click rather than letting it fall through to whatever is beneath.
        for slot in row.components where slot.rect.contains(local) {
            if let selectID = slot.selectID { return .select(customID: selectID, rect: slot.rect) }
            return .component(url: slot.url, customID: slot.customID, origin: slot.rect.origin)
        }

        // The whole card is a hit, not only the button: a click anywhere on it
        // must not fall through to the row beneath, and the button is the only
        // part of it that does anything.
        if let theme = row.sharedTheme, theme.rect.contains(local) {
            if theme.preview.rect.contains(local) {
                return .sharedThemePreview(theme.theme, origin: theme.preview.rect.origin)
            }
            if theme.save.rect.contains(local) {
                // Saved is a state, not a control: it swallows the click, offers no hand.
                guard isThemeSaved?(theme.theme) != true else { return .component(url: nil, customID: nil, origin: .zero) }
                return .sharedThemeSave(theme.theme, creator: theme.creatorName, origin: theme.save.rect.origin)
            }
            // The rest of the card swallows the click.
            return .component(url: nil, customID: nil, origin: .zero)
        }
        for card in row.inviteCards where card.rect.contains(local) {
            if let button = card.button, button.rect.contains(local), let invite = card.card {
                // Your own friend link's button is drawn and is not a control:
                // a dead one, which swallows the click and offers no hand.
                return button.isEnabled
                    ? .inviteButton(invite, origin: button.rect.origin)
                    : .component(url: nil, customID: nil, origin: button.rect.origin)
            }
            if let mark = card.mark, card.markRect.contains(local) {
                return .inviteMark(mark, rect: card.markRect)
            }
            if case .voice(let voice) = card.body, voice.breadcrumbRect.contains(local) {
                return .inviteChannel(voice.channelID, origin: voice.breadcrumbRect.origin)
            }
            if case .voiceRow(let row) = card.body, row.headerRect.contains(local) {
                return .inviteChannel(row.channelID, origin: row.headerRect.origin)
            }
            // Not under a folded card's fade, where it is going or gone.
            if case .profile(let profile) = card.body, let more = profile.moreTraits, more.rect.contains(local) {
                let isFaded = if case .collapsed(let fade) = card.fold { more.rect.maxY > fade.minY } else { false }
                if !isFaded { return .inviteTraits(more.traits, rect: more.rect) }
            }
            if let target = card.foldTarget, target.contains(local) {
                return .inviteFold(InviteCardFold(message: row.id, code: card.code), origin: target.origin)
            }
        }
        if let invite = row.activityInvite, invite.rect.contains(local) {
            return .activityInvite(
                origin: invite.buttonRect.contains(local) ? invite.buttonRect.origin : .zero
            )
        }
        if let card = row.listenAlong, card.rect.contains(local) {
            let pressable = listenAlongCards[card.source.partyID]?.isButtonEnabled == true
            guard pressable, let button = card.buttonRect, button.contains(local) else {
                return .listenAlong(origin: .zero)
            }
            return .listenAlong(origin: button.origin)
        }

        if let poll = row.poll, poll.rect.contains(local) {
            for answer in poll.answers where answer.rect.contains(local) {
                return .pollAnswer(
                    answerID: poll.isVotable ? answer.answerID : nil,
                    origin: answer.rect.origin
                )
            }
        }

        for slot in row.stickers where slot.rect.contains(local) {
            return .sticker(slot.sticker, slot.rect.offsetBy(dx: frame.minX, dy: frame.minY))
        }

        // A music card's Preview chip. Ahead of the star below, because the two
        // never share an embed and checking a usually-empty array first costs a
        // count.
        for slot in row.embeds where !slot.chips.isEmpty {
            for chip in slot.chips where chip.rect.contains(local) {
                switch chip.kind {
                case .preview:
                    if let url = slot.previewURL { return .previewClip(url) }
                case .open:
                    if let card = slot.spotify {
                        return .openMusicPlayer(
                            card, slot.rect.offsetBy(dx: frame.minX, dy: frame.minY)
                        )
                    }
                case .explicit:
                    // A mark, not a control. It still swallows the click rather
                    // than letting it fall through to the card behind it.
                    return nil
                }
            }
        }

        // An unfurled GIF's star. Only the star: the picture itself has no
        // click behaviour here, so nothing else in an embed's rect is claimed
        // and a link inside a card still reaches the text hit test below.
        for (embedIndex, slot) in row.embeds.enumerated()
        where slot.favorite != nil && slot.favoriteRect.contains(local) {
            return .favoriteEmbedGIF(index: embedIndex)
        }

        // A video's Play and Open Link.
        for slot in row.embeds {
            for image in slot.images {
                guard let controls = image.controls, let video = image.video, video.isPlayable else { continue }
                if controls.play.contains(local) { return .playVideo(video, image.rect) }
                if controls.open.contains(local) {
                    return .link(.url(controls.page.absoluteString), controls.open)
                }
            }
        }

        // An embed's picture opens the viewer (Alex, 2026-11-16: "in embeds
        // i cant click the images"). Not a film's poster — its controls are
        // above — nor a covered spoiler, nor an author's or footer's mark.
        for (embedIndex, slot) in row.embeds.enumerated() {
            for (imageIndex, image) in slot.images.enumerated()
            where image.viewerMedia != nil && image.controls == nil && !image.isSpoiler && image.rect.contains(local) {
                return .embedImage(embedIndex: embedIndex, imageIndex: imageIndex)
            }
        }

        let revealedHere = revealedAttachments[row.id] ?? []
        // A file's Download first: it hangs past the card, over whatever is
        // beside it, as Discord's hover group does.
        for (attachmentIndex, slot) in row.attachments.enumerated() {
            if let button = slot.downloadRect, button.contains(local) {
                return .downloadAttachment(index: attachmentIndex, rect: button)
            }
        }
        // A voice note's controls, a little more than their shapes: the bars are thin
        // and two points of air between them is still the bars.
        for slot in row.attachments where slot.rect.contains(local) {
            guard let voice = slot.voice else { continue }
            if voice.pill.insetBy(dx: -4, dy: -6).contains(local) { return .voiceRate(voice) }
            if voice.disc.insetBy(dx: -4, dy: -4).contains(local) { return .voiceToggle(voice) }
            if voice.barsRect.insetBy(dx: -3, dy: -8).contains(local) { return .voiceBars(voice) }
            return .voiceCard
        }
        // A text preview is its hosted card's to answer, which sits over it.
        for (attachmentIndex, slot) in row.attachments.enumerated()
        where slot.kind != .textPreview && slot.rect.contains(local) {
            let isHidden = slot.isSpoiler && !revealedHere.contains(attachmentIndex)
            // The star, before the picture it is drawn on. A spoiler still
            // covered has no star to press: the first click uncovers.
            if slot.favorite != nil, !isHidden, slot.favoriteRect.contains(local) {
                return .favoriteGIF(index: attachmentIndex)
            }
            return .attachment(index: attachmentIndex, isHidden: isHidden)
        }

        // **A forward's own content, which the hit test used to stop short
        // of**: its files open the viewer, its spoilers lift, its stickers and
        // its cards' links answer, and its breadcrumb goes to the original.
        // Its words, when they are the row's own text, were answered above.
        if let forward = row.forwarded, forward.rect.contains(local) {
            if let jump = forward.jump, forward.footerRect.insetBy(dx: -4, dy: -2).contains(local) {
                return .forwardJump(jump)
            }
            for slot in forward.stickers where slot.rect.contains(local) {
                return .sticker(slot.sticker, slot.rect.offsetBy(dx: frame.minX, dy: frame.minY))
            }
            let revealed = revealedForwardAttachments[row.id] ?? []
            for (index, slot) in forward.attachments.enumerated()
            where slot.kind != .textPreview && slot.rect.contains(local) {
                return .forwardedAttachment(index: index, isHidden: slot.isSpoiler && !revealed.contains(index))
            }
            for slot in forward.embeds {
                for image in slot.images {
                    guard let controls = image.controls, let video = image.video, video.isPlayable else { continue }
                    if controls.play.contains(local) { return .playVideo(video, image.rect) }
                    if controls.open.contains(local) {
                        return .link(.url(controls.page.absoluteString), controls.open)
                    }
                }
            }
            for text in forward.embeds.lazy.flatMap(\.texts) {
                let inBlock = CGPoint(x: local.x - text.origin.x, y: local.y - text.origin.y)
                guard inBlock.x >= 0, inBlock.y >= 0,
                      inBlock.x <= text.block.size.width, inBlock.y <= text.block.size.height,
                      let hit = text.block.link(at: inBlock)
                else { continue }
                return .link(
                    hit.target,
                    hit.rect.offsetBy(dx: text.origin.x, dy: text.origin.y).offsetBy(dx: frame.minX, dy: frame.minY)
                )
            }
        }

        if let chip = row.threadChip, chip.rect.contains(local) {
            return .threadChip(chip.targetID, origin: chip.rect.origin)
        }

        // A little more than the disc, which is small for a pointer to find.
        if let failure = row.bubbles?.failure, failure.badge.insetBy(dx: -4, dy: -4).contains(local) {
            return .resend(origin: failure.badge.origin)
        }

        for slot in row.reactions where slot.rect.contains(local) {
            return .reaction(slot.emoji, kind: slot.kind, origin: slot.rect.origin)
        }

        // The pointer is on the row, which is what shows both controls.
        let controls = row.visibleReactionControls(canAddReaction: canAddReactions, showsBookmark: true)
        for slot in controls where slot.rect.contains(local) {
            switch slot.kind {
            case .addReaction:
                return .addReaction(rect: slot.rect)
            case .bookmark:
                return .bookmark(origin: slot.rect.origin)
            }
        }

        // The face, then the name. Both open the same card, and both are things
        // a reader points at when they want to know who somebody is — or, for
        // a crosspost, what published it.
        if row.tag != nil, row.hasAuthorLine, row.tagRect.contains(local) {
            return .serverTag(row.authorID, row.tagRect.offsetBy(dx: frame.minX, dy: frame.minY))
        }
        if row.bubbles == nil, let avatarRect = row.avatarRect, avatarRect.contains(local) {
            let rect = avatarRect.offsetBy(dx: frame.minX, dy: frame.minY)
            return row.isCrosspost ? .crosspostAuthor(rect) : .person(row.authorID, rect)
        }
        if row.hasAuthorLine, row.authorRect.contains(local) {
            let rect = row.authorRect.offsetBy(dx: frame.minX, dy: frame.minY)
            return row.isCrosspost ? .crosspostAuthor(rect) : .person(row.authorID, rect)
        }
        return nil
    }

    /// The cursor currently installed by this view, so an equal set is skipped.
    ///
    /// `NSCursor.set()` is not free and the pointer generates moves at event
    /// rate; setting the same cursor sixty times a second is sixty calls into
    /// the window server for no change at all.
    private var installedCursor: NSCursor?

    private func applyCursor(_ cursor: NSCursor?) {
        guard installedCursor !== cursor else { return }
        installedCursor = cursor
        (cursor ?? .arrow).set()
    }

    private func currentPointerLocation() -> CGPoint {
        guard let window else { return CGPoint(x: -1, y: -1) }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Which row the pointer belongs to.
    ///
    /// **Sticky for the row already hovered, and only for that one.** The action
    /// pill floats over the row's top edge and overhangs the row above it by a
    /// few points, so a pointer travelling up into the pill would otherwise be
    /// read as having left the row the pill belongs to — the pill would vanish
    /// under the cursor on its way to being clicked. Applying the region to the
    /// current row alone means a *fresh* hover can never be mis-assigned.
    private func hoveredIndex(at point: CGPoint) -> Int? {
        // The empty space above a short channel is nobody's row.
        guard bounds.contains(point), point.y >= leadingSpace else { return nil }
        let index = rowIndex(at: point.y)
        if let current = hoveredRow, current != index, rows.indices.contains(current),
           case .message(let row) = rows[current].kind,
           TimelineMetrics.actionBarRegion(
               inRow: rowFrame(at: current), anchor: row.bubbles?.pillAnchor
           ).contains(point)
        {
            return current
        }
        return index
    }

    private func updateHover(at point: CGPoint) {
        let index = hoveredIndex(at: point)
        pointer = point
        let face = stickyFaces.face(at: point)?.run.headID
        if face != pointerFace {
            pointerFace = face
            updateAvatarPlayback()
        }

        // The pointing hand and the lit button, resolved from the same function
        // the click uses. Bounded work: one row's rectangles, and only while
        // nothing is scrolling.
        var cursor: NSCursor?
        var component: CGPoint?
        var plate: Int?
        var link: MessageText.LinkTarget?
        var authorName = false
        var spoiler: Int?
        var attachment: Int?
        var embed: Int?
        var burst: (key: SuperReactionEffects.Key, slot: ReactionSlot, row: MessageRow)?
        var reaction: ReactionHover?
        var markHover: GuildMarkHover?
        var autoModHover: AutoModActionHover?
        var editedHover: EditedMarkHover?
        var onReactions = false
        if let index, rows.indices.contains(index), case .message(let row) = rows[index].kind {
            // **Resolved from the geometry, not from the click target.** The
            // star is drawn on whichever picture the pointer is over, and the
            // target under the pointer is the *star* once it is on it — so
            // asking the target which attachment this is would take the badge
            // away the moment somebody reached for it.
            let local = CGPoint(
                x: point.x - rowFrame(at: index).minX,
                y: point.y - rowFrame(at: index).minY
            )
            onReactions = row.reactionStripContains(local, rowWidth: rowFrame(at: index).width)
            // What a moderator did on an AutoMod alert answers the pointer
            // with Discord's sentence — see `onHoverAutoModAction`.
            if let tip = row.card?.tips.first(where: { $0.rect.contains(local) }) {
                let clip = enclosingScrollView?.contentView.bounds.origin ?? .zero
                autoModHover = AutoModActionHover(
                    action: tip.action,
                    frame: tip.rect.offsetBy(dx: rowFrame(at: index).minX - clip.x, dy: offsets[index] - clip.y)
                )
            }
            // "(edited)" answers the pointer with when — Discord's tooltip on
            // it. See `onHoverEditedMark`.
            if let mark = row.editedMark, mark.rect.contains(local) {
                let clip = enclosingScrollView?.contentView.bounds.origin ?? .zero
                editedHover = EditedMarkHover(
                    editedAt: mark.editedAt,
                    frame: mark.rect.offsetBy(dx: rowFrame(at: index).minX - clip.x, dy: offsets[index] - clip.y)
                )
            }
            // A file stays hovered while the pointer is on its Download, which
            // hangs past it.
            attachment = row.attachments.firstIndex {
                $0.rect.contains(local) || $0.downloadRect?.contains(local) == true
            }
            // The same rule for an unfurled GIF, and only for the embeds that
            // have a star at all — a card the pointer crosses has nothing to
            // reveal, so it must not claim the hover from the picture below it.
            embed = row.embeds.firstIndex {
                $0.favorite != nil && $0.rect.contains(local)
            }
            switch target(in: row, at: point, rowIndex: index) {
            case .person, .crosspostAuthor:
                // The name, not the face: only the words underline.
                authorName = row.hasAuthorLine && row.authorRect.contains(local)
                cursor = .pointingHand
            case .serverTag:
                cursor = .pointingHand
            case .component(let url, let customID, let origin):
                component = origin
                cursor = url == nil && customID == nil ? nil : .pointingHand
            case .dismissEphemeral(let origin), .cancelUpload(let origin):
                component = origin
                cursor = .pointingHand
            case .voiceToggle(let voice):
                component = voice.disc.origin
                cursor = .pointingHand
            case .voiceRate(let voice):
                component = voice.pill.origin
                cursor = .pointingHand
            case .voiceBars:
                cursor = .pointingHand
            case .pollAnswer(let answerID, let origin):
                component = origin
                cursor = answerID == nil ? nil : .pointingHand
            case .activityInvite(let origin), .listenAlong(let origin):
                component = origin
                cursor = origin == .zero ? nil : .pointingHand
            case .inviteButton(_, let origin), .inviteChannel(_, let origin),
                 .sharedThemePreview(_, let origin), .sharedThemeSave(_, _, let origin):
                component = origin
                cursor = .pointingHand
            case .inviteFold(_, let origin):
                component = origin
                cursor = .pointingHand
            case .inviteTraits(_, let rect):
                component = rect.origin
                cursor = .pointingHand
            case .inviteMark(let mark, let rect):
                let clip = enclosingScrollView?.contentView.bounds.origin ?? .zero
                markHover = GuildMarkHover(
                    mark: mark,
                    frame: rect.offsetBy(dx: rowFrame(at: index).minX - clip.x, dy: offsets[index] - clip.y)
                )
            case .reaction(let emoji, let kind, let origin):
                let clip = enclosingScrollView?.contentView.bounds.origin ?? .zero
                if let slot = row.reactions.first(where: { $0.rect.origin == origin }) {
                    reaction = ReactionHover(
                        messageID: row.id,
                        emoji: emoji,
                        kind: kind,
                        chipFrame: slot.rect.offsetBy(dx: -clip.x, dy: offsets[index] - clip.y)
                    )
                }
                if kind == .burst,
                   let slot = row.reactions.first(where: { $0.rect.origin == origin })
                {
                    burst = (
                        SuperReactionEffects.Key(messageID: row.id, emoji: emoji.reactionKey),
                        slot,
                        row
                    )
                }
                // Lit and offered a hand only when a click would do something.
                if kind == .normal || canSuperReact {
                    component = origin
                    cursor = .pointingHand
                }
            case .addReaction(let rect):
                component = rect.origin
                cursor = .pointingHand
            case .card(_, let origin, _):
                component = origin
                cursor = .pointingHand
            case .bookmark(let origin):
                component = origin
                cursor = .pointingHand
            case .threadChip(_, let origin):
                // The origin is published so the painter lights the chip the
                // pointer is on, exactly as a reaction chip does.
                component = origin
                cursor = .pointingHand
            case .resend(let origin):
                component = origin
                cursor = .pointingHand
            case .replyHeader(let target):
                // A quote with nothing behind it swallows the click and goes
                // nowhere, so it must not offer a hand that says it does.
                cursor = target == nil ? nil : .pointingHand
            case .interactionCommand(let rect):
                component = rect.origin
                cursor = .pointingHand
            case .favoriteGIF, .embedImage:
                cursor = .pointingHand
            case .downloadAttachment(_, let rect):
                component = rect.origin
                cursor = .pointingHand
            case .favoriteEmbedGIF, .previewClip, .openMusicPlayer, .playVideo:
                cursor = .pointingHand
            case .forwardJump:
                // The breadcrumb's origin, which the painter lights.
                component = row.forwarded?.footerRect.origin
                cursor = .pointingHand
            case .spoiler(let index):
                spoiler = index
                cursor = .pointingHand
            case .link(let target, _):
                link = target
                plate = row.textBlock.flatMap { block in
                    let inBlock = CGPoint(x: local.x - row.textOrigin.x, y: local.y - row.textOrigin.y)
                    return block.plateRects.first {
                        $0.rect.contains(inBlock) && block.text.plates[$0.plate].isInteractive
                    }?.plate
                }
                cursor = .pointingHand
            case .some:
                cursor = .pointingHand
            case nil:
                // Body text reads as text: the I-beam says it can be selected.
                // "(edited)" cannot be, as Discord's `user-select: none` cannot.
                if editedHover == nil, textPoint(in: row, rowIndex: index, at: point, clamped: false) != nil {
                    cursor = .iBeam
                }
            }
        } else if let index, rows.indices.contains(index), case .marker(.topic, _) = rows[index].kind {
            cursor = .pointingHand
        } else if let index, rows.indices.contains(index), case .conversationStart(let slot) = rows[index].kind,
                  let button = slot.editButton,
                  button.rect.contains(CGPoint(x: point.x - rowFrame(at: index).minX,
                                               y: point.y - rowFrame(at: index).minY))
        {
            component = button.rect.origin
            cursor = .pointingHand
        } else if let index, rows.indices.contains(index), case .conversationStart(let slot) = rows[index].kind,
                  let control = slot.control(at: CGPoint(x: point.x - rowFrame(at: index).minX,
                                                         y: point.y - rowFrame(at: index).minY))
        {
            component = control.origin
            cursor = .pointingHand
        } else if let index, rows.indices.contains(index), case .postActions(let slot) = rows[index].kind,
                  let button = slot.buttons.first(where: {
                      $0.rect.contains(CGPoint(x: point.x - rowFrame(at: index).minX,
                                               y: point.y - rowFrame(at: index).minY))
                  })
        {
            component = button.rect.origin
            cursor = .pointingHand
        } else if let index, rows.indices.contains(index), case .collapsedGroup(let slot) = rows[index].kind,
                  let action = slot.action,
                  action.rect.contains(CGPoint(x: point.x - rowFrame(at: index).minX,
                                               y: point.y - rowFrame(at: index).minY))
        {
            component = action.rect.origin
            cursor = .pointingHand
        }
        applyCursor(cursor)

        // Entering a super reaction chip plays its effect — for everybody,
        // Nitro or not, exactly as Discord's hover does. Once per entry: a move
        // across the chip is not a second entry.
        if burst?.key != hoveredBurst {
            hoveredBurst = burst?.key
            if let burst { playEffect(burst.slot, on: burst.row, trigger: .hover) }
        }
        publishReactionHover(reaction)
        publishMarkHover(markHover)
        publishAutoModHover(autoModHover)
        publishEditedMarkHover(editedHover)

        // A write of an equal value still costs a redraw request, and the
        // pointer generates these at event rate.
        let rowChanged = index != hoveredRow
        let componentChanged = component != hoveredComponent
        let textChanged = plate != hoveredPlate || spoiler != hoveredSpoiler
            || link != hoveredLink || authorName != isAuthorNameHovered
        let attachmentChanged = attachment != hoveredAttachment
        let embedChanged = embed != hoveredEmbed
        let reactionsChanged = onReactions != isPointerOnReactions
        guard rowChanged || componentChanged || textChanged || attachmentChanged || embedChanged
            || reactionsChanged
        else { return }
        let previous = hoveredRow
        hoveredRow = index
        hoveredComponent = component
        hoveredPlate = plate
        hoveredSpoiler = spoiler
        hoveredAttachment = attachment
        hoveredEmbed = embed
        hoveredLink = link
        isAuthorNameHovered = authorName
        isPointerOnReactions = onReactions
        if rowChanged { invalidateRow(previous) }
        invalidateRow(index)
        if attachmentChanged || embedChanged || rowChanged {
            films.setBadge(filmBadge(), scale: window?.backingScaleFactor ?? 2)
        }
        if rowChanged {
            publishHover()
            updateAvatarPlayback()
            // **Not left to `updateAvatarPlayback`.** That one returns early
            // unless its own film changed, so a row whose face is a still JPEG
            // and whose name is Prism would never reach the reconcile — the
            // name would light and then stand there.
            refreshStickerAnimation()
        }
    }

    /// Points the hover film at whatever the pointer is on.
    ///
    /// **Reconciles a subject rather than reacting to an event**, so the four
    /// things that change what should be playing — the pointer moving, a scroll
    /// starting, the rows being rebuilt under the pointer, and the reader's
    /// animation preference — all funnel through one decision.
    ///
    /// Only a **run head** has a face: everything else in a run leaves the
    /// gutter empty, so there is nothing to animate and `avatarRect` is the
    /// same test the painter uses.
    func updateAvatarPlayback() {
        let wanted: HoverAvatarFilm.Subject? = {
            guard AnimationClock.playsAnimatedEmoji, !isScrolling else { return nil }
            // A bubble's face riding the bottom is over another row of its
            // run: the run's last message is still the one it belongs to.
            let faceRow = pointer.flatMap { stickyFaces.face(at: $0) }.flatMap { messageRows[$0.run.tailID] }
            guard let index = faceRow ?? hoveredRow, rows.indices.contains(index),
                  case .message(let row) = rows[index].kind,
                  row.avatarRect != nil
            else { return nil }
            return HoverAvatarFilm.Subject(
                rowID: row.id.rawValue,
                avatarURL: row.avatarURL,
                decorationURL: row.decorationURL,
                avatarSide: Metrics.avatarMessage,
                scale: window?.backingScaleFactor ?? 2
            )
        }()
        guard avatarFilm.reconcile(to: wanted) else { return }
        invalidateRow(hoveredRow)
        refreshStickerAnimation()
    }

    /// Tells the window which row the pointer is on, and where that row is.
    ///
    /// **In the clip view's space, not the document's.** What reads this is a
    /// glass pill overlaid on the scroll view, which is laid out in the
    /// viewport — publishing document coordinates would put the pill wherever
    /// the row happens to be in the whole transcript, which for a channel
    /// scrolled a thousand messages back is somewhere off the screen entirely.
    private func publishHover() {
        guard let onHoverMessage else { return }
        guard let index = hoveredRow, rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else {
            onHoverMessage(nil)
            return
        }
        let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        let frame = rowFrame(at: index).offsetBy(dx: -origin.x, dy: -origin.y)
        onHoverMessage(MessageHover(
            messageID: row.id,
            rowFrame: frame,
            pillAnchor: row.bubbles?.pillAnchor?.offsetBy(dx: frame.minX, dy: frame.minY)
        ))
    }

    /// Tells the window which reaction chip the pointer rests on. Equal writes
    /// are dropped here: the pointer moves at event rate and the answer
    /// changes only at a chip's edge.
    private func publishReactionHover(_ hover: ReactionHover?) {
        guard hover != hoveredReaction else { return }
        hoveredReaction = hover
        onHoverReaction?(hover)
    }

    private func publishMarkHover(_ hover: GuildMarkHover?) {
        guard hover != hoveredMark else { return }
        hoveredMark = hover
        onHoverMark?(hover)
    }

    private func publishAutoModHover(_ hover: AutoModActionHover?) {
        guard hover != hoveredAutoModAction else { return }
        hoveredAutoModAction = hover
        onHoverAutoModAction?(hover)
    }

    private func publishEditedMarkHover(_ hover: EditedMarkHover?) {
        guard hover != hoveredEditedMark else { return }
        hoveredEditedMark = hover
        onHoverEditedMark?(hover)
    }

    /// Every floating answer about the thing under the pointer, withdrawn
    /// together — `INVARIANTS.md` §5: nothing outlives what it names.
    private func clearTooltips() {
        publishReactionHover(nil)
        publishMarkHover(nil)
        publishAutoModHover(nil)
        publishEditedMarkHover(nil)
    }

    // MARK: Highlight

    /// Flashes one message — for a jump from a search result or a reply.
    func highlight(_ messageID: MessageID?) {
        guard highlightedMessageID != messageID else { return }
        let previous = highlightedMessageID
        highlightedMessageID = messageID
        if let previous { invalidateMessage(previous) }
        if let messageID { invalidateMessage(messageID) }
    }

    // MARK: Accessibility
    //
    // The canvas is one element with children built on demand. Building a proxy
    // per row eagerly would put an object per message into the accessibility
    // tree, which is the cost the drawn timeline exists to avoid; building them
    // for the visible window only keeps the tree the size of the viewport.
    //
    // **The hosted cards are children too** — a profile, an event, a text
    // file's preview: live views over the rows, which an override that lists
    // only the drawn elements would hide from VoiceOver.

    override func accessibilityChildren() -> [Any]? {
        let range = visibleRowRange()
        let hosted: [Any] = subviews.filter { $0.identifier == HostedCardHosts.identifier }
        return hosted + range.flatMap { index -> [NSAccessibilityElement] in
            switch rows[index].kind {
            case .message(let row):
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(row.accessibilityLabel)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
                // A drawn card's buttons, one each, as it draws them.
                let frame = rowFrame(at: index)
                let buttons = (row.card?.controls ?? []).filter { !$0.accessibilityLabel.isEmpty }.map { control in
                    let button = PressableAccessibilityElement()
                    let rect = control.rect.offsetBy(dx: frame.minX, dy: frame.minY)
                    let action = control.action
                    let messageID = row.id
                    button.press = { [weak self] in
                        guard let self else { return }
                        if case .person(let userID) = action {
                            self.onOpenProfile?(userID, rect)
                        } else {
                            self.onCardAction?(messageID, action, self.anchorInHostingRoot(rect))
                        }
                    }
                    button.setAccessibilityRole(.button)
                    button.setAccessibilityLabel(control.accessibilityLabel)
                    button.setAccessibilityParent(self)
                    button.setAccessibilityFrameInParentSpace(rect)
                    return button as NSAccessibilityElement
                }
                // A voice note says what it is and how long, and pressing it plays it.
                let notes = row.attachments.compactMap(\.voice).map { voice in
                    let button = PressableAccessibilityElement()
                    button.press = { [weak self] in self?.onToggleVoiceNote?(voice) }
                    button.setAccessibilityRole(.button)
                    button.setAccessibilityLabel(VoiceNoteWords.spoken(seconds: voice.duration))
                    button.setAccessibilityParent(self)
                    button.setAccessibilityFrameInParentSpace(voice.disc.offsetBy(dx: frame.minX, dy: frame.minY))
                    return button as NSAccessibilityElement
                }
                return [element] + buttons + notes
            case .collapsedGroup(let slot):
                // A fold that opens is a button; one that cannot is a line.
                let element = PressableAccessibilityElement()
                if slot.action != nil {
                    let group = slot.group
                    element.press = { [weak self] in self?.onToggleCollapsedGroup?(group) }
                }
                element.setAccessibilityRole(slot.action == nil ? .staticText : .button)
                element.setAccessibilityLabel(slot.accessibilityLabel)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
                return [element]
            case .postActions(let slot):
                // One button each, as the bar draws them.
                let frame = rowFrame(at: index)
                return slot.buttons.map { button in
                    let element = PressableAccessibilityElement()
                    let rect = button.rect.offsetBy(dx: frame.minX, dy: frame.minY)
                    let action = button.action
                    element.press = { [weak self] in
                        guard let self else { return }
                        self.onPostAction?(action, self.anchorInHostingRoot(rect))
                    }
                    element.setAccessibilityRole(.button)
                    element.setAccessibilityLabel(button.accessibilityLabel)
                    element.setAccessibilityParent(self)
                    element.setAccessibilityFrameInParentSpace(rect)
                    return element
                }
            default:
                return []
            }
        }
    }
}

/// A drawn control as VoiceOver meets it — a fold's word, a post bar's button:
/// pressing it does what clicking it does.
///
/// `nonisolated` as its superclass is; AppKit asks it on the main thread, which
/// is where the press runs.
private nonisolated final class PressableAccessibilityElement: NSAccessibilityElement {
    nonisolated(unsafe) var press: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}

/// The full-height document the scroller measures against.
///
/// It draws nothing. Its only job is to be the right size, so the scroll view
/// knows how far there is to travel while the canvas inside it stays small.
final class TimelineDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
    /// Declining every hit lets clicks reach the canvas above it without this
    /// view having to forward them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }
}
