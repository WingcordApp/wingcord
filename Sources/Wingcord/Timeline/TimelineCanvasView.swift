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

    var style: MessageTextStyle
    /// Whether a continuation row draws its gutter time without being pointed
    /// at. Set beside `style` from the same revision, for the same reason.
    var alwaysShowsTimestamps = false
    var contentHeight: CGFloat { offsets[offsets.count - 1] }

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
        }
    }

    /// The channel these rows are in. A different one ends every effect and
    /// forgets which chips have had their ambient play.
    func apply(channelID: ChannelID) {
        guard self.channelID != channelID else { return }
        self.channelID = channelID
        burstEffects.stopAll()
        ambientPlayed.removeAll()
        pendingArrivals.removeAll()
        hoveredBurst = nil
        publishReactionHover(nil)
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
    /// Which attachment the pointer is over. Its own field for the reason
    /// `TimelineRowPainter.State.hoveredAttachment` gives.
    private var hoveredAttachment: Int?
    /// Which unfurled embed the pointer is over. Its own field beside the
    /// attachment's, because a message can carry both a pasted `.gif` file and a
    /// Tenor link and one field would put the star on the wrong one.
    private var hoveredEmbed: Int?
    private var highlightedMessageID: MessageID?
    private var revealedSpoilers: [MessageID: Set<Int>] = [:]
    /// Which spoilered attachments have been uncovered, keyed the same way and
    /// deliberately in a separate table — see `TimelineRowPainter.State`.
    private var revealedAttachments: [MessageID: Set<Int>] = [:]
    /// An application id → the colour its invitation card is ruled with.
    ///
    /// Pushed in rather than read from the store: the painter is `nonisolated`
    /// so a render test can drive it, and a draw loop must not reach for a
    /// main-actor singleton.
    private var activityAccents: [ApplicationID: CGColor] = [:]
    /// What `activityAccents` was built from, kept so the comparison above can
    /// be an equality rather than a count.
    private var packedActivityAccents: [ApplicationID: UInt32] = [:]
    /// The live line each invitation draws, by application, and whether the
    /// reader is in it. Pushed in and redrawn — never laid out. See
    /// `ActivityInviteSlot.statusOrigin`.
    private var activityInviteStatuses: [ApplicationID: ActivityInviteStatus] = [:]
    /// Suppressed while a scroll is running. `.onContinuousHover`-shaped work is
    /// worst exactly during a scroll: a trackpad flick moves no pointer at all
    /// yet drags every row in the list underneath a stationary one, so the
    /// canvas would compute hover for rows nobody is pointing at during the one
    /// stretch with least to spare.
    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue else { return }
            if isScrolling { publishReactionHover(nil) }
            if isScrolling, hoveredRow != nil {
                let previous = hoveredRow
                hoveredRow = nil
                hoveredComponent = nil
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
    var onOpenAttachment: ((MessageID, Int, [CGFloat]) -> Void)?
    /// Stars or un-stars a GIF in the transcript.
    var onToggleFavoriteGIF: ((GIF) -> Void)?
    /// Starts or stops a music card's thirty-second clip.
    var onTogglePreview: ((URL) -> Void)?
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
    /// A poll answer was chosen.
    var onVote: ((MessageID, Int) -> Void)?
    /// A button an application attached, pressed. Carries the message it sits on
    /// and the `custom_id` the interaction has to echo — the canvas knows both
    /// and the store knows neither.
    var onPressComponent: ((MessageID, String) -> Void)?
    /// "Dismiss message" on an ephemeral row. A real removal: the message exists
    /// only in this session, so taking it out of the store destroys the only
    /// copy the reader can reach.
    var onDismissEphemeral: ((MessageID) -> Void)?
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
    /// A reply's quoted line was clicked: go to what it quotes.
    var onOpenReplyTarget: ((MessageID) -> Void)?
    /// The open topic's marker was clicked: bring its panel back.
    var onOpenTopicMarker: (() -> Void)?
    /// The thread chip under a message was clicked: open that thread.
    var onOpenThread: ((ChannelID) -> Void)?
    /// The pointer moved onto, or off, a message row. The rect is in the CLIP
    /// VIEW's space, because what reads it is a floating pill overlaid on the
    /// scroll view rather than anything in document coordinates.
    var onHoverMessage: ((MessageID?, CGRect) -> Void)?
    /// The full menu was asked for — a right-click, or the pill's own button.
    var onOpenMenu: ((MessageID, CGRect) -> Void)?
    /// The pointer moved onto, or off, a reaction chip. The chip's frame is in
    /// the CLIP VIEW's space, for the reason `onHoverMessage`'s is: what reads
    /// it is the tooltip overlaid on the scroll view.
    var onHoverReaction: ((ReactionHover?) -> Void)?
    /// The chip last published through `onHoverReaction`.
    private var hoveredReaction: ReactionHover?

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

    // MARK: Animated stickers
    //
    // **The canvas subscribes to the shared clock, not one timer per sticker.**
    // A drawn transcript has no per-sticker view to hang a display link off, and
    // a link each would be the one-timer-per-animation problem `AnimationClock`
    // exists to prevent. One subscriber invalidates only the rects whose FRAME
    // has actually changed — the clock runs at up to 24 fps and stickers are
    // authored at 10-20, so most ticks resolve to the picture already on screen
    // and cost a dictionary lookup.
    //
    // It does not run through a scroll: `AnimationClock`'s default parks
    // playback while a gesture is in flight, which is what buys the scroll its
    // frames.

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

    /// The frame index each visible filmstrip is currently showing.
    private var shownFilmFrames: [FilmSlot: Int] = [:]
    private var isAnimatingStickers = false
    private var animationToken: ObjectIdentifier { ObjectIdentifier(self) }

    init(style: MessageTextStyle) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        layer?.drawsAsynchronously = false
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

    func apply(activityAccents accents: [ApplicationID: UInt32]) {
        // Compared as packed values, which are `Equatable`; a `CGColor`
        // dictionary is not, and this runs on every update.
        guard accents != packedActivityAccents else { return }
        packedActivityAccents = accents
        activityAccents = accents.mapValues {
            CGColor(
                srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255,
                green: CGFloat(($0 >> 8) & 0xFF) / 255,
                blue: CGFloat($0 & 0xFF) / 255,
                alpha: 1
            )
        }
        setNeedsDisplay(visibleRect)
    }

    /// Installs a new row list and recomputes the offset table.
    ///
    /// Returns the content height so the coordinator can resize the document in
    /// the same pass, rather than through a callback that would land a frame
    /// later and leave the scroller briefly wrong.
    @discardableResult
    func apply(rows: [TimelineRow]) -> CGFloat {
        self.rows = rows
        offsets.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(rows.count + 1)
        var running: CGFloat = 0
        offsets.append(0)
        for row in rows {
            running += row.height
            offsets.append(running)
        }
        // Clear any hover that referred to a row index that no longer exists.
        if let hoveredRow, hoveredRow >= rows.count { self.hoveredRow = nil }
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
        needsDisplay = true
        refreshStickerAnimation()
        return running
    }

    /// Subscribes to the clock while something on screen is moving, and stops
    /// the moment nothing is.
    ///
    /// **Four kinds of moving picture, one subscription.** A sticker, a GIF
    /// attachment, a GIF a link unfurled into and the hovered row's own face
    /// are all filmstrips drawn by the same painter on the same clock, and
    /// giving each its own subscription would be four display-link callbacks
    /// for one repaint.
    ///
    /// Called from every place the answer can change: a rows change, a viewport
    /// move, and the pass that installs newly-decoded film. Idempotent, so those
    /// three can call it freely.
    func refreshStickerAnimation() {
        let wanted = window != nil && hasVisibleFilm
        guard wanted != isAnimatingStickers else { return }
        isAnimatingStickers = wanted
        if wanted {
            AnimationClock.shared.subscribe(animationToken) { [weak self] in
                self?.advanceFilm()
            }
        } else {
            AnimationClock.shared.unsubscribe(animationToken)
            shownFilmFrames.removeAll(keepingCapacity: true)
        }
    }

    /// Releases the clock subscription. Idempotent.
    func stopStickerAnimation() {
        avatarFilm.cancel()
        guard isAnimatingStickers else { return }
        isAnimatingStickers = false
        AnimationClock.shared.unsubscribe(animationToken)
        shownFilmFrames.removeAll(keepingCapacity: false)
    }

    private var hasVisibleFilm: Bool {
        // The hovered row's face and decoration ride this same subscription —
        // "three kinds of moving picture, one subscription" is four now, and
        // giving the fourth its own display-link callback for one repaint is
        // exactly what that sentence is about.
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
        if burstEffects.isShaking(at: AnimationClock.shared.time) || !shakingChips.isEmpty {
            return true
        }
        let playsEmoji = AnimationClock.playsAnimatedEmoji
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            if row.stickers.contains(where: \.isAnimated) { return true }
            if row.attachments.contains(where: \.isAnimated) { return true }
            for embed in row.embeds where embed.images.contains(where: \.isAnimated) {
                return true
            }
            // **Custom emoji in the message body, which used not to count.**
            // They were the one moving picture the transcript drew as a still —
            // documented as out of scope at the time and asked for since. The
            // tag carries `isAnimated`, so a message of ordinary Unicode emoji
            // costs nothing here.
            if playsEmoji,
               row.textBlock?.emojiRects.contains(where: { $0.emoji.isAnimated }) == true
            {
                return true
            }
            // **And the emoji on reaction chips**, which drew as a plate — or,
            // animated, as frame zero — because nothing had ever asked for
            // their pictures.
            if playsEmoji,
               row.reactions.contains(where: { $0.emoji.isAnimated && $0.imageURL != nil })
            {
                return true
            }
        }
        return false
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
              row.isRunHead, (row.authorGradient?.count ?? 0) >= 2
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
              row.isRunHead, let style = row.authorStyle
        else { return false }
        return DisplayNameEffectPainter.animates(style)
    }

    /// One clock tick: repaint only the boxes whose frame actually moved.
    ///
    /// **Per box, not per row and never the whole canvas.** A ten-frame GIF
    /// authored at 10 fps changes on one clock tick in three, and a repaint of
    /// the viewport for a picture that did not move is the cost this whole
    /// arrangement exists to avoid.
    private func advanceFilm() {
        let time = AnimationClock.shared.time
        let scale = window?.backingScaleFactor ?? 2

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

        // Local, so the three loops below share one lookup and one comparison
        // rather than three copies of them.
        func advance(
            url: URL?,
            box: CGRect,
            decodeWidth: CGFloat,
            key: FilmSlot,
            rowOrigin: CGPoint
        ) {
            guard let url else { return }
            let filmKey = AnimatedImageStore.Key(
                url: url, maximumPixelSize: Int((decodeWidth * scale).rounded(.up))
            )
            guard let film = AnimatedImageStore.shared.cached(filmKey) else { return }
            let next = film.index(at: time)
            guard shownFilmFrames[key] != next else { return }
            shownFilmFrames[key] = next
            setNeedsDisplay(box.offsetBy(dx: rowOrigin.x, dy: rowOrigin.y))
        }

        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            let frame = rowFrame(at: index)
            let origin = CGPoint(x: frame.minX, y: frame.minY)
            for (slot, offset) in zip(row.stickers, row.stickers.indices)
            where slot.isAnimated {
                advance(
                    url: slot.url,
                    box: slot.rect,
                    decodeWidth: slot.rect.width,
                    key: FilmSlot(messageID: row.id, kind: .sticker, index: offset),
                    rowOrigin: origin
                )
            }
            for (offset, slot) in row.attachments.enumerated() where slot.isAnimated {
                advance(
                    url: slot.url,
                    box: slot.rect,
                    decodeWidth: slot.decodeWidth,
                    key: FilmSlot(messageID: row.id, kind: .attachment, index: offset),
                    rowOrigin: origin
                )
            }
            if let block = row.textBlock {
                let textOrigin = CGPoint(
                    x: origin.x + row.textOrigin.x,
                    y: origin.y + row.textOrigin.y
                )
                for (offset, entry) in block.emojiRects.enumerated()
                where entry.emoji.isAnimated {
                    advance(
                        url: entry.emoji.id.flatMap {
                            CDN.emoji(id: $0, animated: true, side: entry.rect.width)
                        },
                        box: entry.rect,
                        decodeWidth: entry.rect.width,
                        key: FilmSlot(messageID: row.id, kind: .emoji, index: offset),
                        rowOrigin: textOrigin
                    )
                }
            }
            var embedImage = 0
            for embed in row.embeds {
                for slot in embed.images {
                    defer { embedImage += 1 }
                    guard slot.isAnimated else { continue }
                    advance(
                        url: slot.url,
                        box: slot.rect,
                        decodeWidth: slot.decodeWidth,
                        key: FilmSlot(messageID: row.id, kind: .embed, index: embedImage),
                        rowOrigin: origin
                    )
                }
            }
            for (offset, slot) in row.reactions.enumerated() where slot.emoji.isAnimated {
                advance(
                    url: slot.imageURL,
                    box: slot.glyphRect,
                    decodeWidth: TimelineMetrics.reactionGlyphSide,
                    key: FilmSlot(messageID: row.id, kind: .reaction, index: offset),
                    rowOrigin: origin
                )
            }
        }

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

    /// The clock holds a closure over this view, so leaving the window has to
    /// release it — a canvas that outlives its window as a clock subscriber is a
    /// display link running for a transcript nobody can see.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshStickerAnimation()
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
        if frame != newFrame {
            frame = newFrame
            needsDisplay = true
        }
        // The size is the half that can introduce a scale; `setBoundsOrigin`
        // provably cannot, which is why the two are never assigned together.
        if bounds.size != newFrame.size {
            setBoundsSize(newFrame.size)
            needsDisplay = true
        }
        if bounds.origin != newBounds.origin {
            setBoundsOrigin(newBounds.origin)
            // What is visible has changed, and with it whether anything on
            // screen moves — or might, on its own.
            refreshStickerAnimation()
            refreshAmbient()
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
        if abs(previousWidth - newSize.width) >= 1 {
            onWidthChange?(newSize.width)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
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
                let row = rows[index]
                var state = TimelineRowPainter.State()
                // **The preference, then the pointer.** Always-on timestamps are
                // a `TimelineSettings` field and reach the canvas through the
                // presentation revision, which is what invalidates every cached
                // row when it changes — a read of `AppSettings` here would be the
                // painter reading a value its cache cannot see (§1).
                state.showsGutterTimestamp = alwaysShowsTimestamps
                if hoveredRow == index, !isScrolling {
                    state.isHovered = true
                    state.showsGutterTimestamp = true
                }
                state.animationTime = AnimationClock.shared.time
                if case .message(let message) = row.kind {
                    state.avatarFrame = avatarFilm.avatarFrame(forRow: message.id.rawValue)
                    state.decorationFrame = avatarFilm.decorationFrame(
                        forRow: message.id.rawValue
                    )
                    if !burstEffects.isEmpty {
                        state.burstEffects = burstEffects.showing(on: message.id)
                    }
                }
                state.playingPreviewURL = playingPreview
                if let messageID = row.messageID {
                    state.isHighlighted = messageID == highlightedMessageID
                    // A set lookup per visible row, and only for a row that
                    // carries a message at all.
                    state.isBookmarked = bookmarkedMessageIDs.contains(messageID)
                    state.revealedSpoilers = revealedSpoilers[messageID] ?? []
                    state.revealedAttachments = revealedAttachments[messageID] ?? []
                    if hoveredRow == index {
                        state.hoveredComponent = hoveredComponent
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
                if case .message(let message) = row.kind,
                   let invite = message.activityInvite {
                    let application = invite.source.applicationID
                    state.activityAccent = activityAccents[application]
                    state.activityInviteStatus = activityInviteStatuses[application]?.line
                    state.activityInviteIsJoined =
                        activityInviteStatuses[application]?.isJoined ?? false
                }
                var preparedName: DisplayNameEffectPainter.Prepared?
                if state.isHovered, case .message(let message) = row.kind,
                   message.isRunHead, message.authorStyle != nil
                {
                    preparedName = styledAuthorName(for: message)
                    state.playsNameEffect = playsNameEffects
                }
                if state.isHovered, playsNameEffects {
                    state.nameGradientPhase = nameGradientPhase
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
        guard let nameStyle = row.authorStyle else { return nil }
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

    /// The rows currently inside the canvas's window, as an index range.
    func visibleRowRange() -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = rowIndex(at: bounds.minY) ?? 0
        var last = first
        while last < rows.count, offsets[last] < bounds.maxY { last += 1 }
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
        applyCursor(nil)
        hoveredComponent = nil
        hoveredBurst = nil
        publishReactionHover(nil)
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
        guard let index = rowIndex(at: point.y), rows.indices.contains(index) else { return }
        // The whole marker is its control: it is one band with one meaning.
        if case .topicMarker = rows[index].kind {
            onOpenTopicMarker?()
            return
        }
        guard case .message(let row) = rows[index].kind else { return }

        switch target(in: row, at: point, rowIndex: index) {
        case .spoiler(let spoilerIndex):
            revealedSpoilers[row.id, default: []].insert(spoilerIndex)
            invalidateRow(index)
        case .attachment(let attachmentIndex, let isHidden):
            // The first click on a spoiler uncovers it and stops there. Opening
            // it full-screen in the same press would show the picture to the
            // room before the reader had decided to.
            guard !isHidden else {
                revealedAttachments[row.id, default: []].insert(attachmentIndex)
                invalidateRow(index)
                return
            }
            onOpenAttachment?(row.id, attachmentIndex, row.attachments.map(\.decodeWidth))
        case .favoriteGIF(let attachmentIndex):
            guard let gif = row.attachments[attachmentIndex].favorite else { return }
            onToggleFavoriteGIF?(gif)
            invalidateRow(index)
        case .previewClip(let url):
            onTogglePreview?(url)
        case .openMusicPlayer(let card, let rect):
            DiagnosticLog.trace(
                "spotify", "open chip hit \(card.key) wired=\(onOpenMusicPlayer != nil)"
            )
            onOpenMusicPlayer?(card, rect)
        case .favoriteEmbedGIF(let embedIndex):
            guard row.embeds.indices.contains(embedIndex),
                  let gif = row.embeds[embedIndex].favorite
            else { return }
            onToggleFavoriteGIF?(gif)
            invalidateRow(index)
        case .link(let destination, let rect):
            onOpenLink?(destination, rect)
        case .emoji(let emoji, let rect):
            onOpenEmoji?(emoji, rect)
        case .sticker(let sticker, let rect):
            onOpenSticker?(sticker, rect)
        case .person(let userID, let rect):
            onOpenProfile?(userID, rect)
        case .component(let url, let customID, _):
            // A disabled control consumes the click and does nothing, which is
            // what a disabled control is. A live one is exactly one of the two:
            // a link opens, an action posts an interaction.
            if let url {
                onOpenLink?(.url(url), .zero)
            } else if let customID {
                onPressComponent?(row.id, customID)
            }
        case .dismissEphemeral:
            onDismissEphemeral?(row.id)
        case .pollAnswer(let answerID, _):
            if let answerID { onVote?(row.id, answerID) }
        case .activityInvite(let origin):
            // `.zero` means the click landed on the card but not on the button.
            if origin != .zero { onPlayActivity?(row.id) }
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
        case .replyHeader(let target):
            // A strip with nothing behind it still swallows the click: falling
            // through would open the profile of whoever is underneath.
            if let target { onOpenReplyTarget?(target) }
        case nil:
            if event.clickCount == 2 { onActivateMessage?(row.id) }
        }
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
        /// The star on a GIF. Ahead of the picture in the hit test, because it
        /// sits inside it and the picture would otherwise swallow every press.
        case favoriteGIF(index: Int)
        /// The same star, on a GIF that arrived as an unfurled link rather than
        /// as a file. A separate case because the two index different arrays.
        case favoriteEmbedGIF(index: Int)
        /// The Preview chip on a music card.
        case previewClip(URL)
        /// The Open chip, which raises Spotify's own player. Carries the card's
        /// rect so the panel can be anchored to it — §1.
        case openMusicPlayer(SpotifyUnfurl, CGRect)
        case link(MessageText.LinkTarget, CGRect)
        case emoji(EmojiRef, CGRect)
        case sticker(StickerRef, CGRect)
        case person(UserID, CGRect)
        /// A button an app attached. Carries its origin in row space so the
        /// painter can light the one under the pointer.
        case component(url: String?, customID: String?, origin: CGPoint)
        case dismissEphemeral(origin: CGPoint)
        /// One answer in a poll. `answerID` is nil where the poll cannot be
        /// voted in — the row still swallows the click rather than letting it
        /// fall through to whatever is beneath.
        case pollAnswer(answerID: Int?, origin: CGPoint)
        /// The Play button on an activity invitation. Carries its origin in row
        /// space so the painter can light it, exactly as a component button
        /// does.
        case activityInvite(origin: CGPoint)
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
        /// The quoted line above a reply. Carries where to go, or nil when the
        /// quoted message is gone — which still swallows the click, because a
        /// strip that says "original message was deleted" is not a hole in the
        /// row.
        case replyHeader(MessageID?)
    }

    private func target(in row: MessageRow, at point: CGPoint, rowIndex index: Int) -> Target? {
        let frame = rowFrame(at: index)
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        // The quoted line sits above the author line and overlaps nothing, so
        // it is tested first and costs one rect containment on a reply and a
        // nil check on everything else.
        if let header = row.replyHeader, header.rect.contains(local) {
            return .replyHeader(header.targetID)
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
            for (spoilerIndex, rect) in block.spoilerRects.enumerated()
            where !revealed.contains(spoilerIndex) && rect.contains(inBlock) {
                return .spoiler(spoilerIndex)
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

        // Every button is a hit, live or not: a dead one still has to swallow
        // the click rather than letting it fall through to whatever is beneath.
        for slot in row.components where slot.rect.contains(local) {
            return .component(url: slot.url, customID: slot.customID, origin: slot.rect.origin)
        }

        // The whole card is a hit, not only the button: a click anywhere on it
        // must not fall through to the row beneath, and the button is the only
        // part of it that does anything.
        if let invite = row.activityInvite, invite.rect.contains(local) {
            return .activityInvite(
                origin: invite.buttonRect.contains(local) ? invite.buttonRect.origin : .zero
            )
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

        let revealedHere = revealedAttachments[row.id] ?? []
        for (attachmentIndex, slot) in row.attachments.enumerated()
        where slot.rect.contains(local) {
            let isHidden = slot.isSpoiler && !revealedHere.contains(attachmentIndex)
            // The star, before the picture it is drawn on. A spoiler still
            // covered has no star to press: the first click uncovers.
            if slot.favorite != nil, !isHidden, slot.favoriteRect.contains(local) {
                return .favoriteGIF(index: attachmentIndex)
            }
            return .attachment(index: attachmentIndex, isHidden: isHidden)
        }

        if let chip = row.threadChip, chip.rect.contains(local) {
            return .threadChip(chip.targetID, origin: chip.rect.origin)
        }

        for slot in row.reactions where slot.rect.contains(local) {
            return .reaction(slot.emoji, kind: slot.kind, origin: slot.rect.origin)
        }

        for slot in row.reactionControls where slot.rect.contains(local) {
            switch slot.kind {
            case .addReaction:
                return .addReaction(rect: slot.rect)
            case .bookmark:
                return .bookmark(origin: slot.rect.origin)
            }
        }

        // The face, then the name. Both open the same card, and both are things
        // a reader points at when they want to know who somebody is.
        if let avatarRect = row.avatarRect, avatarRect.contains(local) {
            return .person(
                row.authorID,
                avatarRect.offsetBy(dx: frame.minX, dy: frame.minY)
            )
        }
        if row.isRunHead, row.authorRect.contains(local) {
            return .person(
                row.authorID,
                row.authorRect.offsetBy(dx: frame.minX, dy: frame.minY)
            )
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
        guard bounds.contains(point) else { return nil }
        let index = rowIndex(at: point.y)
        if let current = hoveredRow, current != index, rows.indices.contains(current),
           rows[current].isSelectable,
           TimelineMetrics.actionBarRegion(inRow: rowFrame(at: current)).contains(point)
        {
            return current
        }
        return index
    }

    private func updateHover(at point: CGPoint) {
        let index = hoveredIndex(at: point)

        // The pointing hand and the lit button, resolved from the same function
        // the click uses. Bounded work: one row's rectangles, and only while
        // nothing is scrolling.
        var cursor: NSCursor?
        var component: CGPoint?
        var attachment: Int?
        var embed: Int?
        var burst: (key: SuperReactionEffects.Key, slot: ReactionSlot, row: MessageRow)?
        var reaction: ReactionHover?
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
            attachment = row.attachments.firstIndex { $0.rect.contains(local) }
            // The same rule for an unfurled GIF, and only for the embeds that
            // have a star at all — a card the pointer crosses has nothing to
            // reveal, so it must not claim the hover from the picture below it.
            embed = row.embeds.firstIndex {
                $0.favorite != nil && $0.rect.contains(local)
            }
            switch target(in: row, at: point, rowIndex: index) {
            case .component(let url, let customID, let origin):
                component = origin
                cursor = url == nil && customID == nil ? nil : .pointingHand
            case .dismissEphemeral(let origin):
                component = origin
                cursor = .pointingHand
            case .pollAnswer(let answerID, let origin):
                component = origin
                cursor = answerID == nil ? nil : .pointingHand
            case .activityInvite(let origin):
                component = origin
                cursor = origin == .zero ? nil : .pointingHand
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
            case .bookmark(let origin):
                component = origin
                cursor = .pointingHand
            case .threadChip(_, let origin):
                // The origin is published so the painter lights the chip the
                // pointer is on, exactly as a reaction chip does.
                component = origin
                cursor = .pointingHand
            case .replyHeader(let target):
                // A quote with nothing behind it swallows the click and goes
                // nowhere, so it must not offer a hand that says it does.
                cursor = target == nil ? nil : .pointingHand
            case .favoriteGIF:
                cursor = .pointingHand
            case .favoriteEmbedGIF, .previewClip, .openMusicPlayer:
                cursor = .pointingHand
            case .some:
                cursor = .pointingHand
            case nil:
                break
            }
        } else if let index, rows.indices.contains(index), case .topicMarker = rows[index].kind {
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

        // A write of an equal value still costs a redraw request, and the
        // pointer generates these at event rate.
        let rowChanged = index != hoveredRow
        let componentChanged = component != hoveredComponent
        let attachmentChanged = attachment != hoveredAttachment
        let embedChanged = embed != hoveredEmbed
        guard rowChanged || componentChanged || attachmentChanged || embedChanged else { return }
        let previous = hoveredRow
        hoveredRow = index
        hoveredComponent = component
        hoveredAttachment = attachment
        hoveredEmbed = embed
        if rowChanged { invalidateRow(previous) }
        invalidateRow(index)
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
            guard AnimationClock.playsAnimatedEmoji, !isScrolling,
                  let index = hoveredRow, rows.indices.contains(index),
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
            onHoverMessage(nil, .zero)
            return
        }
        let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        onHoverMessage(row.id, rowFrame(at: index).offsetBy(dx: -origin.x, dy: -origin.y))
    }

    /// Tells the window which reaction chip the pointer rests on. Equal writes
    /// are dropped here: the pointer moves at event rate and the answer
    /// changes only at a chip's edge.
    private func publishReactionHover(_ hover: ReactionHover?) {
        guard hover != hoveredReaction else { return }
        hoveredReaction = hover
        onHoverReaction?(hover)
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

    override func accessibilityChildren() -> [Any]? {
        let range = visibleRowRange()
        return range.compactMap { index -> NSAccessibilityElement? in
            guard case .message(let row) = rows[index].kind else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(row.accessibilityLabel)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
            return element
        }
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
