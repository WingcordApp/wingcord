import AppKit

/// The ground and the scroll-edge strip a drawn canvas needs, installed into
/// its scroll view and driven from the viewport observer it already has.
///
/// **This used to be written twice**, verbatim, in `TimelineCoordinator` and
/// `MemberListCoordinator`: the same two views added in the same order, the same
/// three lines in the viewport observer, the same content-inset arithmetic. Two
/// copies of a rule that `INVARIANTS.md` describes as one rule is how the roster
/// ended up with a black strip the transcript never had — the transcript's copy
/// was fixed and the roster's was not.
///
/// So there is one copy, and the two canvases differ only in what they pass to
/// `init`: which ground they are, how far it is lifted, and what has to be true
/// before the strip appears.
@MainActor
final class CanvasChrome {
    /// The ground, drawn **inside** the scroll view.
    ///
    /// Not decoration and not a duplicate for its own sake: a within-window
    /// backdrop can only sample its own hosting subtree, so this is the only way
    /// the strip above it has anything to blur. See `CanvasGround`.
    private let ground: CanvasGroundView
    private let edge: ScrollEdgeBlur
    /// Present only for a strip that waits for the pointer.
    private let probe: PointerProbe?

    private weak var scrollView: NSScrollView?
    /// The canvas's own content extent, in document points. Handed in rather
    /// than read back off a document view, whose height is padded to the
    /// viewport and therefore says nothing about whether there is anything to
    /// pass under the chrome.
    var contentHeight: CGFloat = 0 {
        didSet {
            guard abs(contentHeight - oldValue) > 0.5 else { return }
            refreshEngagement()
        }
    }

    /// How much of the window's chrome sits above this column.
    var chromeHeight: CGFloat = 0 {
        didSet {
            guard abs(chromeHeight - oldValue) > 0.5 else { return }
            ground.chromeInset = max(0, chromeHeight)
            edge.chromeHeight = max(0, chromeHeight)
            refreshEngagement()
        }
    }

    init(
        installedIn scrollView: NSScrollView,
        role: ThemeGroundRole,
        lift: Double = 0,
        trigger: ScrollEdgeBlur.Trigger
    ) {
        self.scrollView = scrollView

        let ground = CanvasGroundView(frame: .zero)
        ground.role = role
        ground.lift = lift
        scrollView.addSubview(ground, positioned: .below, relativeTo: nil)
        self.ground = ground

        // **A plain subview, not `addFloatingSubview`.** A floating subview is
        // positioned inside the scroll view's CONTENT INSETS, so one asked to
        // sit at the top lands exactly one toolbar too low — a band hanging
        // under the chrome with sharp rows above it. Nothing in a scroll view
        // scrolls except its clip view, so an ordinary subview stays put.
        let edge = ScrollEdgeBlur(role: role, lift: lift)
        edge.trigger = trigger
        edge.needsGroundRedraw = { [weak ground] in ground?.needsDisplay = true }
        scrollView.addSubview(edge, positioned: .above, relativeTo: nil)
        self.edge = edge

        guard trigger == .contentBehindAndPointer else {
            probe = nil
            return
        }
        let probe = PointerProbe(frame: .zero)
        probe.onChange = { [weak edge] inside in edge?.pointerDidChange(inside: inside) }
        // Below the ground, so nothing that draws is layered over it. A probe
        // paints nothing and takes no hits; only its tracking rect matters, and
        // that is geometry rather than a place in the drawing order.
        scrollView.addSubview(probe, positioned: .below, relativeTo: nil)
        self.probe = probe
    }

    /// Called from the owner's viewport observer, **before its early returns**.
    ///
    /// Both of those returns are the first-layout path, which is exactly when
    /// the ground and the strip have never been sized — and a strip that misses
    /// it stays at zero width for the life of the window.
    func viewportDidChange() {
        guard let scrollView else { return }
        scrollView.hidesSystemScrollEdge()
        let bounds = scrollView.bounds
        if ground.frame != bounds { ground.frame = bounds }
        if let probe, probe.frame != bounds { probe.frame = bounds }
        edge.fit()
        refreshEngagement()
    }

    /// Re-answers "is there anything under the chrome" without touching a frame.
    ///
    /// Called from the viewport observer, and from the two inputs that can move
    /// the answer without the viewport moving at all: rows arriving, and the
    /// toolbar changing height.
    ///
    /// **The transcript needs the second call and it is not obvious.** Its
    /// coordinator suppresses viewport notifications for the whole of a layout
    /// pass — `isApplyingUpdate` — and a channel switch scrolls to the foot
    /// inside that window. Without this the strip kept whatever answer the
    /// *previous* channel left it with until the reader touched the wheel.
    func refreshEngagement() {
        guard let scrollView else { return }
        edge.contentDidScroll(
            overlap: TimelineViewportPolicy.chromeOverlap(
                scrollTop: scrollView.contentView.bounds.minY,
                chromeHeight: chromeHeight,
                contentHeight: contentHeight
            )
        )
    }

    func tearDown() {
        edge.needsGroundRedraw = nil
        probe?.onChange = nil
        scrollView = nil
    }
}

// MARK: - The pointer

/// Reports whether the pointer is anywhere inside a column.
///
/// A view rather than a tracking area on the scroll view itself: `NSScrollView`
/// is not ours to subclass in one of the two places this is needed, and a
/// tracking area whose owner is not a view has to be re-added by hand on every
/// resize. `.inVisibleRect` gives the rebuild for free, and `updateTrackingAreas`
/// is the one callback AppKit guarantees around it.
///
/// It draws nothing and takes no hits. Tracking areas are dispatched from the
/// window's geometry rather than through `hitTest`, so declining every hit costs
/// this nothing and keeps clicks reaching the canvas.
final class PointerProbe: NSView {
    var onChange: ((Bool) -> Void)?

    private var isInside = false

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                // `.activeInActiveApp` rather than `.activeAlways`: a pointer
                // resting over an app nobody is using is not a reader looking at
                // a roster.
                //
                // `.assumeInside` is deliberately absent, so a rebuild raised by
                // a resize re-answers the question from where the pointer
                // actually is instead of asserting it is outside.
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
        )
        // A rebuild happens when the column is resized, shown or scrolled into
        // place, and the pointer may already be inside it — in which case AppKit
        // sends no `mouseEntered` at all and the strip would wait for a move
        // that never comes.
        //
        // Only while the app is active, which is the same condition
        // `.activeInActiveApp` puts on the tracking area itself: answering this
        // from a pointer parked over a window nobody is using would contradict
        // it on the very next event.
        guard NSApp.isActive, let window, window.isVisible else {
            setInside(false)
            return
        }
        setInside(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }

    private func setInside(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        onChange?(inside)
    }
}
