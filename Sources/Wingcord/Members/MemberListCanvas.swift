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
/// heights are fixed**, so a row's position is arithmetic over the sections
/// rather than a measurement — see `RosterLayout`. That is what lets a list of
/// a hundred thousand rows cost nothing but its groups.
final class MemberListCanvas: NSView {
    private(set) var roster = Roster.empty
    private var layout = RosterLayout()
    var style: MessageTextStyle

    private var hoveredRow: Int?
    /// Rows past this are somebody else's to draw for now: see `RosterFoldAnimator`.
    var drawingLimit: CGFloat? {
        didSet {
            guard drawingLimit != oldValue else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?
    /// Whether the pointer is over the column at all, which is what sets Active
    /// Now's lobes dancing.
    private var isPointerInside = false
    /// See `apply(isCovered:)`.
    private var isCovered = false

    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue, isScrolling, hoveredRow != nil else { return }
            let previous = hoveredRow
            hoveredRow = nil
            invalidateRow(previous)
            updatePlatePlayback()
            scheduleHoverReport()
        }
    }

    /// Whether a row under the pointer carries the glass buttons. A role's popout
    /// draws these rows with none.
    var showsRowActions = false

    /// The row that stays lit whatever the pointer does: the one whose card or menu
    /// is open, or whose buttons the pointer has moved onto — Discord's `.active`.
    var pinnedUserID: UserID? {
        didSet {
            guard pinnedUserID != oldValue else { return }
            let previous = pinnedRow
            resolvePinnedRow()
            invalidateRow(previous)
            invalidateRow(pinnedRow)
            scheduleHoverReport()
        }
    }
    private var pinnedRow: Int?

    private func resolvePinnedRow() {
        pinnedRow = pinnedUserID.flatMap { userID in
            roster.members.first { $0.value.userID == userID }?.key
        }
    }

