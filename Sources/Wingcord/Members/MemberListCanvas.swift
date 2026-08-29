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

    var isScrolling = false {
        didSet {
            guard isScrolling != oldValue, isScrolling, hoveredRow != nil else { return }
            let previous = hoveredRow
            hoveredRow = nil
            invalidateRow(previous)
        }
    }

    var onOpenProfile: ((UserID, CGRect) -> Void)?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

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

        while index < rows.count, offsets[index] < dirtyRect.maxY {
            let frame = rowFrame(at: index)
            if frame.intersects(dirtyRect) {
                switch rows[index] {
                case .header(let title, let count, let colorValue):
                    MemberRowPainter.drawHeader(
                        title: title,
                        count: count,
                        colorValue: colorValue,
                        in: frame,
                        context: context,
                        style: style
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
                        }
                    )
                }
            }
            index += 1
        }
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

    override func mouseMoved(with event: NSEvent) {
        guard !isScrolling else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = bounds.contains(point) ? rowIndex(at: point.y) : nil
        let hoverable = index.flatMap { rows.indices.contains($0) && rows[$0].userID != nil ? $0 : nil }
        guard hoverable != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = hoverable
        invalidateRow(previous)
        invalidateRow(hoverable)
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

    override func accessibilityChildren() -> [Any]? {
        visibleRowRange().compactMap { index -> NSAccessibilityElement? in
            guard case .member(let entry) = rows[index] else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.button)
            var label = entry.name
            if entry.isBot { label += ", app" }
            label += ", \(entry.status.label)"
            if let subtitle = entry.subtitle { label += ", \(subtitle)" }
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rowFrame(at: index))
            return element
        }
    }
}
