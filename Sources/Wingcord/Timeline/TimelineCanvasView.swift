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
    private var highlightedMessageID: MessageID?
    private var revealedSpoilers: [MessageID: Set<Int>] = [:]
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
                invalidateRow(previous)
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
    var onOpenLink: ((MessageText.LinkTarget) -> Void)?
    var onVisibleRangeChange: ((Range<Int>) -> Void)?
    var onActivateMessage: ((MessageID) -> Void)?

    private var trackingArea: NSTrackingArea?

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
        needsDisplay = true
        return running
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
    func installViewport(frame newFrame: CGRect, bounds newBounds: CGRect) {
        if bounds != newBounds {
            bounds = newBounds
            // A fast gesture can replace the whole overscanned window in one
            // event. Ask for the new contents explicitly so Core Animation never
            // presents an empty slice while waiting for an unrelated
            // invalidation.
            needsDisplay = true
        }
        if frame != newFrame {
            frame = newFrame
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
                if let messageID = row.messageID {
                    state.isHighlighted = messageID == highlightedMessageID
                    state.revealedSpoilers = revealedSpoilers[messageID] ?? []
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
        guard hoveredRow != nil else { return }
        let previous = hoveredRow
        hoveredRow = nil
        invalidateRow(previous)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point.y),
              rows.indices.contains(index),
              case .message(let row) = rows[index].kind
        else { return }

        let frame = rowFrame(at: index)
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        // A spoiler beats a link: the reveal has to happen before the thing
        // underneath can be clicked, or a masked link inside a spoiler opens
        // without ever being read.
        if let block = row.textBlock {
            let inBlock = CGPoint(
                x: local.x - row.textOrigin.x,
                y: local.y - row.textOrigin.y
            )
            var revealed = revealedSpoilers[row.id] ?? []
            for (spoilerIndex, rect) in block.spoilerRects.enumerated()
            where !revealed.contains(spoilerIndex) && rect.contains(inBlock) {
                revealed.insert(spoilerIndex)
                revealedSpoilers[row.id] = revealed
                invalidateRow(index)
                return
            }
            if let target = block.linkTarget(at: inBlock) {
                onOpenLink?(target)
                return
            }
        }

        if event.clickCount == 2 {
            onActivateMessage?(row.id)
        }
    }

    private func currentPointerLocation() -> CGPoint {
        guard let window else { return CGPoint(x: -1, y: -1) }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func updateHover(at point: CGPoint) {
        let index: Int? = bounds.contains(point) ? rowIndex(at: point.y) : nil
        // A write of an equal value still costs a redraw request, and the
        // pointer generates these at event rate.
        guard index != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = index
        invalidateRow(previous)
        invalidateRow(index)
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
