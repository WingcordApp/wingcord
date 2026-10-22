import AppKit
import CoreGraphics

// MARK: - Choosing what to capture
//
// docs/CLIPS-PRESENCE.md, D12. The three choices macOS's own screenshot bar
// gives, in the same gestures: **a display** (clicked, when there is more than
// one), **a window** (the one under the pointer lit up, clicked), **an area**
// (dragged out). One clear panel over each display draws it; Escape cancels.
// Everything here is in Core Graphics' global space — points, top-left origin,
// the space ScreenCaptureKit measures displays and windows in.

/// What the reader chose.
enum CaptureChoice: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Part of a display, in that display's points from its top left.
    case area(CGDirectDisplayID, CGRect)
}

enum CaptureTarget: String, CaseIterable, Identifiable, Sendable {
    case display, window, area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }

    var symbolName: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

@MainActor
final class CaptureTargetPicker {

    private var panels: [CapturePickPanel] = []
    private var continuation: CheckedContinuation<CaptureChoice?, Never>?

    /// Shows the overlays and waits for a choice, or nil for Escape.
    ///
    /// - Parameter excluding: this app's own capture windows, which are never
    ///   offered.
    func choose(_ target: CaptureTarget, excluding: Set<CGWindowID>) async -> CaptureChoice? {
        // One display, and it is the display that is wanted: nothing to ask.
        if target == .display, NSScreen.screens.count == 1, let only = NSScreen.screens.first?.displayID {
            return .display(only)
        }
        let windows = target == .window ? Self.pickableWindows(excluding: excluding) : []
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let displayID = screen.displayID else { continue }
                let panel = CapturePickPanel(screen: screen, displayID: displayID, target: target, windows: windows)
                panel.pickView.onChoice = { [weak self] choice in self?.finish(choice) }
                panel.orderFrontRegardless()
                panels.append(panel)
            }
            // The one under the pointer takes the keyboard, for Escape.
            let mouse = NSEvent.mouseLocation
            (panels.first { $0.frame.contains(mouse) } ?? panels.first)?.makeKey()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ choice: CaptureChoice?) {
        for panel in panels { panel.orderOut(nil) }
        panels = []
        NSCursor.arrow.set()
        continuation?.resume(returning: choice)
        continuation = nil
    }

    /// Ordinary windows on screen, front first — Core Graphics' own order,
    /// which is the order the pointer meets them in.
    private static func pickableWindows(excluding: Set<CGWindowID>) -> [(id: CGWindowID, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  !excluding.contains(CGWindowID(number)),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            return (CGWindowID(number), frame)
        }
    }
}

// MARK: - One display's overlay

private final class CapturePickPanel: NSPanel {
    let pickView: CapturePickView

    init(screen: NSScreen, displayID: CGDirectDisplayID, target: CaptureTarget, windows: [(id: CGWindowID, frame: CGRect)]) {
        pickView = CapturePickView(displayID: displayID, target: target, windows: windows)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = pickView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class CapturePickView: NSView {
    var onChoice: ((CaptureChoice?) -> Void)?

    private let displayID: CGDirectDisplayID
    private let target: CaptureTarget
    private let windows: [(id: CGWindowID, frame: CGRect)]
    /// This display in global top-left points.
    private let displayBounds: CGRect
    private var hovered: CGWindowID?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(displayID: CGDirectDisplayID, target: CaptureTarget, windows: [(id: CGWindowID, frame: CGRect)]) {
        self.displayID = displayID
        self.target = target
        self.windows = windows
        displayBounds = CGDisplayBounds(displayID)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (target == .area ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    /// A view point as a global top-left one.
    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + displayBounds.minX, y: point.y + displayBounds.minY)
    }

    /// A global rect in this view's space.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    // MARK: The pointer

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard target == .window else { return }
        let point = global(convert(event.locationInWindow, from: nil))
        let under = windows.first { $0.frame.contains(point) }?.id
        guard under != hovered else { return }
        hovered = under
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch target {
        case .display:
            onChoice?(.display(displayID))
        case .window:
            let global = global(point)
            if let window = windows.first(where: { $0.frame.contains(global) }) { onChoice?(.window(window.id)) }
        case .area:
            dragStart = point
            dragRect = CGRect(origin: point, size: .zero)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard target == .area, let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragRect = CGRect(
            x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard target == .area, let rect = dragRect else { return }
        dragStart = nil
        // A click with no drag is not an area.
        guard rect.width >= 16, rect.height >= 16 else {
            dragRect = nil
            needsDisplay = true
            return
        }
        onChoice?(.area(displayID, rect.integral))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onChoice?(nil) } else { super.keyDown(with: event) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let veil = NSColor.black.withAlphaComponent(0.32)
        switch target {
        case .display:
            (isHovered ? NSColor.controlAccentColor.withAlphaComponent(0.22) : veil).setFill()
            bounds.fill()
            drawLabel(isHovered ? "Click to choose this display" : "", in: bounds)
        case .window:
            veil.setFill()
            bounds.fill()
            if let hovered, let frame = windows.first(where: { $0.id == hovered })?.frame {
                let rect = local(frame)
                NSColor.clear.setFill()
                rect.fill(using: .copy)
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                rect.fill()
                let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                outline.stroke()
            }
        case .area:
            let path = NSBezierPath(rect: bounds)
            if let dragRect, dragRect.width > 0 {
                path.append(NSBezierPath(rect: dragRect))
                path.windingRule = .evenOdd
            }
            veil.setFill()
            path.fill()
            if let dragRect, dragRect.width > 0 {
                let outline = NSBezierPath(rect: dragRect.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                NSColor.white.setStroke()
                outline.stroke()
                drawSize(of: dragRect)
            }
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// The selection's size in pixels, beside its corner — as macOS's own.
    private func drawSize(of rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(x: rect.maxX - size.width - 8, y: rect.maxY + 6 + size.height < bounds.maxY ? rect.maxY + 6 : rect.maxY - size.height - 6)
        let plate = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

extension NSScreen {
    /// The Core Graphics display this screen is.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
