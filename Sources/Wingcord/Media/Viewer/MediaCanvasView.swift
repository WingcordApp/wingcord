import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The viewer's stage: one layer, moved.
///
/// **Nothing here ever redraws.** A still is a `CALayer`'s `contents`, a
/// filmstrip is that property assigned a different frame, and a video is an
/// `AVPlayerLayer` — so zoom, pan, the spring that settles them and every frame
/// of a GIF cost one property write and no display pass at all. The compositor
/// does the rest on the GPU, which is what makes a 4000-pixel photograph pan at
/// the pointer's exact speed on a laptop.
///
/// **Every gesture is handled here rather than by SwiftUI**, and that is a
/// deliberate trade of code for feel. `DragGesture` cannot give the release
/// velocity that `INVARIANTS.md` §3 requires for a handoff, a `ScrollView`
/// cannot be zoom-anchored to the pointer, and neither sees `magnify(with:)`,
/// `smartMagnify(with:)` or a wheel at all. One responder sees all of them, with
/// no ambiguity about which recogniser won.
///
/// The gesture vocabulary, and it is the same one every picture on this platform
/// answers to:
///
/// | Gesture | Zoomed in | At fit |
/// | --- | --- | --- |
/// | Pinch | zoom, anchored at the fingers | shrink, then dismiss |
/// | Two-finger drag | pan | throw away, then dismiss |
/// | Drag | pan | — |
/// | Double click / two-finger double tap | back to fit | zoom to actual size |
/// | Wheel | pan | — |
/// | ⌘ + wheel | zoom | zoom |
///
/// The five behaviours it exists to get right:
///
///  1. **1:1 tracking.** The picture is glued to the pointer, from the grab
///     offset, for the whole drag.
///  2. **Resistance, not a wall.** Past its bounds the picture keeps following,
///     less and less, and springs back on release.
///  3. **Velocity handoff.** The settle starts at the pointer's exact release
///     velocity, so there is no seam between dragging and animating.
///  4. **Interruptible.** A new gesture takes the *current* value, mid-spring,
///     and carries on from there.
///  5. **The dismissal is the gesture, not a button it triggers.** The picture
///     shrinks under the fingers and the surface behind it fades in step, so the
///     reader can see the outcome coming and let go to cancel it.
final class MediaCanvasView: NSView {

    /// How the content fills the stage.
    enum Fill {
        /// Zoomable and pannable, laid out from the picture's own pixel size.
        case transformable(CGSize)
        /// Letterboxed by the layer itself, at the stage's full size.
        ///
        /// **Video takes this and does not zoom.** Its natural size arrives from
        /// the player a beat after the first frame does, so a stage that laid
        /// itself out from a size it does not have yet would show one frame at
        /// the wrong aspect on every video ever opened. `resizeAspect` on a
        /// full-bounds layer is right before the size is known and after.
        case letterboxed
    }

    // MARK: Content

    private let contentLayer = CALayer()
    private var playerLayer: AVPlayerLayer?
    private var fill: Fill = .letterboxed
    private var film: AnimatedImage?
    private var shownFrame = -1
    /// The bitmap currently in `contentLayer.contents`, kept alongside it.
    ///
    /// `CALayer.contents` is `Any?` and reading a `CGImage` back out of it is a
    /// force cast on a value the layer is free to have replaced. One reference
    /// beside it is cheaper than the cast and cannot be wrong.
    private var shownImage: CGImage?

    /// Whichever layer is currently showing something. One accessor, so the
    /// transform arithmetic below has no cases in it.
    private var activeLayer: CALayer { playerLayer ?? contentLayer }

    // MARK: Transform state

    private(set) var zoom = MediaZoom.fit
    private var target = MediaZoom.fit
    private var velocity = CGPoint.zero
    private var scaleVelocity: CGFloat = 0

    /// Reduce Motion replaces every settle with an assignment. The travel goes;
    /// the picture still lands where it should.
    var reducesMotion = false

    // MARK: Dismissal

