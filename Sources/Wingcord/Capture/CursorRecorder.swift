import AppKit
import Foundation
import QuartzCore
import WingcordCore

// MARK: - Where the cursor went, while recording
//
// docs/CLIPS-PRESENCE.md, D12. The screen is recorded without the cursor, and
// this keeps it instead: sixty samples a second while it moves, every click
// and scroll, and which system cursor it was — so an editor can draw it again
// bigger, smoother, or not at all, and zoom towards a click.
//
// **Mouse events only.** A global monitor sees the mouse without Accessibility
// permission; keystrokes would need it, and a recording that asked for the
// right to read the keyboard is not one anybody should trust.

@MainActor
final class CursorRecorder {

    /// The recorded picture's frame in global points, top-left origin — a
    /// window's moves with it, so it is asked for on every sample.
    private let frame: () -> CGRect
    /// The movie's zero on the host clock, once the first frame is known.
    private let start: () -> Double?

    private var log = CursorLog()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastPoint: CGPoint?
    private var lastKind: CursorLog.Kind?
    /// Samples taken before the movie's first frame was known, on the host
    /// clock — moved onto the movie's when it is.
    private var early: [(time: Double, sample: CursorLog.Sample)] = []

    init(frame: @escaping () -> CGRect, start: @escaping () -> Double?) {
        self.frame = frame
        self.start = start
    }

    func begin() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.note(event) }
        }) { monitors.append(global) }
        // A global monitor sees other apps' events only; this app's own come
        // through a local one.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.note(event) }
            return event
        }) { monitors.append(local) }
    }

    /// Stops, and hands back everything kept.
    func end() -> CursorLog {
        timer?.invalidate()
        timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        return log
    }

    // MARK: Sampling

    private func sample() {
        let point = Self.globalTopLeft(NSEvent.mouseLocation)
        let kind = Self.currentKind()
        guard point != lastPoint || kind != lastKind else { return }
        lastPoint = point
        lastKind = kind
        let now = CACurrentMediaTime()
        let place = CursorLog.normalise(point, in: frame())
        let sample = CursorLog.Sample(t: 0, x: place.x, y: place.y, kind: kind, isOutside: place.isOutside)
        guard let start = start() else {
            early.append((now, sample))
            return
        }
        flushEarly(start: start)
        var timed = sample
        timed.t = max(0, now - start)
        log.samples.append(timed)
    }

    private func flushEarly(start: Double) {
        guard !early.isEmpty else { return }
        for (time, sample) in early where time >= start - 0.05 {
            var timed = sample
            timed.t = max(0, time - start)
            log.samples.append(timed)
        }
        early = []
    }

    private func note(_ event: NSEvent) {
        guard let start = start() else { return }
        flushEarly(start: start)
        let t = max(0, CACurrentMediaTime() - start)
        let place = CursorLog.normalise(Self.globalTopLeft(NSEvent.mouseLocation), in: frame())
        switch event.type {
        case .scrollWheel:
            log.scrolls.append(CursorLog.Scroll(t: t, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            log.clicks.append(CursorLog.Click(t: t, x: place.x, y: place.y, button: event.buttonNumber, isDown: true))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            log.clicks.append(CursorLog.Click(t: t, x: place.x, y: place.y, button: event.buttonNumber, isDown: false))
        default:
            break
        }
    }

    // MARK: Spaces

    /// AppKit's bottom-left global point as the top-left one ScreenCaptureKit
    /// and Core Graphics measure windows and displays in.
    static func globalTopLeft(_ point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: Which cursor

    /// The system cursors an editor can draw again, by the picture they show.
    private static let known: [(Data, CursorLog.Kind)] = {
        let cursors: [(NSCursor, CursorLog.Kind)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand),
            (.openHand, .openHand), (.closedHand, .closedHand), (.crosshair, .crosshair),
            (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
            (.operationNotAllowed, .notAllowed),
        ]
        return cursors.compactMap { cursor, kind in cursor.image.tiffRepresentation.map { ($0, kind) } }
    }()

    private static var lastImage: NSImage?
    private static var lastImageKind: CursorLog.Kind = .arrow

    /// Which cursor the system is drawing now. Compared by picture once per
    /// change of picture — not once a sample.
    private static func currentKind() -> CursorLog.Kind {
        guard let image = NSCursor.currentSystem?.image else { return .arrow }
        if image === lastImage { return lastImageKind }
        lastImage = image
        let data = image.tiffRepresentation
        lastImageKind = known.first { $0.0 == data }?.1 ?? .other
        return lastImageKind
    }
}
