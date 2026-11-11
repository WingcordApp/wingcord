import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - The canvas

/// The picker's grid, drawn.
///
/// The same virtualisation as the transcript and the member list — a
/// viewport-sized canvas inside a full-height document — for a stronger reason
/// than either: the emoji tab is nineteen hundred Unicode glyphs plus every
/// custom emoji in the account, which on a real one is tens of thousands. As
/// views that is tens of thousands of nodes with a button each; drawn, it is the
/// forty cells a viewport shows.
///
/// Cell heights are fixed, so the offset table is arithmetic and hit-testing is
/// a binary search — see `ExpressionGridLayout`.
final class ExpressionGridCanvas: NSView {
    private(set) var sections: [ExpressionSection] = []
    private(set) var layout = ExpressionGridLayout(sections: [], metrics: .init(itemSize: 1, spacing: 0, columns: 1))

    /// The section whose heading the floating pill is showing.
    ///
    /// The canvas skips that heading, so exactly one copy of it is on screen.
    /// Without this the two are both drawn — coincident at rest, and visibly
    /// apart during the push, where the pinned copy is held at the line while
    /// the canvas's own keeps sliding up behind the transparent chrome.
    var pinnedSection: Int? {
        didSet {
            guard pinnedSection != oldValue else { return }
            invalidateHeader(oldValue)
            invalidateHeader(pinnedSection)
        }
    }