    /// How far the picture has been thrown, and how far it has been squeezed.
    /// Both feed one progress number, because the reader is doing one thing.
    private var dismissTranslation = CGPoint.zero
    private var dismissPinch: CGFloat = 1
    private var dismissTranslationTarget = CGPoint.zero
    private var dismissPinchTarget: CGFloat = 1
    private var dismissVelocity = CGPoint.zero
    private var dismissPinchVelocity: CGFloat = 0
    private var isDismissing = false
    private var reportedProgress: Double = 0

    /// A squeeze past this commits. Loose enough that a deliberate pinch always
    /// lands and tight enough that brushing the trackpad never does.
    private static let dismissPinchThreshold: CGFloat = 0.86
    /// And a throw past this, measured where the flick is *going* rather than
    /// where the fingers left off — §3.
    private static let dismissThrowThreshold: CGFloat = 130
    /// Travel before a two-finger scroll at fit is treated as a throw at all.
    private static let dismissHysteresis: CGFloat = 9

    // MARK: Playback

    /// The film's own playhead, in seconds.
    ///
    /// **Its own, not the shared clock's.** Every other animated surface in the
    /// app reads `AnimationClock.time` directly, which is right for scenery that
    /// only ever plays. Here the reader can pause and scrub, so the clock
    /// supplies the *tick* and this accumulates it — which also keeps a paused
    /// viewer costing exactly one subscription and no frames.
    private(set) var playhead: Double = 0
    private var lastTick: Double?
    var isFilmPlaying = true
    var filmRate: Double = 1

    // MARK: Callbacks

