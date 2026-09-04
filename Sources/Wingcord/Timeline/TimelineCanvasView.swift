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
    var contentHeight: CGFloat { offsets[offsets.count - 1] }

    // MARK: Interaction state

    private var hoveredRow: Int?
    /// The origin, in row space, of the button under the pointer.
    ///
    /// Identified by its origin rather than by an index: the index of a button
    /// only means anything beside the array it came from, and the canvas keeps
    /// no such array between passes.
    private var hoveredComponent: CGPoint?
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
            if isScrolling, hoveredRow != nil {
                let previous = hoveredRow
                hoveredRow = nil
                hoveredComponent = nil
                invalidateRow(previous)
                publishHover()
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
    /// A reaction chip was clicked. The reader's own reaction is toggled.
    var onToggleReaction: ((MessageID, EmojiRef) -> Void)?
    /// A reply's quoted line was clicked: go to what it quotes.
    var onOpenReplyTarget: ((MessageID) -> Void)?
    /// The thread chip under a message was clicked: open that thread.
    var onOpenThread: ((ChannelID) -> Void)?
    /// The pointer moved onto, or off, a message row. The rect is in the CLIP
    /// VIEW's space, because what reads it is a floating pill overlaid on the
    /// scroll view rather than anything in document coordinates.
    var onHoverMessage: ((MessageID?, CGRect) -> Void)?
    /// The full menu was asked for — a right-click, or the pill's own button.
    var onOpenMenu: ((MessageID, CGRect) -> Void)?

    private var trackingArea: NSTrackingArea?

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
        enum Kind: UInt8 { case sticker, attachment, embed }
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
        needsDisplay = true
        refreshStickerAnimation()
        return running
    }

    /// Subscribes to the clock while something on screen is moving, and stops
    /// the moment nothing is.
    ///
    /// **Three kinds of moving picture, one subscription.** A sticker, a GIF
    /// attachment and a GIF a link unfurled into are all filmstrips drawn by the
    /// same painter on the same clock, and giving each its own subscription
    /// would be three display-link callbacks for one repaint.
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
        guard isAnimatingStickers else { return }
        isAnimatingStickers = false
        AnimationClock.shared.unsubscribe(animationToken)
        shownFilmFrames.removeAll(keepingCapacity: false)
    }

    private var hasVisibleFilm: Bool {
        for index in visibleRowRange() {
            guard case .message(let row) = rows[index].kind else { continue }
            if row.stickers.contains(where: \.isAnimated) { return true }
            if row.attachments.contains(where: \.isAnimated) { return true }
            for embed in row.embeds where embed.images.contains(where: \.isAnimated) {
                return true
            }
        }
        return false
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
        }
    }

    /// The clock holds a closure over this view, so leaving the window has to
    /// release it — a canvas that outlives its window as a clock subscriber is a
    /// display link running for a transcript nobody can see.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshStickerAnimation()
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
            // screen moves.
            refreshStickerAnimation()
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

        while index < rows.count, offsets[index] < dirtyRect.maxY {
            let frame = rowFrame(at: index)
            if frame.intersects(dirtyRect) {
                let row = rows[index]
                var state = TimelineRowPainter.State()
                if hoveredRow == index, !isScrolling {
                    state.isHovered = true
                    state.showsGutterTimestamp = true
                }
                state.animationTime = AnimationClock.shared.time
                if let messageID = row.messageID {
                    state.isHighlighted = messageID == highlightedMessageID
                    state.revealedSpoilers = revealedSpoilers[messageID] ?? []
                    state.revealedAttachments = revealedAttachments[messageID] ?? []
                    if hoveredRow == index { state.hoveredComponent = hoveredComponent }
                }
                if case .message(let message) = row.kind,
                   let invite = message.activityInvite {
                    let application = invite.source.applicationID
                    state.activityAccent = activityAccents[application]
                    state.activityInviteStatus = activityInviteStatuses[application]?.line
                    state.activityInviteIsJoined =
                        activityInviteStatuses[application]?.isJoined ?? false
                }
                TimelineRowPainter.draw(
                    row: row,
                    in: frame,
                    context: context,
                    style: style,
                    state: state,
                    images: images,
                    scale: scale
                )
            }
            index += 1
        }
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
        guard !isScrolling else { return }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        applyCursor(nil)
        hoveredComponent = nil
        guard hoveredRow != nil else { return }
        let previous = hoveredRow
        hoveredRow = nil
        invalidateRow(previous)
        publishHover()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else { return }

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
        case .reaction(let emoji, _):
            onToggleReaction?(row.id, emoji)
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
        /// A reaction chip. Clicking it adds or removes the reader's own.
        /// Carries its origin in row space so the painter can light the one
        /// under the pointer — identified by origin, not index, for the reason
        /// `hoveredComponent` is.
        case reaction(EmojiRef, origin: CGPoint)
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

        let revealedHere = revealedAttachments[row.id] ?? []
        for (attachmentIndex, slot) in row.attachments.enumerated()
        where slot.rect.contains(local) {
            return .attachment(
                index: attachmentIndex,
                isHidden: slot.isSpoiler && !revealedHere.contains(attachmentIndex)
            )
        }

        if let chip = row.threadChip, chip.rect.contains(local) {
            return .threadChip(chip.targetID, origin: chip.rect.origin)
        }

        for slot in row.reactions where slot.rect.contains(local) {
            return .reaction(slot.emoji, origin: slot.rect.origin)
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
        if let index, rows.indices.contains(index), case .message(let row) = rows[index].kind {
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
            case .reaction(_, let origin):
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
            case .some:
                cursor = .pointingHand
            case nil:
                break
            }
        }
        applyCursor(cursor)

        // A write of an equal value still costs a redraw request, and the
        // pointer generates these at event rate.
        let rowChanged = index != hoveredRow
        let componentChanged = component != hoveredComponent
        guard rowChanged || componentChanged else { return }
        let previous = hoveredRow
        hoveredRow = index
        hoveredComponent = component
        if rowChanged { invalidateRow(previous) }
        invalidateRow(index)
        if rowChanged { publishHover() }
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