    /// The cell under the pointer, as (section, item).
    private var hovered: (section: Int, item: Int)?
    private var trackingArea: NSTrackingArea?

    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue, isScrolling, hovered != nil else { return }
            clearHover()
        }
    }

    var onPick: ((ExpressionItem) -> Void)?
    /// Whether a cell is starred, and how to star it — the right-click menu's
    /// Favorite. Nil where a picker offers no stars.
    var isFavorite: ((ExpressionItem) -> Bool)?
    var onToggleFavorite: ((ExpressionItem) -> Void)?
    var onWidthChange: ((CGFloat) -> Void)?
    var onHover: ((ExpressionHover?) -> Void)?

    /// Whether moving art may move. Off, every cell draws its first frame — the
    /// same picture, without the clock or the filmstrips.
    var animates = true {
        didSet {
            guard animates != oldValue else { return }
            updateClock()
            needsDisplay = true
        }
    }

    /// Whether anything on screen has a filmstrip to run. Recomputed when the
    /// viewport moves, never per frame.
    private var hasAnimatedCellsVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
        layer?.drawsAsynchronously = false
        postsFrameChangedNotifications = true
        setAccessibilityElement(true)
        setAccessibilityRole(.grid)
        setAccessibilityLabel("Expressions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @discardableResult
    func apply(sections: [ExpressionSection], metrics: ExpressionGridMetrics) -> CGFloat {
        self.sections = sections
        layout = ExpressionGridLayout(sections: sections, metrics: metrics)
        if let hovered, !isValid(hovered) { self.hovered = nil }
        needsDisplay = true
        return layout.contentHeight
    }

    private func isValid(_ cell: (section: Int, item: Int)) -> Bool {
        sections.indices.contains(cell.section)
            && sections[cell.section].items.indices.contains(cell.item)
    }

    /// See `TimelineCanvasView.installViewport`: assigning `bounds` while the
    /// frame is still a different size defines a SCALE between the two, and
    /// every cell then draws stretched until a later pass happens to make the
    /// sizes agree. Frame first, then size, then origin.
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

    /// The rows a repaint or a prefetch has to walk.
    func visibleRowRange() -> Range<Int> { layout.rowRange(in: bounds) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !sections.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let images = ImageStore.shared
        // One timestamp for the whole pass, so every cell shows the same
        // moment — read from the app's single clock rather than from `now`,
        // which would drift each cell against the others.
        let time = animates ? AnimationClock.shared.time : nil

        for index in layout.rowRange(in: dirtyRect) {
            let row = layout.rows[index]
            let section = sections[row.section]

            guard let firstItem = row.firstItem else {
                // Drawn at its natural position, unless the floating pill is
                // already showing this one.
                guard row.section != pinnedSection else { continue }
                ExpressionGridPainter.drawHeader(
                    section,
                    in: layout.rowFrame(at: index, width: bounds.width),
                    images: images,
                    scale: scale,
                    context: context
                )
                continue
            }

            for column in 0..<row.count {
                let item = section.items[firstItem + column]
                let cell = layout.itemFrame(row: index, column: column)
                let isHovered = hovered.map {
                    $0.section == row.section && $0.item == firstItem + column
                } ?? false
                ExpressionGridPainter.drawItem(
                    item,
                    in: cell,
                    isHovered: isHovered,
                    isDimmed: section.isLocked || item.isLocked,
                    images: images,
                    scale: scale,
                    time: time,
                    context: context
                )
            }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isScrolling else { return }
        let point = convert(event.locationInWindow, from: nil)
        let cell = layout.item(at: point)
        guard cell?.section != hovered?.section || cell?.item != hovered?.item else { return }
        let previous = hovered
        hovered = cell.flatMap { isValid($0) ? $0 : nil }
        invalidate(previous)
        invalidate(hovered)
        reportHover()
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = layout.item(at: point), isValid(cell) else { return }
        // **A locked section is dimmed AND unpickable.** Dimming is a statement
        // and a click is an action: a cell that looks unavailable and still
        // types `<:blobcat:123>` into the draft sends a message that arrives as
        // literal text, which is worse than either honest answer.
        let item = sections[cell.section].items[cell.item]
        guard !sections[cell.section].isLocked, !item.isLocked else { return }
        onPick?(item)
    }

    /// Discord's right-click on a picker cell: Favorite, or Remove from
    /// Favorites. A locked cell can be starred too — a star is about the
    /// emoji, not about this channel.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onToggleFavorite, let isFavorite else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = layout.item(at: point), isValid(cell) else { return nil }
        let item = sections[cell.section].items[cell.item]
        let menu = NSMenu()
        let starred = isFavorite(item)
        let entry = NSMenuItem(
            title: starred ? "Remove from Favorites" : "Favorite",
            action: #selector(toggleFavoriteFromMenu(_:)),
            keyEquivalent: ""
        )
        entry.image = NSImage(systemSymbolName: starred ? "star.slash" : "star", accessibilityDescription: nil)
        entry.target = self
        entry.representedObject = ExpressionMenuItem(item: item)
        menu.addItem(entry)
        return menu
    }

    @objc private func toggleFavoriteFromMenu(_ sender: NSMenuItem) {
        guard let boxed = sender.representedObject as? ExpressionMenuItem else { return }
        onToggleFavorite?(boxed.item)
    }

    /// Repaints one heading's row and nothing else — 26 points, a few times per
    /// scroll, rather than the whole canvas.
    private func invalidateHeader(_ section: Int?) {
        guard let section, section < layout.headerRows.count else { return }
        setNeedsDisplay(layout.rowFrame(at: layout.headerRows[section], width: bounds.width))
    }

    private func clearHover() {
        guard hovered != nil else { return }
        let previous = hovered
        hovered = nil
        invalidate(previous)
        reportHover()
    }

    /// Hands the footer what is under the pointer.
    ///
    /// Only on a change, and a hover changes at a person's pace — this is the
    /// one place a canvas write crosses back into SwiftUI, and it must not
    /// become a per-frame one.
    private func reportHover() {
        guard let onHover else { return }
        guard let hovered, isValid(hovered) else {
            onHover(nil)
            return
        }
        let section = sections[hovered.section]
        let item = section.items[hovered.item]
        onHover(ExpressionHover(
            art: item.art,
            name: item.name,
            hasShortcode: {
                if case .insert = item.pick { return true }
                return false
            }(),
            source: section.title,
            sourceBadge: section.badge
        ))
    }

    // MARK: The clock

    /// Subscribes only while something on screen actually moves, and drops the
    /// subscription the moment nothing does — the clock tears its display link
    /// down when its last subscriber leaves, so a picker showing Unicode emoji
    /// costs nothing at all.
    private func updateClock() {
        let token = ObjectIdentifier(self)
        guard animates, hasAnimatedCellsVisible, window != nil else {
            AnimationClock.shared.unsubscribe(token)
            return
        }
        // Through the scroll: these cells are the thing being chosen, and a
        // grid that freezes the moment you flick it reads as broken. A popover
        // of 32pt cells is a bitmap swap each — see `AnimationClock.subscribe`.
        AnimationClock.shared.subscribe(token, throughScroll: true) { [weak self] in
            // One invalidation for the visible rect rather than one per cell:
            // in a section of animated emoji nearly every cell is moving, so
            // forty rects a frame would be forty times the bookkeeping for the
            // same repaint.
            self?.needsDisplay = true
        }
    }

    /// Recomputed when the viewport moves. Walks the visible rows only.
    func refreshAnimationState() {
        var found = false
        outer: for index in visibleRowRange() {
            let row = layout.rows[index]
            guard let first = row.firstItem else { continue }
            let items = sections[row.section].items
            for column in 0..<row.count {
                if case .image(_, true) = items[first + column].art {
                    found = true
                    break outer
                }
            }
        }
        guard found != hasAnimatedCellsVisible else { return }
        hasAnimatedCellsVisible = found
        updateClock()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }

    /// Leaves the clock for good.
    ///
    /// The clock keys subscribers by object identity and tears its display link
    /// down when the last one leaves — so a canvas that deallocated without
    /// saying so would leave a dead entry holding the link alive for the life
    /// of the process. `viewDidMoveToWindow` covers the ordinary path; this
    /// covers teardown, which is the one that must not be missed.
    func stopAnimating() {
        hasAnimatedCellsVisible = false
        AnimationClock.shared.unsubscribe(ObjectIdentifier(self))
    }

    /// Repaints one cell, plus the pad its highlight bleeds into.
    private func invalidate(_ cell: (section: Int, item: Int)?) {
        guard let cell, isValid(cell) else { return }
        for index in 0..<layout.rows.count {
            let row = layout.rows[index]
            guard row.section == cell.section, let first = row.firstItem,
                  cell.item >= first, cell.item < first + row.count
            else { continue }
            let frame = layout.itemFrame(row: index, column: cell.item - first)
            setNeedsDisplay(frame.insetBy(
                dx: ExpressionGridPainter.highlightInset,
                dy: ExpressionGridPainter.highlightInset
            ))
            return
        }
    }

    // MARK: Accessibility
    //
    // A drawn grid has no child views, so VoiceOver would find one element
    // called "Expressions" and nothing in it. The cells are published as
    // elements built on demand — only for the rows on screen, because an
    // account's whole emoji set is far too many to publish at once.

    override func accessibilityChildren() -> [Any]? {
        var elements: [NSAccessibilityElement] = []
        for index in visibleRowRange() {
            let row = layout.rows[index]
            guard let first = row.firstItem else { continue }
            let section = sections[row.section]
            for column in 0..<row.count {
                let item = section.items[first + column]
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(item.name)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(
                    layout.itemFrame(row: index, column: column)
                )
                elements.append(element)
            }
        }
        return elements
    }
}