    /// Whether a row draws as being pointed at.
    private func isRowLit(_ index: Int) -> Bool {
        index == pinnedRow || (index == hoveredRow && !isScrolling)
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
            refreshDance()
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
    /// A section's heading clicked: fold it, or bring it back.
    var onToggleSection: ((MemberSectionKey) -> Void)?
    /// The row the buttons belong on changed.
    var onHoverRow: ((MemberRowHover?) -> Void)?
    /// Which rooms' headings carry a button now.
    var onVoiceButtons: (([MemberVoiceButton]) -> Void)?
    /// A room's name clicked.
    var onOpenRoom: ((ChannelID) -> Void)?
    /// An Activity card clicked: its popout, beside it.
    var onOpenActivity: ((String, CGRect) -> Void)?
    /// The Activity heading clicked: fold, unfold, or bring back.
    var onToggleActivity: (() -> Void)?
    /// The Activity heading's gear, or a right-click on the heading.
    var onActivityMenu: ((CGRect) -> Void)?

    /// The Activity section at the head of the list, drawn before the first
    /// group — see `MemberActivityBlock`. **Above the roster, not inside it**:
    /// the roster's arithmetic is a fixed height per row, and the section's
    /// cards are a different height again, so the whole roster is simply
    /// pushed down by the section's height.
    private(set) var activity: MemberActivityBlock?
    private var hoveredCard: Int?
    /// Redraws the live cards' clocks once a second, and only while one is
    /// drawn — `INVARIANTS.md`'s rule about clocks: subscribed while needed,
    /// never left running.
    private var liveClock: Timer?

    private var activityHeight: CGFloat { activity?.height ?? 0 }

    var contentHeight: CGFloat { layout.contentHeight + activityHeight }

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
        liveClock?.invalidate()
        liveClock = nil
        onHoveredRowChange = nil
        durationClock?.invalidate()
        durationClock = nil
        danceClock?.invalidate()
        danceClock = nil
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
    func apply(roster: Roster) -> CGFloat {
        self.roster = roster
        layout = RosterLayout(roster, separatesFirst: activity != nil)
        if let hoveredRow, row(at: hoveredRow)?.userID == nil { self.hoveredRow = nil }
        resolvePinnedRow()
        scheduleHoverReport()
        refreshDurationClock()
        refreshDance()
        // Somebody may have started or stopped typing in this rebuild, which is
        // the only thing here that moves without the pointer.
        defer { refreshClock() }
        // The row under the pointer may now be a different person — a presence
        // flush re-runs this list — so the film has to be re-resolved rather
        // than left playing on whoever moved into that slot.
        updatePlatePlayback()
        needsDisplay = true
        return layout.contentHeight
    }

    /// What sits at a row, or nil past the end of the list.
    func row(at index: Int) -> MemberRow? {
        guard index >= 0, index < layout.rowCount else { return nil }
        return layout.row(at: index, in: roster)
    }

    func rowIndex(at y: CGFloat) -> Int? {
        layout.index(at: y - activityHeight)
    }

    func rowFrame(at index: Int) -> CGRect {
        layout.frame(at: index, width: bounds.width).offsetBy(dx: 0, dy: activityHeight)
    }

    // MARK: The Activity section

    /// Takes a new section, answering the list's whole height.
    @discardableResult
    func apply(activity: MemberActivityBlock?) -> CGFloat {
        guard activity != self.activity else { return contentHeight }
        let previousHeight = activityHeight
        let hadActivity = self.activity != nil
        self.activity = activity
        // The first heading under it has a hairline; with nothing above, it doesn't.
        if hadActivity != (activity != nil) {
            layout = RosterLayout(roster, separatesFirst: activity != nil)
        }
        if let hoveredCard, activity?.cards.indices.contains(hoveredCard) != true { self.hoveredCard = nil }
        if previousHeight != activityHeight {
            needsDisplay = true
        } else {
            setNeedsDisplay(CGRect(x: 0, y: 0, width: bounds.width, height: activityHeight))
        }
        updateLiveClock()
        return contentHeight
    }

    private func activityCardFrame(at index: Int) -> CGRect {
        activity?.cardFrame(at: index, width: bounds.width) ?? .zero
    }

    private var activityHeaderFrame: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: MemberActivityGeometry.headerHeight)
    }

    private func updateLiveClock() {
        let hasLive = activity?.cards.contains(where: \.isLive) == true
        if hasLive, liveClock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickLiveCards() }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveClock = timer
        } else if !hasLive {
            liveClock?.invalidate()
            liveClock = nil
        }
    }

    private func tickLiveCards() {
        guard let activity, window != nil else { return }
        for (index, card) in activity.cards.enumerated() where card.isLive {
            let frame = activityCardFrame(at: index)
            if frame.intersects(visibleRect) { setNeedsDisplay(frame) }
        }
    }

    private func drawActivity(_ activity: MemberActivityBlock, in dirtyRect: CGRect, context: CGContext, scale: CGFloat) {
        if activityHeaderFrame.intersects(dirtyRect) {
            MemberActivityPainter.drawHeader(activity, in: activityHeaderFrame, context: context, style: style)
        }
        let now = Date()
        for (index, card) in activity.cards.enumerated() {
            let frame = activityCardFrame(at: index)
            guard frame.intersects(dirtyRect) else { continue }
            MemberActivityPainter.drawCard(
                card,
                in: frame,
                context: context,
                style: style,
                isHovered: hoveredCard == index && !isScrolling,
                images: ImageStore.shared,
                scale: scale,
                now: now
            )
        }
    }

    func visibleRowRange() -> Range<Int> {
        // Through `rowIndex`, which knows the Activity section sits above.
        guard bounds.maxY > activityHeight,
              let first = rowIndex(at: bounds.minY),
              let last = rowIndex(at: bounds.maxY - 0.5)
        else { return 0..<0 }
        return first..<last + 1
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
            // The buttons are placed in the viewport's space, and a row that stays
            // lit through a scroll moves within it.
            scheduleHoverReport()
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
        guard let index, index >= 0, index < layout.rowCount else { return }
        setNeedsDisplay(rowFrame(at: index))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        let scale = window?.backingScaleFactor ?? 2
        if let activity, dirtyRect.minY < activityHeight {
            drawActivity(activity, in: dirtyRect, context: context, scale: scale)
        }
        // Under the rows, a room's wash and what it says at its foot.
        for position in layout.sections.indices {
            guard case .voiceGroup(let group) = layout.sections[position].kind else { continue }
            let frame = layout.sectionFrame(position, width: bounds.width).offsetBy(dx: 0, dy: activityHeight)
            guard frame.intersects(dirtyRect), frame.minY < drawingLimit ?? .infinity else { continue }
            MemberRowPainter.drawVoiceGroupGround(group, in: frame, context: context, style: style)
        }
        guard var index = rowIndex(at: max(activityHeight, dirtyRect.minY)) else { return }
        // Read once per draw rather than per row: it is a clock read, and every
        // row would otherwise ask the same question and get the same answer.
        let phase = gradientPhase
        let now = Date()

        while let row = row(at: index) {
            let frame = rowFrame(at: index)
            guard frame.minY < dirtyRect.maxY, frame.minY < drawingLimit ?? .infinity else { break }
            if frame.intersects(dirtyRect) {
                switch row {
                case .header(let section):
                    MemberRowPainter.drawHeader(
                        section,
                        in: frame,
                        isSeparated: layout.isSeparated(layout.sectionIndex(containing: index)),
                        context: context,
                        style: style,
                        images: ImageStore.shared,
                        scale: scale,
                        dimmedLobe: section.glyph == .activeNow ? dimmedLobe : nil
                    )
                case .placeholder:
                    MemberRowPainter.drawPlaceholder(index: index, in: frame, context: context)
                case .member(let entry):
                    MemberRowPainter.drawMember(
                        entry,
                        in: frame,
                        context: context,
                        style: style,
                        isHovered: isRowLit(index),
                        showsActions: showsRowActions && isRowLit(index),
                        images: ImageStore.shared,
                        scale: scale,
                        now: now,
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

    /// How tall everything under the heading at this row is. See `RosterLayout`.
    func bodyHeight(ofHeadingAt index: Int) -> CGFloat {
        layout.bodyHeight(ofSectionAt: layout.sectionIndex(containing: index))
    }

    /// What's in a stretch of the list, as a picture, whether it's on screen or not:
    /// the rows are arithmetic, and `draw` will draw any of them.
    func renderedImage(of rect: CGRect) -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((rect.width * scale).rounded(.up))
        let height = Int((rect.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.translateBy(x: -rect.minX * scale, y: rect.maxY * scale)
        context.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let limit = drawingLimit
        drawingLimit = nil
        draw(rect)
        drawingLimit = limit
        NSGraphicsContext.current = previous
        return context.makeImage()
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
            return roster.members.first { $0.value.userID == profiledUserID }?.key
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
                  let entry = roster.members[index],
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
                  let entry = roster.members[index]
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
        roster.members.values.contains { $0.isTyping }
    }

    /// Where in that cycle the dots are, shared by every typing row so they
    /// pulse together rather than each on its own arrival time.
    private var typingPhase: CGFloat {
        let cycle = AnimationClock.shared.time / Self.typingCycle
        return CGFloat(cycle - cycle.rounded(.down))
    }

    /// Repaints the rows whose dots moved. Only those rows, never the column.
    private func invalidateTypingRows() {
        for (index, entry) in roster.members where entry.isTyping {
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
        guard !isScrolling, let hoveredRow,
              roster.members[hoveredRow]?.gradient != nil
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
        let rate = wanted ? clockRate : 0
        guard wanted != isPlateSubscribed || rate != subscribedRate else { return }
        isPlateSubscribed = wanted
        subscribedRate = rate
        guard wanted else {
            AnimationClock.shared.unsubscribe(playToken)
            return
        }
        AnimationClock.shared.subscribe(playToken, rate: rate) { [weak self] in
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

    /// The rate the clock was last asked for.
    private var subscribedRate: Double = 0

    /// How often what moves here needs a look: the hovered row's films at
    /// their own fastest frame, and sixty for a travelling gradient.
    private var clockRate: Double {
        if gradientPhase != nil { return 60 }
        var rate = AnimationClock.defaultRate
        if avatarFilm.isPlaying { rate = max(rate, avatarFilm.rate) }
        if let plateFilm { rate = max(rate, 1 / plateFilm.shortestFrame) }
        return rate
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
        refreshDance()
        guard isCovered else { return }
        clearHover()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        refreshDance()
    }

    override func mouseMoved(with event: NSEvent) {
        if !isPointerInside {
            isPointerInside = true
            refreshDance()
        }
        guard !isScrolling, !isCovered else { return }
        let point = convert(event.locationInWindow, from: nil)
        // The Activity section first: it sits above the roster's rows.
        let card = bounds.contains(point) && point.y < activityHeight
            ? activity?.cardIndex(at: point.y)
            : nil
        if card != hoveredCard {
            let previous = hoveredCard
            hoveredCard = card
            if let previous { setNeedsDisplay(activityCardFrame(at: previous)) }
            if let card { setNeedsDisplay(activityCardFrame(at: card)) }
        }
        let index = bounds.contains(point) && point.y >= activityHeight ? rowIndex(at: point.y) : nil
        let hoverable = index.flatMap { candidate in
            // `rowIndex` clamps, so the air under the last row answers with it.
            row(at: candidate)?.userID != nil && rowFrame(at: candidate).contains(point) ? candidate : nil
        }
        let room = roomContaining(point)
        if room != hoveredRoom {
            hoveredRoom = room
            scheduleHoverReport()
        }
        guard hoverable != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = hoverable
        invalidateRow(previous)
        invalidateRow(hoverable)
        updatePlatePlayback()
        onHoveredRowChange?()
        scheduleHoverReport()
    }

    /// The room whose band a point is in.
    private func roomContaining(_ point: CGPoint) -> ChannelID? {
        guard point.y >= activityHeight, let index = rowIndex(at: point.y) else { return nil }
        let position = layout.sectionIndex(containing: index)
        guard case .voiceGroup(let group) = layout.sections[position].kind else { return nil }
        let frame = layout.sectionFrame(position, width: bounds.width).offsetBy(dx: 0, dy: activityHeight)
        return frame.contains(point) ? group.channelID : nil
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshDance()
        clearHover()
    }

    /// Lets go of the pointer: the same work whether it left the column or a
    /// card was drawn over it.
    private func clearHover() {
        if let previous = hoveredCard {
            hoveredCard = nil
            setNeedsDisplay(activityCardFrame(at: previous))
        }
        if hoveredRoom != nil {
            hoveredRoom = nil
            scheduleHoverReport()
        }
        guard hoveredRow != nil else { return }
        let previous = hoveredRow
        hoveredRow = nil
        invalidateRow(previous)
        updatePlatePlayback()
        // Leaving the column counts: the filmstrip that just finished decoding
        // is the allocation most likely to have cost the list its pictures, and
        // the pointer going away is the last moment anything asks.
        onHoveredRowChange?()
        scheduleHoverReport()
    }

    // MARK: The buttons on the hovered row

    private var lastReportedHover: MemberRowHover?
    private var isHoverReportPending = false
    /// The room the pointer is in.
    private var hoveredRoom: ChannelID?
    private var lastVoiceButtons: [MemberVoiceButton] = []

    /// Tells the column which row the buttons belong on — **on the next turn of the
    /// run loop, never now.** Half the things that move it arrive from
    /// `updateNSView`, and a representable never reports state from there
    /// (`INVARIANTS.md`). Several in a row come out as one.
    private func scheduleHoverReport() {
        guard onHoverRow != nil, !isHoverReportPending else { return }
        isHoverReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHoverReportPending = false
            self.reportHover()
        }
    }

    private func reportHover() {
        var hover: MemberRowHover?
        if showsRowActions,
           let index = pinnedRow ?? (isScrolling ? nil : hoveredRow),
           let entry = roster.members[index]
        {
            let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
            hover = MemberRowHover(
                userID: entry.userID,
                rowFrame: rowFrame(at: index).offsetBy(dx: -origin.x, dy: -origin.y),
                isReader: entry.isReader,
                joinableVoiceChannelID: entry.joinableVoiceChannelID
            )
        }
        if hover != lastReportedHover {
            lastReportedHover = hover
            onHoverRow?(hover)
        }
        reportVoiceButtons()
    }

    /// A room's heading has its button while the pointer's in the room, and the
    /// reader's own room always has its Disconnect: Discord's `.joinButton`.
    private func reportVoiceButtons() {
        guard let onVoiceButtons else { return }
        var buttons: [MemberVoiceButton] = []
        if showsRowActions {
            let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
            for index in visibleRowRange() {
                guard case .header(let section)? = row(at: index),
                      case .voiceGroup(let group) = section.kind,
                      group.isReaderIn || (group.canJoin && group.channelID == hoveredRoom)
                else { continue }
                let heading = rowFrame(at: index).offsetBy(dx: -origin.x, dy: -origin.y)
                buttons.append(MemberVoiceButton(
                    channelID: group.channelID,
                    frame: MemberVoiceGroupGeometry.eyebrow(in: heading),
                    isReaderIn: group.isReaderIn,
                    canJoin: group.canJoin
                ))
            }
        }
        guard buttons != lastVoiceButtons else { return }
        lastVoiceButtons = buttons
        onVoiceButtons(buttons)
    }

    // MARK: The clocks a row draws

    /// Moves the times on the lines along — `· 2h` — and only while a row has one:
    /// `INVARIANTS.md`'s rule about clocks, subscribed while needed.
    ///
    /// **Twice a minute, because the shortest thing it says is a minute**, and the
    /// rows it repaints are the few on screen with a time on them.
    private var durationClock: Timer?

    private func refreshDurationClock() {
        let wanted = roster.members.values.contains { $0.line?.since != nil }
        if wanted, durationClock == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickDurations() }
            }
            RunLoop.main.add(timer, forMode: .common)
            durationClock = timer
        } else if !wanted {
            durationClock?.invalidate()
            durationClock = nil
        }
    }

    private func tickDurations() {
        guard window != nil else { return }
        for index in visibleRowRange() where roster.members[index]?.line?.since != nil {
            invalidateRow(index)
        }
    }

    // MARK: Active Now's lobes

    /// Which lobe is dim right now.
    private var dimmedLobe: Int?
    private var danceClock: Timer?
    private var danceStep = 0

    /// Discord's little dance on its Active Now glyph while the pointer is in the
    /// list (`tU`, `763349`). Off under Reduce Motion, and stopped when nothing can
    /// see it — the clock rule again.
    private func refreshDance() {
        let wanted = isPointerInside && animatesPlate && !isCovered
            && roster.sections.contains { $0.glyph == .activeNow }
        if wanted, danceClock == nil {
            danceStep = 0
            let timer = Timer(timeInterval: MemberSectionGlyphs.danceInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickDance() }
            }
            RunLoop.main.add(timer, forMode: .common)
            danceClock = timer
        } else if !wanted, danceClock != nil {
            danceClock?.invalidate()
            danceClock = nil
            setDimmedLobe(nil)
        }
    }

    private func tickDance() {
        danceStep = (danceStep + 1) % MemberSectionGlyphs.danceSteps.count
        setDimmedLobe(MemberSectionGlyphs.danceSteps[danceStep])
    }

    private func setDimmedLobe(_ lobe: Int?) {
        guard lobe != dimmedLobe else { return }
        dimmedLobe = lobe
        guard let heading = roster.sections.first(where: { $0.glyph == .activeNow }) else { return }
        // The glyph's box, not the whole heading: this runs seven times a second.
        setNeedsDisplay(MemberSectionGeometry.glyphRect(in: rowFrame(at: heading.index)))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let activity, point.y < activityHeight {
            if let card = activity.cardIndex(at: point.y) {
                onOpenActivity?(activity.cards[card].id, anchorInHostingRoot(MemberActivityGeometry.plate(in: activityCardFrame(at: card))))
            } else if MemberActivityGeometry.gearRect(in: activityHeaderFrame, canToggle: activity.canToggle)
                .insetBy(dx: -6, dy: -6).contains(point)
            {
                onActivityMenu?(anchorInHostingRoot(MemberActivityGeometry.gearRect(in: activityHeaderFrame, canToggle: activity.canToggle)))
            } else if activity.canToggle {
                onToggleActivity?()
            }
            return
        }
        // `rowIndex` clamps, so the air under the last row answers with it.
        guard let index = rowIndex(at: point.y), rowFrame(at: index).contains(point),
              let row = row(at: index)
        else { return }
        if case .header(let section) = row {
            if section.canCollapse {
                onToggleSection?(section.key)
            } else if case .voiceGroup(let group) = section.kind,
                      point.x >= MemberRowPainter.voiceGroupNameX(in: rowFrame(at: index))
            {
                onOpenRoom?(group.channelID)
            }
            return
        }
        guard let userID = row.userID else { return }
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
        // The heading's menu, on the heading — Discord's context menu there.
        if let activity, point.y < MemberActivityGeometry.headerHeight, activityHeight > 0 {
            onActivityMenu?(anchorInHostingRoot(MemberActivityGeometry.gearRect(in: activityHeaderFrame, canToggle: activity.canToggle)))
            return
        }
        if point.y < activityHeight {
            super.rightMouseDown(with: event)
            return
        }
        guard let index = rowIndex(at: point.y), rowFrame(at: index).contains(point),
              let userID = row(at: index)?.userID
        else {
            super.rightMouseDown(with: event)
            return
        }
        onOpenMenu?(userID, anchorInHostingRoot(rowFrame(at: index)))
    }

    override func accessibilityChildren() -> [Any]? {
        activityAccessibilityChildren() + visibleRowRange().compactMap { index -> NSAccessibilityElement? in
            if case .header(let section)? = row(at: index) {
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.button)
                let name = section.label ?? section.key.storageKey
                element.setAccessibilityLabel(
                    section.canCollapse ? "\(name), \(section.isCollapsed ? "collapsed" : "expanded")" : name
                )
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
                return element
            }
            guard let entry = roster.members[index] else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            var label = entry.name
            if entry.isBot { label += ", app" }
            label += ", \(entry.status.label)"
            if let line = entry.line, !line.spoken.isEmpty { label += ", \(line.spoken)" }
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
            return element
        }
    }
}

extension MemberListCanvas {
    /// The section's heading and its cards, as buttons.
    fileprivate func activityAccessibilityChildren() -> [NSAccessibilityElement] {
        guard let activity else { return [] }
        let heading = NSAccessibilityElement()
        heading.setAccessibilityRole(.button)
        heading.setAccessibilityLabel(
            "\(activity.title)" + (activity.canToggle ? (activity.isHidden ? ", hidden" : activity.isExpanded ? ", expanded" : ", collapsed") : "")
        )
        heading.setAccessibilityParent(self)
        heading.setAccessibilityFrameInParentSpace(
            CGRect(x: 0, y: 0, width: bounds.width, height: MemberActivityGeometry.headerHeight)
        )
        let now = Date()
        let cards = activity.cards.enumerated().map { index, card -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            let chips = card.badges.map { MemberActivityPainter.resolve($0, card: card, now: now).text }
            element.setAccessibilityLabel(([card.name, card.title] + chips).joined(separator: ", "))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(activity.cardFrame(at: index, width: bounds.width))
            return element
        }
        return [heading] + cards
    }
}