    /// Fires when the zoom lands somewhere new. Guarded on a real change, so a
    /// settle reports the frames that moved and not the ones that did not.
    var onZoomChange: ((CGFloat) -> Void)?
    /// Fires when the shown frame changes. Bounded by the film's own rate, not
    /// the display's.
    var onFrameChange: ((Int) -> Void)?
    /// 0 at rest, 1 at the point of no return. The surfaces behind and above the
    /// picture fade with it.
    var onDismissProgress: ((Double) -> Void)?
    /// The gesture committed. The viewer closes; nothing here springs back.
    var onDismiss: (() -> Void)?
    /// A click landed beside the media rather than on it.
    ///
    /// **The stage fills the window, so the letterboxing belongs to this view
    /// and not to the scrim behind it.** Without this the empty half of a
    /// portrait photograph swallows every click, and the one gesture every
    /// lightbox on this platform answers to — click outside, close — does
    /// nothing at all.
    var onBackgroundClick: (() -> Void)?
    /// A click landed on the media itself. Video only: it is the gesture that
    /// means play or pause everywhere else, and a picture has nothing to toggle.
    var onContentClick: (() -> Void)?

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.drawsAsynchronously = false
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .trilinear
        // No implicit animation on any property this view assigns. Core
        // Animation would otherwise cross-fade every frame of a GIF and ease
        // every point of a 1:1 drag a quarter of a second behind the pointer.
        contentLayer.actions = Self.silentActions
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let silentActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "frame": NSNull(), "opacity": NSNull(), "transform": NSNull(),
    ]

    /// Key events belong to SwiftUI, which owns Escape, the arrows and the space
    /// bar. A view that takes first responder here takes them with it.
    override var acceptsFirstResponder: Bool { false }
    /// A click into an inactive window both activates it and starts the drag,
    /// rather than being spent on the activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Releases the link and the clock subscription. Idempotent.
    func tearDown() {
        stopSettle()
        unsubscribeFromClock()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        onZoomChange = nil
        onFrameChange = nil
        onDismissProgress = nil
        onDismiss = nil
        onBackgroundClick = nil
        onContentClick = nil
    }

    // MARK: Installing content

    func setStill(_ image: CGImage?, pixelSize: CGSize) {
        film = nil
        shownFrame = -1
        unsubscribeFromClock()
        shownImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        CATransaction.commit()
        setFill(pixelSize.width > 0 ? .transformable(pixelSize) : .letterboxed)
    }

    func setFilm(_ film: AnimatedImage?) {
        self.film = film
        shownFrame = -1
        guard let film, let first = film.frames.first else {
            unsubscribeFromClock()
            return
        }
        setFill(.transformable(CGSize(width: first.width, height: first.height)))
        playhead = 0
        lastTick = nil
        showFilmFrame()
        subscribeToClock()
    }

    /// Installs the video layer, or takes it away.
    ///
    /// The player is owned by the playback controller; the layer is this view's,
    /// because a layer belongs to the tree it is composited in and outliving the
    /// stage is exactly what a retained one would do.
    func setPlayer(_ player: AVPlayer?) {
        guard let player else {
            playerLayer?.player = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            return
        }
        if let playerLayer {
            if playerLayer.player !== player { playerLayer.player = player }
        } else {
            let created = AVPlayerLayer(player: player)
            created.videoGravity = .resizeAspect
            created.actions = Self.silentActions
            layer?.addSublayer(created)
            playerLayer = created
        }
        contentLayer.contents = nil
        shownImage = nil
        film = nil
        unsubscribeFromClock()
        setFill(.letterboxed)
    }

    private func setFill(_ newFill: Fill) {
        fill = newFill
        // A new picture starts fitted. Carrying the previous one's zoom over
        // means stepping to the next attachment lands somewhere in the middle
        // of it at 4x, which reads as the viewer having lost its place.
        stopSettle()
        zoom = .fit
        target = .fit
        velocity = .zero
        scaleVelocity = 0
        clearDismissState()
        layoutContent()
        onZoomChange?(1)
    }

    // MARK: Geometry

    private var geometry: MediaStageGeometry {
        MediaStageGeometry(
            contentPixels: {
                if case .transformable(let size) = fill { return size }
                return bounds.size
            }(),
            viewport: bounds.size,
            displayScale: window?.backingScaleFactor ?? 2
        )
    }

    var isTransformable: Bool {
        if case .transformable = fill { return true }
        return false
    }

    var maximumZoom: CGFloat { geometry.maximumScale }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// The one place a layer's frame is written.
    ///
    /// Inside a transaction with actions disabled: `layer.actions` covers the
    /// keys this view sets by name, and a transaction covers everything a future
    /// edit might add.
    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let base: CGRect = isTransformable && playerLayer == nil
            ? geometry.contentRect(zoom)
            : bounds
        activeLayer.frame = dismissTransformed(base)
    }

    /// The dismissal, applied last: a squeeze about the picture's own centre and
    /// a translation, so it reads as the picture being taken away rather than as
    /// the zoom changing.
    private func dismissTransformed(_ rect: CGRect) -> CGRect {
        guard dismissPinch < 0.999 || dismissTranslation != .zero else { return rect }
        let size = CGSize(width: rect.width * dismissPinch, height: rect.height * dismissPinch)
        return CGRect(
            x: rect.midX - size.width / 2 + dismissTranslation.x,
            y: rect.midY - size.height / 2 + dismissTranslation.y,
            width: size.width,
            height: size.height
        )
    }

    // MARK: Commands

    /// Zooms about the stage's centre. What the toolbar's slider and its two
    /// step buttons call.
    func setZoom(_ scale: CGFloat, animated: Bool = true) {
        guard isTransformable else { return }
        zoomTo(scale, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: animated)
    }

    func reset() {
        guard isTransformable else { return }
        settle(to: .fit)
    }

    /// Fit ↔ actual size, about the stage's centre. What the space bar and the
    /// double click both mean; the click anchors at the pointer instead.
    func toggleZoom() {
        guard isTransformable else { return }
        zoomTo(
            zoom.scale > 1.001 ? 1 : geometry.toggleScale,
            anchor: CGPoint(x: bounds.midX, y: bounds.midY),
            animated: true
        )
    }

    private func zoomTo(_ scale: CGFloat, anchor: CGPoint, animated: Bool) {
        let geometry = self.geometry
        let clamped = min(geometry.maximumScale, max(1, scale))
        let offset = geometry.anchoredOffset(from: zoom, to: clamped, anchor: anchor)
        let landing = MediaZoom(scale: clamped, offset: geometry.clamped(offset, scale: clamped))
        if animated { settle(to: landing) } else { apply(landing) }
    }

    // MARK: Film

    private func subscribeToClock() {
        // `throughScroll` because in this surface the moving picture IS the
        // content. Nothing in the viewer scrolls, but the gate is process-wide
        // and a member list being flicked behind the lightbox would otherwise
        // freeze what the reader opened it to watch.
        AnimationClock.shared.subscribe(ObjectIdentifier(self), throughScroll: true) {
            [weak self] in self?.tickFilm()
        }
    }

    private func unsubscribeFromClock() {
        AnimationClock.shared.unsubscribe(ObjectIdentifier(self))
        lastTick = nil
    }

    private func tickFilm() {
        guard let film, film.duration > 0 else { return }
        let now = AnimationClock.shared.time
        defer { lastTick = now }
        guard isFilmPlaying, let lastTick else { return }
        playhead = (playhead + (now - lastTick) * filmRate)
            .truncatingRemainder(dividingBy: film.duration)
        showFilmFrame()
    }

    /// The picture currently on screen.
    ///
    /// **The frame being shown, not the first one.** Copying a GIF somebody has
    /// scrubbed to the middle of should copy what they are looking at. Nil for
    /// video, whose frames belong to the decoder.
    func currentImage() -> CGImage? { shownImage }

    /// Parks the playhead on one frame. What the scrubber drives.
    func seekFilm(toFrame index: Int) {
        guard let film, film.frameCount > 0 else { return }
        let clamped = min(film.frameCount - 1, max(0, index))
        // The *start* of that frame: seeking to its end would show the next one
        // for every position the reader dragged to.
        playhead = clamped == 0 ? 0 : film.ends[clamped - 1]
        showFilmFrame()
    }

    private func showFilmFrame() {
        guard let film else { return }
        let index = film.index(at: playhead)
        guard index != shownFrame else { return }
        shownFrame = index
        shownImage = film.frames[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = shownImage
        CATransaction.commit()
        onFrameChange?(index)
    }

    // MARK: Pointer

    private var dragOrigin: CGPoint?
    private var dragStartOffset = CGPoint.zero
    private var lastSample: (point: CGPoint, time: TimeInterval)?
    private var previousSample: (point: CGPoint, time: TimeInterval)?

    override func resetCursorRects() {
        guard isTransformable, zoom.scale > 1.001 else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isTransformable else {
            // Video. `videoRect` is the picture inside the layer, which is what
            // the letterboxing is measured against — the layer itself is the
            // whole stage.
            guard let playerLayer, playerLayer.videoRect.contains(point) else {
                onBackgroundClick?()
                return
            }
            onContentClick?()
            return
        }
        if event.clickCount == 2 {
            zoomTo(zoom.scale > 1.001 ? 1 : geometry.toggleScale, anchor: point, animated: true)
            return
        }
        guard geometry.contentRect(zoom).contains(point) else {
            onBackgroundClick?()
            return
        }
        guard zoom.scale > 1.001 else { return }
        // Interrupting a settle takes the value that is on screen right now,
        // never the target it was heading for — §3, and the difference is a
        // visible jump on every grab of a moving picture.
        stopSettle()
        dragOrigin = point
        dragStartOffset = zoom.offset
        lastSample = (point, event.timestamp)
        previousSample = nil
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let proposed = CGPoint(
            x: dragStartOffset.x + (point.x - dragOrigin.x),
            y: dragStartOffset.y + (point.y - dragOrigin.y)
        )
        apply(MediaZoom(scale: zoom.scale, offset: geometry.resisted(proposed, scale: zoom.scale)))
        previousSample = lastSample
        lastSample = (point, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        NSCursor.pop()
        let released = releaseVelocity()
        let geometry = self.geometry
        let rest = geometry.projectedRest(from: zoom.offset, velocity: released, scale: zoom.scale)
        settle(to: MediaZoom(scale: zoom.scale, offset: rest), velocity: released)
    }

    /// Points per second at release, from the last two samples.
    ///
    /// Two rather than one: a single event's delta over a single event's
    /// interval is dominated by whatever the event loop was doing at that
    /// instant, and reads as a flick nobody made.
    private func releaseVelocity() -> CGPoint {
        guard let lastSample, let previousSample else { return .zero }
        let interval = lastSample.time - previousSample.time
        guard interval > 0.001 else { return .zero }
        return CGPoint(
            x: (lastSample.point.x - previousSample.point.x) / interval,
            y: (lastSample.point.y - previousSample.point.y) / interval
        )
    }

    // MARK: Trackpad

    override func scrollWheel(with event: NSEvent) {
        // A wheel with Command, or any wheel from a device with no precise
        // deltas, zooms. A trackpad's two-finger scroll pans, which is what it
        // does over every other picture on this platform.
        let isZoom = event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas
        if isZoom {
            guard isTransformable else { return }
            let step = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 120
                : event.scrollingDeltaY / 20
            zoomTo(
                zoom.scale * (1 + step),
                anchor: convert(event.locationInWindow, from: nil),
                animated: false
            )
            return
        }

        // At fit there is nothing to pan, so a two-finger drag means "take this
        // away" — the gesture every picture viewer on Apple's platforms answers
        // to. Zoomed in it means what it says.
        guard isTransformable, zoom.scale > 1.001 else {
            throwGesture(with: event)
            return
        }
        stopSettle()
        let proposed = CGPoint(
            x: zoom.offset.x + event.scrollingDeltaX,
            y: zoom.offset.y - event.scrollingDeltaY
        )
        apply(MediaZoom(scale: zoom.scale, offset: geometry.resisted(proposed, scale: zoom.scale)))
        if event.phase == .ended || event.momentumPhase == .ended {
            settle(to: MediaZoom(
                scale: zoom.scale,
                offset: geometry.clamped(zoom.offset, scale: zoom.scale)
            ))
        }
    }

    /// Two fingers at fit: the picture follows them 1:1 and shrinks as it goes,
    /// so where the gesture is heading is legible before it lands — and letting
    /// go short of the threshold springs it back rather than committing.
    private func throwGesture(with event: NSEvent) {
        switch event.phase {
        case .began:
            stopSettle()
            isDismissing = false
        case .changed:
            dismissTranslation.x += event.scrollingDeltaX
            dismissTranslation.y -= event.scrollingDeltaY
            let distance = hypot(dismissTranslation.x, dismissTranslation.y)
            guard distance > Self.dismissHysteresis else { return }
            isDismissing = true
            // The squeeze is derived from the throw rather than tracked
            // separately: one gesture, one progress, and the two can never
            // disagree about how far along it is.
            dismissPinch = 1 - min(0.22, distance / 1400)
            publishDismissProgress()
            layoutContent()
        case .ended, .cancelled:
            guard isDismissing else { return }
            isDismissing = false
            let velocity = throwVelocity(from: event)
            let projected = CGPoint(
                x: Motion.projectedPosition(from: dismissTranslation.x, velocity: velocity.x),
                y: Motion.projectedPosition(from: dismissTranslation.y, velocity: velocity.y)
            )
            if hypot(projected.x, projected.y) >= Self.dismissThrowThreshold {
                commitDismissal()
            } else {
                springDismissBack(velocity: velocity)
            }
        default:
            break
        }
    }

    /// A scroll gesture carries no velocity of its own, so the last event's
    /// delta over one frame is the best estimate available — and it is the same
    /// estimate AppKit's own momentum is built from.
    private func throwVelocity(from event: NSEvent) -> CGPoint {
        CGPoint(x: event.scrollingDeltaX * 60, y: -event.scrollingDeltaY * 60)
    }

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            stopSettle()
            pinchBaseScale = zoom.scale
            pinchFactor = 1
        case .changed:
            pinchFactor *= (1 + event.magnification)
            let proposed = pinchBaseScale * pinchFactor
            if proposed >= 1 {
                // Back above fit: the dismissal is abandoned in the same motion
                // that started it, which is what makes it feel cancellable
                // rather than committed the moment it began.
                if dismissPinch < 1 {
                    dismissPinch = 1
                    dismissTranslation = .zero
                    publishDismissProgress()
                }
                guard isTransformable else { return }
                zoomTo(proposed, anchor: convert(event.locationInWindow, from: nil), animated: false)
                return
            }
            // Below fit. Resisted, so the picture never simply collapses and the
            // reader always has room to change their mind.
            dismissPinch = 1 - Motion.rubberBand(offset: 1 - proposed, limit: 0.9, coefficient: 1.6)
            publishDismissProgress()
            layoutContent()
        case .ended, .cancelled:
            if dismissPinch <= Self.dismissPinchThreshold {
                commitDismissal()
            } else if dismissPinch < 0.999 || dismissTranslation != .zero {
                springDismissBack(velocity: .zero)
            } else if isTransformable {
                settle(to: MediaZoom(
                    scale: zoom.scale,
                    offset: geometry.clamped(zoom.offset, scale: zoom.scale)
                ))
            }
        default:
            break
        }
    }

    private var pinchBaseScale: CGFloat = 1
    private var pinchFactor: CGFloat = 1

    /// The trackpad's two-finger double tap. The same gesture the double click
    /// is, so it lands in the same place.
    override func smartMagnify(with event: NSEvent) {
        guard isTransformable else { return }
        zoomTo(
            zoom.scale > 1.001 ? 1 : geometry.toggleScale,
            anchor: convert(event.locationInWindow, from: nil),
            animated: true
        )
    }

    // MARK: Dismissal

    /// 0 at rest, 1 at the point of no return. Both halves of the gesture map
    /// onto it, so the fade behind the picture is one number whichever way the
    /// reader is doing this.
    private var dismissProgress: Double {
        let fromPinch = Double((1 - dismissPinch) / (1 - Self.dismissPinchThreshold))
        let fromThrow = Double(
            hypot(dismissTranslation.x, dismissTranslation.y) / Self.dismissThrowThreshold
        )
        return min(1, max(0, max(fromPinch, fromThrow)))
    }

    private func publishDismissProgress() {
        let progress = dismissProgress
        // A gesture reports at event rate; the surfaces that read this are a
        // scrim and a control bar, and neither can show a hundredth.
        guard abs(progress - reportedProgress) > 0.01 || progress == 0 || progress == 1 else {
            return
        }
        reportedProgress = progress
        onDismissProgress?(progress)
    }

    /// Committing freezes the transform where the fingers left it.
    ///
    /// **Nothing springs back and nothing is re-animated here.** The viewer's own
    /// exit takes over on the next frame and scales the whole surface from
    /// wherever this one is, so the two compose into one continuous movement
    /// instead of a snap followed by a fade.
    private func commitDismissal() {
        reportedProgress = 1
        onDismissProgress?(1)
        onDismiss?()
    }

    private func springDismissBack(velocity: CGPoint) {
        dismissTranslationTarget = .zero
        dismissPinchTarget = 1
        dismissVelocity = velocity
        dismissPinchVelocity = 0
        guard !reducesMotion else {
            clearDismissState()
            layoutContent()
            onDismissProgress?(0)
            return
        }
        startSettle()
    }

    private func clearDismissState() {
        dismissTranslation = .zero
        dismissPinch = 1
        dismissTranslationTarget = .zero
        dismissPinchTarget = 1
        dismissVelocity = .zero
        dismissPinchVelocity = 0
        isDismissing = false
        reportedProgress = 0
    }

    // MARK: The spring

    private var settleLink: CADisplayLink?
    private var lastSettleTime: CFTimeInterval?
    private static let spring = Motion.momentum.spring

    private func apply(_ newZoom: MediaZoom) {
        let scaleChanged = abs(newZoom.scale - zoom.scale) > 0.0005
        zoom = newZoom
        layoutContent()
        if scaleChanged {
            onZoomChange?(newZoom.scale)
            // The pointer over a picture that has just become pannable — or has
            // just stopped being — is holding the wrong cursor until it moves.
            window?.invalidateCursorRects(for: self)
        }
    }

    private func settle(to landing: MediaZoom, velocity released: CGPoint = .zero) {
        target = landing
        guard !reducesMotion else {
            self.velocity = .zero
            scaleVelocity = 0
            stopSettle()
            apply(landing)
            return
        }
        velocity = released
        startSettle()
    }

    private func startSettle() {
        guard settleLink == nil else { return }
        lastSettleTime = nil
        let link = displayLink(target: self, selector: #selector(stepSettle(_:)))
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    private func stopSettle() {
        settleLink?.invalidate()
        settleLink = nil
        lastSettleTime = nil
    }

    @objc private func stepSettle(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let lastSettleTime else {
            self.lastSettleTime = now
            return
        }
        // Clamped: a step longer than a moment means the app was busy, and a
        // spring integrated over it lands in one visible jump.
        let delta = min(now - lastSettleTime, 1.0 / 30)
        self.lastSettleTime = now

        // **One spring per axis.** A single spring over the 2D distance
        // desynchronises the moment x and y carry different velocities, which is
        // every diagonal flick there has ever been.
        var x = Double(zoom.offset.x), vx = Double(velocity.x)
        var y = Double(zoom.offset.y), vy = Double(velocity.y)
        var scale = Double(zoom.scale), vs = Double(scaleVelocity)
        var dx = Double(dismissTranslation.x), dvx = Double(dismissVelocity.x)
        var dy = Double(dismissTranslation.y), dvy = Double(dismissVelocity.y)
        var pinch = Double(dismissPinch), vp = Double(dismissPinchVelocity)

        Self.spring.update(value: &x, velocity: &vx, target: Double(target.offset.x), deltaTime: delta)
        Self.spring.update(value: &y, velocity: &vy, target: Double(target.offset.y), deltaTime: delta)
        Self.spring.update(value: &scale, velocity: &vs, target: Double(target.scale), deltaTime: delta)
        Self.spring.update(
            value: &dx, velocity: &dvx, target: Double(dismissTranslationTarget.x), deltaTime: delta
        )
        Self.spring.update(
            value: &dy, velocity: &dvy, target: Double(dismissTranslationTarget.y), deltaTime: delta
        )
        Self.spring.update(
            value: &pinch, velocity: &vp, target: Double(dismissPinchTarget), deltaTime: delta
        )

        velocity = CGPoint(x: vx, y: vy)
        scaleVelocity = CGFloat(vs)
        dismissVelocity = CGPoint(x: dvx, y: dvy)
        dismissPinchVelocity = CGFloat(vp)
        dismissTranslation = CGPoint(x: dx, y: dy)
        dismissPinch = CGFloat(pinch)
        apply(MediaZoom(scale: CGFloat(scale), offset: CGPoint(x: x, y: y)))
        publishDismissProgress()

        let settled = abs(x - Double(target.offset.x)) < 0.4
            && abs(y - Double(target.offset.y)) < 0.4
            && abs(scale - Double(target.scale)) < 0.002
            && abs(dx - Double(dismissTranslationTarget.x)) < 0.4
            && abs(dy - Double(dismissTranslationTarget.y)) < 0.4
            && abs(pinch - Double(dismissPinchTarget)) < 0.002
            && abs(vx) < 8 && abs(vy) < 8 && abs(vs) < 0.05
            && abs(dvx) < 8 && abs(dvy) < 8 && abs(vp) < 0.05
        guard settled else { return }
        stopSettle()
        velocity = .zero
        scaleVelocity = 0
        dismissVelocity = .zero
        dismissPinchVelocity = 0
        dismissTranslation = dismissTranslationTarget
        dismissPinch = dismissPinchTarget
        apply(target)
        publishDismissProgress()
    }
}
