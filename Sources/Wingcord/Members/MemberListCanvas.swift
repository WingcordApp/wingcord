import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// The member list, drawn.
///
/// The same virtualisation as the transcript — a viewport-sized canvas inside a
/// full-height document — for the same reason: a five-hundred-member roster is
/// five hundred rows of avatar, name, badges and activity line, and composing
/// them as views is several thousand view nodes for the forty a column shows.
///
/// It is simpler than the transcript in exactly one way that matters: **row
/// heights are fixed**, so there is no text layout in the height calculation and
/// the offset table is arithmetic rather than measurement. That is what lets a
/// presence flush re-run the whole list in microseconds.
final class MemberListCanvas: NSView {
    private(set) var rows: [MemberRow] = []
    private(set) var offsets: [CGFloat] = [0]
    var style: MessageTextStyle

    private var hoveredRow: Int?
    private var trackingArea: NSTrackingArea?
    /// See `apply(isCovered:)`.
    private var isCovered = false

    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue, isScrolling, hoveredRow != nil else { return }
            let previous = hoveredRow
            hoveredRow = nil
            invalidateRow(previous)
            updatePlatePlayback()
        }
    }

    /// Whether a nameplate is allowed to move.
    ///
    /// Reduce Motion parks it on the still, which is the loop's own first frame
    /// — the preference is about movement, and the plate is part of somebody's
    /// identity rather than decoration the app chose to add.
    var animatesPlate = true {
        didSet {
            guard animatesPlate != oldValue else { return }
            updatePlatePlayback()
        }
    }

    /// The pointer moved to a different row.
    ///
    /// The coordinator re-checks what the visible rows need when this fires —
    /// see `MemberListView`, which explains why a settled list otherwise has no
    /// moment at which a dropped picture can come back.
    var onHoveredRowChange: (() -> Void)?

    var onOpenProfile: ((UserID, CGRect) -> Void)?
    /// A right-click on a person. Raises the actions rather than the card.
    var onOpenMenu: ((UserID, CGRect) -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?

    var contentHeight: CGFloat { offsets[offsets.count - 1] }

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
        setAccessibilityLabel("Members")
        adoptAvatarFilm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        // **Not belt and braces.** The clock holds the subscription, not this
        // view — its closure keeps only a weak reference — so a canvas released
        // without `tearDown` leaves an entry the clock can never drop, and its
        // display link then runs at twenty-four frames a second for the life of
        // the process with nobody to call.
        MainActor.assumeIsolated { AnimationClock.shared.unsubscribe(playToken) }
    }

    /// Releases the clock and anything in flight. Called by the coordinator that
    /// owns this view; `deinit` covers the case where nobody does.
    func tearDown() {
        onHoveredRowChange = nil
        plateTask?.cancel()
        plateTask = nil
        plateFilm = nil
        plateKey = nil
        avatarFilm.onFrameChange = nil
        avatarFilm.cancel()
        unsubscribeFromClock()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @discardableResult
    func apply(rows: [MemberRow]) -> CGFloat {
        self.rows = rows
        offsets.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(rows.count + 1)
        var running: CGFloat = 0
        offsets.append(0)
        for row in rows {
            running += row.height
            offsets.append(running)
        }
        if let hoveredRow, hoveredRow >= rows.count { self.hoveredRow = nil }
        // Somebody may have started or stopped typing in this rebuild, which is
        // the only thing here that moves without the pointer.
        defer { refreshClock() }
        // The row under the pointer may now be a different person — a presence
        // flush re-runs this list — so the film has to be re-resolved rather
        // than left playing on whoever moved into that slot.
        updatePlatePlayback()
        needsDisplay = true
        return running
    }

    func rowIndex(at y: CGFloat) -> Int? {
        guard !rows.isEmpty, y >= 0, y < contentHeight else {
            return rows.isEmpty ? nil : (y < 0 ? 0 : rows.count - 1)
        }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func rowFrame(at index: Int) -> CGRect {
        CGRect(x: 0, y: offsets[index], width: bounds.width, height: rows[index].height)
    }

    func visibleRowRange() -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = rowIndex(at: bounds.minY) ?? 0
        var last = first
        while last < rows.count, offsets[last] < bounds.maxY { last += 1 }
        return first..<max(first, last)
    }

    /// Moves the canvas, keeping its coordinate system at 1:1.
    ///
    /// See `TimelineCanvasView.installViewport` for why the order is what it is:
    /// assigning `bounds` while the frame is still a different size defines a
    /// SCALE between the two, and every row then draws stretched or microscopic
    /// until a later pass happens to make the sizes agree.
    func installViewport(frame newFrame: CGRect, bounds newBounds: CGRect) {
        if frame != newFrame {
            frame = newFrame
            needsDisplay = true
        }
        if bounds.size != newFrame.size {
            setBoundsSize(newFrame.size)
            needsDisplay = true
        }
        if bounds.origin != newBounds.origin {
            setBoundsOrigin(newBounds.origin)
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if abs(previousWidth - newSize.width) >= 1 { onWidthChange?(newSize.width) }
    }

    /// Wires the hover film to this view. Called once, from `init`.
    private func adoptAvatarFilm() {
        avatarFilm.onFrameChange = { [weak self] in
            guard let self else { return }
            self.invalidateRow(self.platedRowCache)
            self.refreshClock()
        }
    }

    private func invalidateRow(_ index: Int?) {
        guard let index, rows.indices.contains(index) else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        guard !rows.isEmpty, var index = rowIndex(at: max(0, dirtyRect.minY)) else { return }
        let scale = window?.backingScaleFactor ?? 2
        // Read once per draw rather than per row: it is a clock read, and every
        // row would otherwise ask the same question and get the same answer.
        let phase = gradientPhase

        while index < rows.count, offsets[index] < dirtyRect.maxY {
            let frame = rowFrame(at: index)
            if frame.intersects(dirtyRect) {
                switch rows[index] {
                case .header(let title, let count, let colorValue, let iconURL):
                    MemberRowPainter.drawHeader(
                        title: title,
                        count: count,
                        colorValue: colorValue,
                        iconURL: iconURL,
                        in: frame,
                        context: context,
                        style: style,
                        images: ImageStore.shared,
                        scale: scale
                    )
                case .member(let entry):
                    MemberRowPainter.drawMember(
                        entry,
                        in: frame,
                        context: context,
                        style: style,
                        isHovered: hoveredRow == index && !isScrolling,
                        images: ImageStore.shared,
                        scale: scale,
                        // Resolved here because the registry is main-actor
                        // state; the lookup is a dictionary hit after the first
                        // row that asks for a given face.
                        nameFace: entry.displayNameFont.flatMap {
                            DisplayNameFontRegistry.font($0, size: style.bodyFont.pointSize)
                        },
                        plateFrame: plateImage(forRow: index),
                        avatarFrame: avatarFilm.avatarFrame(forRow: entry.userID.rawValue),
                        decorationFrame: avatarFilm.decorationFrame(
                            forRow: entry.userID.rawValue
                        ),
                        // **Nil unless this is the row under the pointer.**
                        // Discord gates the same thing on hover, and it is what
                        // keeps a roster of gradient roles from being forty
                        // animations at once.
                        typingPhase: typingPhase,
                        gradientPhase: hoveredRow == index ? phase : nil
                    )
                }
            }
            index += 1
        }
    }

    // MARK: The plate under the pointer

    // **One plate moves, and it is the one somebody is looking at.** Every
    // plated row draws its still; the row under the pointer draws a frame of
    // the loop instead. A roster of forty decorated members playing at once
    // would be forty filmstrips resident — half a gigabyte at twelve megabytes
    // each — and a column of moving pictures where a list of people should be.
    //
    // The cost of the one that does play is a **row-sized invalidation per
    // changed frame**: `draw(_:)` already skips every row outside the dirty
    // rect, so a tick repaints one 235x44 rectangle rather than the column.
    // Nothing repaints at all on the ticks that resolve to the frame already on
    // screen, which at twenty-four ticks over a twelve-frame-a-second asset is
    // half of them.

    /// The filmstrip playing on the hovered row.
    private var plateFilm: AnimatedImage?
    /// The slot that film came from. **The identity, not a flag**: a load that
    /// lands after the pointer has moved on belongs to a row that is no longer
    /// there, and drawing it would put one person's plate behind another's name.
    private var plateKey: AnimatedImageStore.Key?
    /// Which frame is on screen, so a tick that resolves to it costs nothing.
    private var plateFrame = -1
    private var plateTask: Task<Void, Never>?
    private var isPlateSubscribed = false

    /// The moving face and decoration on the row under the pointer.
    ///
    /// **The same one-row rule the plate follows, and for a stronger reason.**
    /// A roster draws two hundred faces; a decorated account animates most of
    /// them. `HoverAvatarFilm` holds the pair together and is shared with the
    /// transcript, which has the identical problem one row at a time.
    private let avatarFilm = HoverAvatarFilm()

    /// This view's identity in the shared clock.
    private var playToken: ObjectIdentifier { ObjectIdentifier(self) }

    /// Whose card is open over the roster, if anybody's.
    ///
    /// **A profile pins the plate to its own subject.** A card opens *over* the
    /// row it came from and the pointer lands on the card, not on the row — so
    /// a plate that only plays under the pointer stops the instant the thing
    /// showing it appears. See `platedRow`.
    var profiledUserID: UserID? {
        didSet {
            guard profiledUserID != oldValue else { return }
            let previous = platedRowCache
            updatePlatePlayback()
            // The row that had a frame up and the row that now does are both
            // repainted: neither is the hovered one, so nothing else would.
            if previous != platedRowCache {
                invalidateRow(previous)
                invalidateRow(platedRowCache)
            }
        }
    }

    /// Which row's plate is moving.
    ///
    /// **One film at a time, and the open card outranks the pointer.** §4.6:
    /// a column of them playing at once is a list of artwork rather than a list
    /// of people, so this resolves to a single row — the card's subject where
    /// there is a card, and whatever the pointer is on otherwise.
    private var platedRow: Int? {
        if let profiledUserID {
            return rows.firstIndex { row in
                if case .member(let entry) = row { return entry.userID == profiledUserID }
                return false
            }
        }
        return hoveredRow
    }

    /// The last answer `platedRow` gave, so a change can repaint the row it
    /// left as well as the one it moved to.
    private var platedRowCache: Int?

    /// One frame of the moving plate, for the row that has it.
    private func plateImage(forRow index: Int) -> CGImage? {
        guard index == platedRowCache, !isScrolling, let plateFilm,
              plateFilm.frames.indices.contains(plateFrame)
        else { return nil }
        return plateFilm.frames[plateFrame]
    }

    /// Brings the film in step with whatever the pointer is on.
    ///
    /// **Reconciles a key rather than reacting to an event**, so the four things
    /// that change what should be playing — the pointer moving, a scroll
    /// starting, the roster being rebuilt under the pointer, and Reduce Motion —
    /// all funnel through one decision and none of them can leave the previous
    /// person's plate running.
    private func updatePlatePlayback() {
        platedRowCache = platedRow
        let wanted: AnimatedImageStore.Key? = {
            guard animatesPlate, !isScrolling, let index = platedRowCache,
                  rows.indices.contains(index),
                  case .member(let entry) = rows[index],
                  let url = entry.nameplateAnimatedURL
            else { return nil }
            return NameplateFilm.key(
                url: url,
                width: MemberRowGeometry.nameplateArtWidth,
                scale: window?.backingScaleFactor ?? 2
            )
        }()
        updateAvatarPlayback()
        guard wanted != plateKey else {
            refreshClock()
            return
        }

        plateTask?.cancel()
        plateTask = nil
        // A row that had a frame up has to be told to draw its still again.
        // Three of the four callers invalidate anyway — the pointer moving
        // repaints both rows, a scroll and a rebuild repaint everything — but
        // Reduce Motion coming on mid-hover changes nothing else, and without
        // this the plate would stay frozen on whichever frame it stopped at.
        let hadFilm = plateFilm != nil
        plateFilm = nil
        plateFrame = -1
        plateKey = wanted
        if hadFilm { invalidateRow(platedRowCache) }

        guard let wanted else {
            refreshClock()
            return
        }
        // A cached filmstrip starts on this frame rather than after a hop, so a
        // pointer sweeping back over a row it has already visited does not
        // flicker through the still on the way.
        if let hit = AnimatedImageStore.shared.cached(wanted) {
            install(hit, for: wanted)
            return
        }
        refreshClock()
        // A plate with no animated form is remembered as a still by the store,
        // so this asks once and never again.
        guard !AnimatedImageStore.shared.isKnownStill(wanted) else { return }
        plateTask = Task { [weak self] in
            let film = await AnimatedImageStore.shared.image(for: wanted)
            guard let self, !Task.isCancelled else { return }
            self.install(film, for: wanted)
        }
    }

    private func install(_ film: AnimatedImage?, for key: AnimatedImageStore.Key) {
        guard plateKey == key, let film, film.frameCount > 1 else { return }
        plateFilm = film
        // In step with every other animation on screen, because they all read
        // the same timestamp.
        plateFrame = film.index(at: AnimationClock.shared.time)
        refreshClock()
        invalidateRow(platedRowCache)
    }

    /// Points the hover film at whatever the pointer is on.
    ///
    /// Shares `platedRow`'s answer, so the face, the decoration and the plate
    /// are always the same person's — and an open card outranks the pointer
    /// here too, because the card is where the pointer actually is.
    private func updateAvatarPlayback() {
        let wanted: HoverAvatarFilm.Subject? = {
            guard animatesPlate, !isScrolling, let index = platedRowCache,
                  rows.indices.contains(index),
                  case .member(let entry) = rows[index]
            else { return nil }
            return HoverAvatarFilm.Subject(
                rowID: entry.userID.rawValue,
                avatarURL: entry.avatarURL,
                decorationURL: entry.decorationURL,
                avatarSide: MemberRowGeometry.avatarSide,
                scale: window?.backingScaleFactor ?? 2
            )
        }()
        if avatarFilm.reconcile(to: wanted) { invalidateRow(platedRowCache) }
    }

    /// How long one cycle of the typing dots takes.
    ///
    /// Three dots a third of a cycle apart at this period is the cadence every
    /// typing indicator uses; faster reads as a spinner and slower as a stall.
    private static let typingCycle = 1.4

    /// Whether anybody in the list is typing.
    ///
    /// **Not gated on hover, unlike everything else that moves here.** A typing
    /// indicator is a notification — its whole job is to be noticed without
    /// being pointed at — and it is bounded by its own nature: it expires after
    /// ten seconds and a channel rarely has more than two people mid-sentence.
    private var hasTypingRow: Bool {
        rows.contains { row in
            if case .member(let entry) = row { return entry.isTyping }
            return false
        }
    }

    /// Where in that cycle the dots are, shared by every typing row so they
    /// pulse together rather than each on its own arrival time.
    private var typingPhase: CGFloat {
        let cycle = AnimationClock.shared.time / Self.typingCycle
        return CGFloat(cycle - cycle.rounded(.down))
    }

    /// Repaints the rows whose dots moved. Only those rows, never the column.
    private func invalidateTypingRows() {
        for (index, row) in rows.enumerated() {
            guard case .member(let entry) = row, entry.isTyping else { continue }
            invalidateRow(index)
        }
    }

    /// How long one cycle of an enhanced role's gradient takes.
    ///
    /// Discord's `gradientUsernameAnimation` is `1.5s linear infinite` and its
    /// tile is 100 points wide, so the ramp travels one tile per cycle. The
    /// tile here is the name's own width, which is what makes a short name and
    /// a long one take the same time to come round rather than a short one
    /// flickering.
    private static let gradientCycle = 1.5

    /// Where in that cycle the hovered name is, or nil when nothing is
    /// animating.
    ///
    /// **Only the hovered row**, for the reason the plate film already gives:
    /// forty names scrolling their own ramps is a column of moving text where a
    /// list of people should be, and every one of them is a row-sized
    /// invalidation per frame.
    private var gradientPhase: CGFloat? {
        guard !isScrolling, let hoveredRow, hoveredRow < rows.count,
              case .member(let entry) = rows[hoveredRow], entry.gradient != nil
        else { return nil }
        let cycle = AnimationClock.shared.time / Self.gradientCycle
        return CGFloat(cycle - cycle.rounded(.down))
    }

    /// Starts or stops the one subscription, from one question.
    ///
    /// **Four things ride this clock and any of them can be the only one.** A
    /// hovered row can have a moving plate, a moving face, a moving decoration,
    /// a travelling gradient, all of them or none — and the subscription used
    /// to be started and stopped from four places, which is how a rider that
    /// arrives on its own ends up frozen behind a still one. Asking "is
    /// anything moving" in one place is the same reconcile the plate's own key
    /// already uses, and it is idempotent, so every caller may call it freely.
    private func refreshClock() {
        let wanted = plateFilm != nil || gradientPhase != nil
            || avatarFilm.isPlaying || hasTypingRow
        guard wanted != isPlateSubscribed else { return }
        isPlateSubscribed = wanted
        guard wanted else {
            AnimationClock.shared.unsubscribe(playToken)
            return
        }
        AnimationClock.shared.subscribe(playToken) { [weak self] in
            guard let self else { return }
            let time = AnimationClock.shared.time
            if let plateFilm = self.plateFilm {
                let index = plateFilm.index(at: time)
                if index != self.plateFrame {
                    self.plateFrame = index
                    self.invalidateRow(self.platedRowCache)
                }
            }
            // Nothing happens on the ticks that resolve to the frame already on
            // screen, which at 24 ticks over a 12-frame-a-second asset is half
            // of them.
            if self.avatarFilm.advance(to: time) {
                self.invalidateRow(self.platedRowCache)
            }
            if self.gradientPhase != nil, let hovered = self.hoveredRow {
                self.invalidateRow(hovered)
            }
            self.invalidateTypingRows()
        }
    }

    private func unsubscribeFromClock() {
        guard isPlateSubscribed else { return }
        isPlateSubscribed = false
        AnimationClock.shared.unsubscribe(playToken)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Whether a floating layer is drawn over this canvas. See
    /// `TimelineCanvasView.apply(isCovered:)` — a tracking area is not
    /// occlusion-tested, so without this the roster lights rows and plays
    /// nameplates underneath an open profile card.
    func apply(isCovered: Bool) {
        guard self.isCovered != isCovered else { return }
        self.isCovered = isCovered
        guard isCovered else { return }
        clearHover()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isScrolling, !isCovered else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = bounds.contains(point) ? rowIndex(at: point.y) : nil
        let hoverable = index.flatMap { rows.indices.contains($0) && rows[$0].userID != nil ? $0 : nil }
        guard hoverable != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = hoverable
        invalidateRow(previous)
        invalidateRow(hoverable)
        updatePlatePlayback()
        onHoveredRowChange?()
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// Lets go of the pointer: the same work whether it left the column or a
    /// card was drawn over it.
    private func clearHover() {
        guard hoveredRow != nil else { return }
        let previous = hoveredRow
        hoveredRow = nil
        invalidateRow(previous)
        updatePlatePlayback()
        // Leaving the column counts: the filmstrip that just finished decoding
        // is the allocation most likely to have cost the list its pictures, and
        // the pointer going away is the last moment anything asks.
        onHoveredRowChange?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              rows.indices.contains(index),
              let userID = rows[index].userID
        else { return }
        // The profile card is anchored to the ROW that opened it, so it appears
        // beside that person rather than at the pointer — a card that follows
        // the click reads as a menu.
        //
        // The anchor is expressed in the SwiftUI root's space, which is the
        // hosting view's and not the window's — see `anchorInHostingRoot`.
        onOpenProfile?(userID, anchorInHostingRoot(rowFrame(at: index)))
    }

    /// The person menu, at the row.
    ///
    /// **`rightMouseDown` rather than `menu(for:)`**, for the reason the
    /// transcript's is: AppKit's own path expects an `NSMenu`, and this app's is
    /// a glass surface presented at the window root — a drawn canvas cannot host
    /// a presentation at all.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              rows.indices.contains(index),
              let userID = rows[index].userID
        else {
            super.rightMouseDown(with: event)
            return
        }
        onOpenMenu?(userID, anchorInHostingRoot(rowFrame(at: index)))
    }

    override func accessibilityChildren() -> [Any]? {
        visibleRowRange().compactMap { index -> NSAccessibilityElement? in
            guard case .member(let entry) = rows[index] else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            var label = entry.name
            if entry.isBot { label += ", app" }
            label += ", \(entry.status.label)"
            if let line = entry.activityLine { label += ", \(line.spokenText)" }
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
            return element
        }
    }
}