/// The pinned heading: a floating copy of the pill the canvas draws inline.
///
/// **A plain subview of the scroll view, above the clip view** — deliberately
/// not `addFloatingSubview(_:for:)`. That API manages the frames it is given and
/// positions them inside the content insets, so a heading placed at "one chrome
/// height down" landed at two: measured, the pill sat a full inset below the
/// search field it is supposed to hold under. A subview the scroll view does not
/// manage leaves the arithmetic here, where it can be reasoned about.
///
/// It does not scroll, because only the clip view's document does. Repositioning
/// it is a frame assignment; it repaints only when the section it shows changes,
/// which is a handful of times per scroll.
final class ExpressionHeaderPill: NSView {
    var section: ExpressionSection? {
        didSet {
            guard section?.id != oldValue?.id || section?.isLocked != oldValue?.isLocked else {
                return
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Declines every hit, so a click meant for the cell underneath reaches it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let section else { return }
        ExpressionGridPainter.drawHeader(
            section,
            in: bounds,
            images: ImageStore.shared,
            scale: window?.backingScaleFactor ?? 2,
            context: context
        )
    }
}

// MARK: - Hosting

/// Where the grid should scroll to, and a token so the same request is not
/// obeyed twice.
///
/// A plain section index cannot express "jump to section 3 again" — which is
/// what clicking the same rail icon twice is — so the token is what makes the
/// request an event rather than a state.
struct ExpressionJump: Equatable {
    var section: Int
    var token: Int
}

/// A cell, carried by a menu item to its action.
private final class ExpressionMenuItem: NSObject {
    let item: ExpressionItem
    init(item: ExpressionItem) { self.item = item }
}

struct ExpressionGridView: NSViewRepresentable {
    var sections: [ExpressionSection]
    var mode: ExpressionMode
    /// How much room the floating chrome takes at the top. Content is inset by
    /// it and scrolls **under** it, and the pinned heading holds just below it.
    var topInset: CGFloat
    /// Whether moving art may move — the app's own preference, and Reduce
    /// Motion, resolved once at the root and handed down rather than asked of
    /// the OS here.
    var animates: Bool
    var jump: ExpressionJump?
    var onPick: (ExpressionItem) -> Void
    var onTopSectionChange: (Int) -> Void
    var onHover: (ExpressionHover?) -> Void
    var isFavorite: ((ExpressionItem) -> Bool)? = nil
    var onToggleFavorite: ((ExpressionItem) -> Void)? = nil

    func makeCoordinator() -> ExpressionGridCoordinator { ExpressionGridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onTopSectionChange = onTopSectionChange
        context.coordinator.onHover = onHover
        context.coordinator.setFavorites(isFavorite: isFavorite, toggle: onToggleFavorite)
        context.coordinator.update(
            sections: sections, mode: mode, topInset: topInset, animates: animates, jump: jump
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ExpressionGridCoordinator) {
        coordinator.tearDown()
        scrollView.documentView = nil
    }
}

@MainActor
final class ExpressionGridCoordinator: NSObject {
    private var scrollView: NSScrollView?
    private var documentView: TimelineDocumentView?
    private var canvas: ExpressionGridCanvas?
    private var headerPill: ExpressionHeaderPill?

    private var sections: [ExpressionSection] = []
    private var mode: ExpressionMode = .emoji
    private var layoutWidth: CGFloat = 0
    private var topInset: CGFloat = 0
    private var lastJumpToken = Int.min
    /// A jump the grid could not honour yet, because it had no layout to find
    /// the section in. Held rather than dropped: a picker opened AT a section
    /// asks before its first layout has run.
    private var pendingJumpSection: Int?
    private var reportedSection = -1

    private var observers: [NSObjectProtocol] = []
    private var prefetchTask: Task<Void, Never>?
    private var liveScrollTimeout: Task<Void, Never>?
    private var isTornDown = false

    var onPick: (ExpressionItem) -> Void = { _ in }
    var onTopSectionChange: (Int) -> Void = { _ in }
    var onHover: (ExpressionHover?) -> Void = { _ in }
    private var animates = true

    func setFavorites(isFavorite: ((ExpressionItem) -> Bool)?, toggle: ((ExpressionItem) -> Void)?) {
        canvas?.isFavorite = isFavorite
        canvas?.onToggleFavorite = toggle
    }

    func makeScrollView() -> NSScrollView {
        let canvas = ExpressionGridCanvas(frame: .zero)
        canvas.onPick = { [weak self] item in self?.onPick(item) }
        canvas.onWidthChange = { [weak self] _ in self?.applyLayout() }
        canvas.onHover = { [weak self] hover in self?.onHover(hover) }

        // Flipped, like every other document in this app. A plain `NSView` puts
        // the origin at the BOTTOM left, so the grid opens on the end of the
        // last category instead of the start of the first — which is a scroll
        // position nobody set and cannot explain.
        let document = TimelineDocumentView(frame: .zero)
        document.addSubview(canvas)

        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.automaticallyAdjustsContentInsets = false

        let pill = ExpressionHeaderPill(frame: .zero)
        scrollView.addSubview(pill, positioned: .above, relativeTo: scrollView.contentView)

        self.canvas = canvas
        self.documentView = document
        self.headerPill = pill
        self.scrollView = scrollView
        observe(scrollView)
        return scrollView
    }

    private func observe(_ scrollView: NSScrollView) {
        let center = NotificationCenter.default
        // The clip view's FRAME as well as its bounds: at `makeNSView` the
        // scroll view has no size, so the first real width arrives as a frame
        // change and the grid would otherwise stay blank until scrolled.
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(center.addObserver(
                forName: name, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportDidChange() }
            })
        }
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(true) }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrolling(false) }
        })
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        prefetchTask?.cancel()
        prefetchTask = nil
        liveScrollTimeout?.cancel()
        liveScrollTimeout = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        canvas?.stopAnimating()
        canvas?.onPick = nil
        canvas?.onWidthChange = nil
        canvas?.onHover = nil
        headerPill?.removeFromSuperview()
        headerPill = nil
        canvas = nil
        documentView = nil
        scrollView = nil
        ScrollWorkGate.endIfOwned(by: ObjectIdentifier(self))
    }

    deinit {
        MainActor.assumeIsolated {
            if !isTornDown { tearDown() }
        }
    }

    func update(
        sections: [ExpressionSection],
        mode: ExpressionMode,
        topInset: CGFloat,
        animates: Bool,
        jump: ExpressionJump?
    ) {
        guard !isTornDown else { return }
        if animates != self.animates {
            self.animates = animates
            canvas?.animates = animates
        }
        if abs(topInset - self.topInset) >= 0.5 {
            // **The content has to move with the inset.** The chrome's height is
            // measured, so the first layout runs at zero and the real inset
            // arrives a pass later — and a clip view left where it was is then
            // one chrome height off its own rest position. That is what put the
            // grid a section into itself and drew the pinned heading and the
            // canvas's own copy of it at two different heights.
            //
            // **Read where the reader was before the insets change.** AppKit
            // moves a clip view that has its size along with its inset, and
            // one that has none not at all; moving by the delta from wherever
            // AppKit left it moved a sized picker twice, and it opened a whole
            // chrome above its first section — Alex's image 49, "open to a
            // space", whenever the size landed before the measured inset.
            let delta = topInset - self.topInset
            self.topInset = topInset
            let origin = scrollView?.contentView.bounds.origin ?? .zero
            scrollView?.contentInsets = NSEdgeInsets(
                top: topInset, left: 0, bottom: Spacing.base, right: 0
            )
            // The scroller must not run under the chrome either.
            scrollView?.scrollerInsets = NSEdgeInsets(
                top: topInset, left: 0, bottom: 0, right: 0
            )
            if let scrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y - delta))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        if mode != self.mode || sections != self.sections {
            let modeChanged = mode != self.mode
            self.mode = mode
            self.sections = sections
            applyLayout()
            // A new tab starts at the top. Carrying the previous one's offset
            // into a set of sections that has nothing to do with it lands the
            // reader in the middle of a server they did not choose.
            if modeChanged { scrollToTop() }
        }
        if let jump, jump.token != lastJumpToken {
            lastJumpToken = jump.token
            pendingJumpSection = jump.section
        }
        applyPendingJump()
    }

    private func applyPendingJump() {
        guard let section = pendingJumpSection, scroll(toSection: section) else { return }
        pendingJumpSection = nil
    }

    private func applyLayout() {
        guard let canvas, let scrollView, !isTornDown else { return }
        let viewport = scrollView.contentView.bounds
        if viewport.width > 0 { layoutWidth = viewport.width }
        let metrics = ExpressionGridMetrics.resolve(for: mode, width: max(layoutWidth, 1))
        let height = canvas.apply(sections: sections, metrics: metrics)
        let size = NSSize(
            width: max(1, viewport.width),
            height: max(1, max(height, viewport.height))
        )
        if documentView?.frame.size != size { documentView?.setFrameSize(size) }
        positionCanvas()
        positionPinnedHeader()
        canvas.refreshAnimationState()
        schedulePrefetch()
        applyPendingJump()
    }

    private func viewportDidChange() {
        guard !isTornDown, let scrollView, let canvas else { return }
        let width = scrollView.contentView.bounds.width
        // Bootstrap and resize are the same case: the width the grid was laid
        // out against is no longer the width on screen.
        if width > 0, abs(width - layoutWidth) >= 1 {
            layoutWidth = width
            applyLayout()
            return
        }
        if canvas.layout.rows.isEmpty, !sections.isEmpty, width > 0 {
            applyLayout()
            return
        }
        positionCanvas()
        positionPinnedHeader()
        reportTopSection()
        canvas.refreshAnimationState()
        schedulePrefetch()
    }

    private func positionCanvas() {
        guard let scrollView, let canvas, let documentView else { return }
        let geometry = TimelineViewportPolicy.geometry(
            viewport: scrollView.contentView.bounds,
            documentHeight: documentView.frame.height,
            currentFrame: canvas.frame
        )
        canvas.installViewport(frame: geometry.frame, bounds: geometry.bounds)
    }

    /// Moves the pinned heading to wherever the scroll has pushed it.
    ///
    /// Cheap on purpose: a frame assignment, and a repaint only when the section
    /// changes. This runs on every bounds change, which is every scroll tick.
    private func positionPinnedHeader() {
        guard let scrollView, let canvas, let pill = headerPill else { return }
        let clip = scrollView.contentView.bounds
        // The line the heading holds at, in document space: the top of the
        // visible area, past the chrome floating over it.
        guard !sections.isEmpty,
              let pinned = canvas.layout.pinnedHeader(at: clip.minY + topInset),
              sections.indices.contains(pinned.section)
        else {
            pill.isHidden = true
            canvas.pinnedSection = nil
            return
        }
        pill.isHidden = false
        pill.section = sections[pinned.section]
        canvas.pinnedSection = pinned.section
        // The scroll view's space is **flipped** here, because its document is,
        // so this is a distance from the top rather than from the bottom — and
        // the clip view's frame starts at the scroll view's own origin, because
        // content insets move its BOUNDS and not its frame. So the distance the
        // heading sits below the clip view's top is the distance it sits below
        // the scroll view's, with nothing to add.
        pill.frame = CGRect(
            x: 0,
            y: pinned.y - clip.minY,
            width: scrollView.bounds.width,
            height: ExpressionGridLayout.headerHeight
        )
    }

    /// Tells the rail which section the reader is looking at.
    ///
    /// Guarded on the value, not fired per scroll tick: this crosses back into
    /// SwiftUI, and a write per tick re-evaluates the whole picker.
    private func reportTopSection() {
        guard let canvas, let scrollView else { return }
        let viewport = scrollView.contentView.bounds
        guard let section = canvas.layout.section(atTopOf: viewport),
              section != reportedSection
        else { return }
        reportedSection = section
        onTopSectionChange(section)
    }

    /// - Returns: false when there is no layout yet to find the section in.
    @discardableResult
    private func scroll(toSection section: Int) -> Bool {
        guard let canvas, let scrollView,
              let offset = canvas.layout.offset(ofSection: section)
        else { return false }
        reportedSection = section
        // Past the chrome, so the section's own heading is not left underneath
        // the search field it was jumped to from.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset - topInset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        positionCanvas()
        positionPinnedHeader()
        schedulePrefetch()
        return true
    }

    private func scrollToTop() {
        guard let scrollView else { return }
        reportedSection = 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topInset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        positionCanvas()
        positionPinnedHeader()
    }

    private func setScrolling(_ scrolling: Bool) {
        guard !isTornDown else { return }
        canvas?.isScrolling = scrolling
        let owner = ObjectIdentifier(self)
        if scrolling {
            ScrollWorkGate.begin(owner: owner)
            liveScrollTimeout?.cancel()
            liveScrollTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.setScrolling(false) }
            }
        } else {
            liveScrollTimeout?.cancel()
            liveScrollTimeout = nil
            ScrollWorkGate.endIfOwned(by: owner)
            schedulePrefetch()
        }
    }

    /// Fetches the pictures the visible cells need.
    ///
    /// **The painter only ever peeks at the cache** — it cannot start a fetch
    /// from inside a draw — so an asset nobody prefetches is an asset that never
    /// arrives, and the key here has to match the painter's exactly or the
    /// picture lands in a slot the draw never looks in.
    private func schedulePrefetch() {
        guard !isTornDown, let canvas else { return }
        prefetchTask?.cancel()

        let scale = canvas.window?.backingScaleFactor ?? 2
        let pixels = Int((canvas.layout.metrics.itemSize * scale).rounded(.up))
        var requests: [ImageStore.Key] = []
        var seen = Set<ImageStore.Key>()

        // Filmstrips, kept apart from the stills: they are a different decode
        // of the same URL into a different cache, and they are asked for second
        // so the grid fills with pictures before it starts moving.
        var films: [AnimatedImageStore.Key] = []

        // The heading pill's own icon, at the size the pill draws it.
        let badgePixels = Int((ExpressionGridPainter.badgeSide * scale).rounded(.up))
        for section in canvas.sections {
            guard case .image(let url, _) = section.badge, let url else { continue }
            if LottieFilmstrip.handles(url) {
                // A Lottie cover's poster lives in the filmstrip cache; at this
                // size the whole strip is a few kilobytes.
                let film = AnimatedImageStore.Key(url: url, maximumPixelSize: badgePixels)
                if AnimatedImageStore.shared.cached(film) == nil,
                   !AnimatedImageStore.shared.isKnownStill(film) {
                    films.append(film)
                }
                continue
            }
            let key = ImageStore.Key(url: url, maximumPixelSize: badgePixels)
            if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                requests.append(key)
            }
        }

        for index in canvas.visibleRowRange() {
            let row = canvas.layout.rows[index]
            guard let first = row.firstItem else { continue }
            let items = canvas.sections[row.section].items
            for column in 0..<row.count {
                guard case .image(let url, let animated) = items[first + column].art,
                      let url
                else { continue }
                // Lottie has no still — the CDN serves only the JSON — so
                // asking for one is a download and a decode that can only fail.
                if !LottieFilmstrip.handles(url) {
                    let key = ImageStore.Key(url: url, maximumPixelSize: pixels)
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(key)
                    }
                }
                guard animated, animates else { continue }
                let film = AnimatedImageStore.Key(
                    url: url,
                    maximumPixelSize: pixels,
                    byteBudget: ExpressionGridPainter.filmBudget
                )
                // `isKnownStill` is what stops a single-frame asset being
                // re-fetched and re-inspected forever by a grid that keeps
                // asking whether it can move.
                if AnimatedImageStore.shared.cached(film) == nil,
                   !AnimatedImageStore.shared.isKnownStill(film) {
                    films.append(film)
                }
            }
        }
        guard !requests.isEmpty || !films.isEmpty else { return }

        prefetchTask = Task { [weak self] in
            await ScrollWorkGate.waitUntilInactive()
            guard !Task.isCancelled else { return }
            // Stills first, then the films that make them move — each drawn as
            // it lands, coalesced (`ImageBatch`), so one slow sticker does not
            // keep the rest of the grid blank.
            await ImageBatch.load(
                requests,
                using: { await ImageStore.shared.image(for: $0) != nil },
                landed: { [weak self] _ in
                    guard let self, !self.isTornDown else { return }
                    self.canvas?.needsDisplay = true
                }
            )
            guard !films.isEmpty, !Task.isCancelled else { return }
            await ImageBatch.load(
                films,
                using: { await AnimatedImageStore.shared.image(for: $0) != nil },
                landed: { [weak self] _ in
                    guard let self, !self.isTornDown else { return }
                    self.canvas?.refreshAnimationState()
                    self.canvas?.needsDisplay = true
                }
            )
        }
    }
}
