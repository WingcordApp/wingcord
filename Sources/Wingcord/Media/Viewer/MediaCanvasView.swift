import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// The viewer's stage: one picture on a layer, its neighbours beside it, and
/// every gesture the reader can make at it.
///
/// **Nothing here ever redraws.** A still is a `CALayer`'s `contents`, a
/// filmstrip is that property assigned a different frame, a video is an
/// `AVPlayerLayer` — so zoom, pan, paging, the flights in and out and every
/// spring that settles them cost property writes and no display pass at all.
///
/// **Every gesture is handled here rather than by SwiftUI**, a deliberate trade
/// of code for feel: `DragGesture` gives no release velocity to hand off
/// (`INVARIANTS.md` §3), a `ScrollView` cannot zoom about the fingers, and
/// neither sees `magnify(with:)`, `smartMagnify(with:)` or a wheel. One
/// responder sees all of them, with no doubt about which recogniser won.
///
/// The vocabulary — every picture on this platform answers to it:
///
/// | Gesture | Zoomed in | At fit |
/// | --- | --- | --- |
/// | Pinch | zoom, about the fingers | shrink, then back into the thumbnail |
/// | Two fingers sideways | pan | page through the message's pictures |
/// | Two fingers up or down | pan | take the picture away |
/// | Drag | pan | — |
/// | Double click / two-finger double tap | back to fit | zoom to actual size |
/// | ⌘ + wheel, or a mouse wheel | zoom | zoom |
///
/// What it exists to get right (apple-design, REDESIGN.md D8–D9):
///
///  1. **1:1 tracking** from the grab, for pans, pages and throws alike.
///  2. **Resistance, not a wall**, past any bound.
///  3. **Velocity handoff**: whatever a release starts — a settle, a page, a
///     flight home — starts at the fingers' speed, one spring per axis.
///  4. **Projection**: a page turns, and a throw closes, by where the gesture
///     is *going*.
///  5. **Interruptible**: a new gesture takes the values on screen, mid-spring.
///  6. **The picture keeps its place in the world**: it grows out of its
///     thumbnail and returns into it, cropped and cornered as the cell draws
///     it (a shared element transition), and its box in the transcript is
///     empty while it is out.
final class MediaCanvasView: NSView {

    /// How the content fills the stage.
    enum Fill {
        /// Zoomable and pannable, laid out from the picture's own pixel size.
        case transformable(CGSize)
        /// A video, letterboxed by its layer inside the band the chrome leaves
        /// it (`letterboxInsets`).
        ///
        /// **Video does not zoom.** Its natural size arrives from the player a
        /// beat after the first frame, so a stage laid out from a size it does
        /// not have yet would show a frame at the wrong aspect on every video
        /// ever opened. `resizeAspect` on the band is right before the size is
        /// known and after.
        case letterboxed
    }

    /// A picture beside the one on stage — what slides in when the reader
    /// pages.
    struct Neighbor {
        var identity: AnyHashable
        var image: CGImage?
        var pixelSize: CGSize
        var isVideo: Bool
    }

    // MARK: Layers

    /// The window the picture is seen through: the whole stage at rest, the
    /// thumbnail's rounded box at home, everything between during a flight.
    private let clipLayer = CALayer()
    private let contentLayer = CALayer()
    private var playerLayer: AVPlayerLayer?
    private let previousLayer = CALayer()
    private let nextLayer = CALayer()

    // MARK: Content

    private var fill: Fill = .letterboxed
    private var film: AnimatedImage?
    private var shownFrame = -1
    /// The bitmap currently in `contentLayer.contents`, kept alongside it —
    /// reading a `CGImage` back out of `contents` is a force cast on a value
    /// the layer is free to have replaced.
    private var shownImage: CGImage?
    /// Which item the picture on stage belongs to. A page swaps a neighbour's
    /// picture in before the item arrives, and the item must not then replace
    /// it with a smaller poster.
    private(set) var contentIdentity: AnyHashable?
    /// A video's own size, when it is known — what its picture is fitted to in
    /// a flight and beside a page.
    private var videoSize: CGSize = .zero
    /// The band a video keeps clear of the chrome above and below it. A
    /// picture runs to the window's edges; a video cannot, because glass over
    /// playing video churns and the chrome must sit on the scrim (§4).
    var letterboxInsets = NSEdgeInsets(top: 76, left: 0, bottom: 76, right: 0) {
        didSet { if !NSEdgeInsetsEqual(oldValue, letterboxInsets) { needsLayout = true } }
    }

    private var activeLayer: CALayer { playerLayer ?? contentLayer }

    // MARK: Zoom

    private(set) var zoom = MediaZoom.fit
    private var target = MediaZoom.fit
    private var velocity = CGPoint.zero
    private var scaleVelocity: CGFloat = 0

    /// Reduce Motion: every settle becomes an assignment, every flight and page
    /// a cross-fade.
    var reducesMotion = false

    // MARK: Dismissal

    /// How far the picture has been thrown, and how far squeezed. Both feed one
    /// progress number, because the reader is doing one thing.
    private var dismissTranslation = CGPoint.zero
    private var dismissPinch: CGFloat = 1
    private var dismissTranslationTarget = CGPoint.zero
    private var dismissPinchTarget: CGFloat = 1
    private var dismissVelocity = CGPoint.zero
    private var dismissPinchVelocity: CGFloat = 0
    private var reportedProgress: Double = 0

    /// A squeeze past this closes. Loose enough that a deliberate pinch always
    /// lands and tight enough that brushing the trackpad never does.
    private static let dismissPinchThreshold: CGFloat = 0.86
    /// And a throw past this, measured where the flick is *going* — §3.
    private static let dismissThrowThreshold: CGFloat = 130

    // MARK: Paging

    private var previous: Neighbor?
    private var next: Neighbor?
    /// Whether there is anything to page to.
    var canPage = false
    private var pageOffset: CGFloat = 0
    private var pageTarget: CGFloat = 0
    private var pageVelocity: CGFloat = 0
    /// ±1 while a committed page slides home, 0 otherwise.
    private var committingPage = 0
    /// The room between two pages.
    private static let pageGap: CGFloat = 32
    private var pageStride: CGFloat { bounds.width + Self.pageGap }

    // MARK: The two-finger gesture at fit

    private var axis: GestureAxis = .undecided
    private var gestureTranslation = CGPoint.zero
    private var gestureVelocity = GestureVelocity()
    private var pageGrab: CGFloat = 0
    private var dismissGrab = CGPoint.zero

    // MARK: Flights

    private var flight: MediaFlight?
    private var flightIsOpening = true
    private var flightProgress: CGFloat = 1
    private var flightProgressVelocity: CGFloat = 0
    private var flightCenter = CGPoint.zero
    private var flightCenterVelocity = CGPoint.zero
    private var flightCenterTarget = CGPoint.zero
    private var flightSpring = Motion.reposition.spring
    /// The thumbnail the picture opens from, asked for once the stage has a
    /// size — the first layout, which is before the first frame is drawn.
    private var pendingOpen: (() -> MediaSources.Thumbnail?)?
    private(set) var isClosing = false
    private var reportedPresence: Double = -1

    // MARK: Playback

    /// The film's own playhead, in seconds. **Its own, not the shared
    /// clock's**: the reader can pause and scrub, so the clock supplies the
    /// tick and this accumulates it.
    private(set) var playhead: Double = 0
    private var lastTick: Double?
    var isFilmPlaying = true
    var filmRate: Double = 1

    // MARK: Callbacks

    /// The zoom landed somewhere new. Guarded on a real change.
    var onZoomChange: ((CGFloat) -> Void)?
    /// The shown frame changed. Bounded by the film's rate, not the display's.
    var onFrameChange: ((Int) -> Void)?
    /// 0 at rest, 1 at the point of no return, while a throw or a squeeze is
    /// under the fingers.
    var onDismissProgress: ((Double) -> Void)?
    /// How far the stage is in: 0 at home, 1 open. The scrim and the chrome
    /// follow it through both flights.
    var onPresence: ((Double) -> Void)?
    /// A gesture asked for the viewer to close, at this release velocity.
    var onRequestClose: ((CGPoint) -> Void)?
    /// The flight home landed: the viewer may go.
    var onClosed: (() -> Void)?
    /// A page turned: -1 to the previous picture, 1 to the next.
    var onPage: ((Int) -> Void)?
    /// A click beside the media rather than on it.
    var onBackgroundClick: (() -> Void)?
    /// A click on a video itself — play or pause.
    var onContentClick: (() -> Void)?

    // MARK: The system player, the light, Live Text (decisions 24–26)

    /// A video plays in AVKit's own player once it's still; a clip and a
    /// GIF's MP4 keep the viewer's (their bars carry marks, or nothing).
    var usesSystemPlayer = false {
        didSet {
            guard usesSystemPlayer != oldValue else { return }
            if !usesSystemPlayer { systemPlayer.detach() }
            layoutContent()
        }
    }
    /// Cinema mode's glow behind the picture.
    var isCinemaOn = false {
        didSet { if isCinemaOn != oldValue { layoutContent() } }
    }
    /// Live Text over a still.
    var isLiveTextOn = false {
        didSet { if isLiveTextOn != oldValue { layoutContent() } }
    }
    private lazy var systemPlayer = ViewerSystemPlayer(host: self)
    private let ambient = ViewerAmbientLight()
    private lazy var liveText = ViewerLiveText(host: self)

    /// Nothing is moving the picture: no flight, page, throw or squeeze.
    private var isAtRest: Bool {
        flight == nil && !isClosing && pageOffset == 0 && committingPage == 0
            && dismissProgress < 0.001 && pendingOpen == nil
    }

    private func layoutExtras() {
        let atRest = isAtRest
        if case .letterboxed = fill, usesSystemPlayer, let player = playerLayer?.player {
            systemPlayer.show(player, frame: restingContent, visible: atRest)
        } else {
            systemPlayer.hide()
        }
        // The light follows the picture through a throw and a page; a flight
        // takes it away (the scrim is fading there anyway).
        let showsLight = isCinemaOn && flight == nil && !isClosing && pendingOpen == nil
        ambient.layout(around: contentLayer.frame, visible: showsLight, animated: !reducesMotion)
        liveText.update(
            image: shownImage,
            frame: contentLayer.frame,
            active: isLiveTextOn && isTransformable && film == nil && atRest
        )
    }

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.drawsAsynchronously = false
        for content in [contentLayer, previousLayer, nextLayer] {
            content.contentsGravity = .resize
            content.magnificationFilter = .linear
            content.minificationFilter = .trilinear
            // No implicit animation on anything this view assigns: Core
            // Animation would cross-fade every frame of a GIF and ease every
            // point of a 1:1 drag a quarter of a second behind the fingers.
            content.actions = Self.silentActions
        }
        clipLayer.masksToBounds = true
        clipLayer.cornerCurve = .continuous
        clipLayer.actions = Self.silentActions
        clipLayer.addSublayer(previousLayer)
        clipLayer.addSublayer(nextLayer)
        clipLayer.addSublayer(contentLayer)
        layer?.addSublayer(clipLayer)
        // Cinema mode's light, behind the picture (decision 25). Its blur is a
        // Core Image filter on a layer, which the view has to allow.
        layerUsesCoreImageFilters = true
        layer?.insertSublayer(ambient.layer, below: clipLayer)
        // Nothing is shown until the opening flight has somewhere to start.
        clipLayer.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private static let silentActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
        "frame": NSNull(), "opacity": NSNull(), "transform": NSNull(),
        "cornerRadius": NSNull(), "hidden": NSNull(),
    ]

    /// Key events belong to SwiftUI, which owns Escape, the arrows and space.
    override var acceptsFirstResponder: Bool { false }
    /// A click into an inactive window both activates it and starts the drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Releases the link and the clock subscription. Idempotent.
    func tearDown() {
        systemPlayer.detach()
        ambient.tearDown()
        liveText.tearDown()
        stopSettle()
        unsubscribeFromClock()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        pendingOpen = nil
        onZoomChange = nil
        onFrameChange = nil
        onDismissProgress = nil
        onPresence = nil
        onRequestClose = nil
        onClosed = nil
        onPage = nil
        onBackgroundClick = nil
        onContentClick = nil
    }

    // MARK: Installing content

    func setStill(_ image: CGImage?, pixelSize: CGSize, identity: AnyHashable? = nil) {
        film = nil
        shownFrame = -1
        unsubscribeFromClock()
        shownImage = image
        if let identity { contentIdentity = identity }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        ambient.setImage(image)
        CATransaction.commit()
        setFill(pixelSize.width > 0 ? .transformable(pixelSize) : .letterboxed)
    }

    /// A sharper copy of the picture already on stage, keeping the zoom and
    /// pan the reader is at — the close-up arriving under a pinch.
    ///
    /// **Not `setStill`**, which starts a new picture fitted: the close-up
    /// arrives because the reader zoomed past 1.9×, and installing it as a new
    /// picture snapped them back to fit. The same picture at more pixels has
    /// the same shape, so its fitted frame — and every zoom measured from it —
    /// is unchanged; only the ceiling the pixel count sets moves.
    func sharpen(_ image: CGImage) {
        // A film on stage is the moving picture itself; a still arriving for
        // it is a stale answer.
        guard film == nil else { return }
        shownImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        ambient.setImage(image)
        CATransaction.commit()
        if case .transformable = fill {
            fill = .transformable(CGSize(width: image.width, height: image.height))
            onZoomChange?(zoom.scale)
        }
    }

    /// A video's poster, under the player until it has a frame of its own.
    func showPoster(_ image: CGImage?, identity: AnyHashable) {
        shownImage = image
        contentIdentity = identity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = image
        ambient.setImage(image)
        CATransaction.commit()
        layoutContent()
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

    /// Installs the video layer, or takes it away. The poster already on the
    /// content layer stays under it until the player has a frame to show.
    func setPlayer(_ player: AVPlayer?, videoSize size: CGSize = .zero) {
        guard let player else {
            playerLayer?.player = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            videoSize = .zero
            systemPlayer.detach()
            ambient.setPlayer(nil)
            return
        }
        videoSize = size
        ambient.setPlayer(player)
        if let playerLayer {
            if playerLayer.player !== player { playerLayer.player = player }
        } else {
            let created = AVPlayerLayer(player: player)
            created.videoGravity = .resizeAspect
            created.actions = Self.silentActions
            clipLayer.addSublayer(created)
            playerLayer = created
        }
        film = nil
        unsubscribeFromClock()
        setFill(.letterboxed)
    }

    private func setFill(_ newFill: Fill) {
        fill = newFill
        // A new picture starts fitted: carrying the last one's zoom over lands
        // the reader somewhere in the middle of the next at 4x.
        stopZoomSettle()
        zoom = .fit
        target = .fit
        velocity = .zero
        scaleVelocity = 0
        if !isClosing { clearDismissState() }
        layoutContent()
        onZoomChange?(1)
    }

    /// The pictures either side, for paging. Nil where there is none.
    func setNeighbors(previous: Neighbor?, next: Neighbor?) {
        guard committingPage == 0 else { return }
        self.previous = previous
        self.next = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previousLayer.contents = previous?.image
        nextLayer.contents = next?.image
        previousLayer.backgroundColor = previous.map { $0.image == nil ? Self.placeholderGround : nil } ?? nil
        nextLayer.backgroundColor = next.map { $0.image == nil ? Self.placeholderGround : nil } ?? nil
        CATransaction.commit()
        layoutContent()
    }

    /// A sharper picture for a neighbour that is already laid beside the stage.
    func updateNeighbor(_ identity: AnyHashable, image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if previous?.identity == identity {
            previous?.image = image
            previousLayer.contents = image
            previousLayer.backgroundColor = nil
        }
        if next?.identity == identity {
            next?.image = image
            nextLayer.contents = image
            nextLayer.backgroundColor = nil
        }
        CATransaction.commit()
    }

    private static let placeholderGround = CGColor(gray: 0.16, alpha: 1)

    // MARK: Geometry

    private var geometry: MediaStageGeometry {
        stillGeometry(for: {
            if case .transformable(let size) = fill { return size }
            return bounds.size
        }())
    }

    /// The stage for a still of this pixel size: kept clear of the controls
    /// (the bands a video is letterboxed into, and a margin either side) and
    /// never blown up past its own size — `MediaStageGeometry.fitInset`.
    private func stillGeometry(for pixels: CGSize) -> MediaStageGeometry {
        MediaStageGeometry(
            contentPixels: pixels,
            viewport: bounds.size,
            displayScale: window?.backingScaleFactor ?? 2,
            fitInset: CGSize(
                width: Self.stillSideMargin,
                height: max(letterboxInsets.top, letterboxInsets.bottom)
            ),
            capsAtNaturalSize: true
        )
    }

    /// A still's margin from the stage's left and right edges at fit.
    private static let stillSideMargin: CGFloat = 40

    var isTransformable: Bool {
        if case .transformable = fill { return true }
        return false
    }

    var maximumZoom: CGFloat { geometry.maximumScale }

    /// The band a video is letterboxed into.
    private var videoArea: CGRect {
        CGRect(
            x: bounds.minX + letterboxInsets.left,
            y: bounds.minY + letterboxInsets.bottom,
            width: max(1, bounds.width - letterboxInsets.left - letterboxInsets.right),
            height: max(1, bounds.height - letterboxInsets.top - letterboxInsets.bottom)
        )
    }

    /// Where the picture on stage sits at rest, without the gestures' offsets.
    private var restingContent: CGRect {
        switch fill {
        case .transformable:
            return geometry.contentRect(zoom)
        case .letterboxed:
            guard videoSize.width > 0 else { return videoArea }
            return MediaFlight.aspectFit(videoSize, in: videoArea)
        }
    }

    /// Where a neighbour sits at fit, before the page offset.
    private func restingFrame(of neighbor: Neighbor) -> CGRect {
        neighbor.isVideo
            ? MediaFlight.aspectFit(neighbor.pixelSize, in: videoArea)
            : stillGeometry(for: neighbor.pixelSize).contentRect(.fit)
    }

    override func layout() {
        super.layout()
        startPendingOpen()
        layoutContent()
    }

    /// The one place a layer's frame is written, inside a transaction with
    /// actions off.
    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let flight {
            let frame = flight.frame(progress: flightProgress, contentCenter: flightCenter)
            clipLayer.frame = frame.clip
            clipLayer.cornerRadius = frame.cornerRadius
            clipLayer.opacity = Float(frame.alpha)
            let content = frame.content.offsetBy(dx: -frame.clip.minX, dy: -frame.clip.minY)
            contentLayer.frame = content
            playerLayer?.frame = content
            previousLayer.isHidden = true
            nextLayer.isHidden = true
            layoutExtras()
            return
        }

        clipLayer.frame = bounds
        clipLayer.cornerRadius = 0
        // Hidden until the opening flight has a thumbnail to start from.
        clipLayer.opacity = pendingOpen == nil ? 1 : 0
        let shift = CGPoint(x: pageOffset, y: 0)
        switch fill {
        case .transformable:
            contentLayer.frame = dismissTransformed(geometry.contentRect(zoom)).offsetBy(dx: shift.x, dy: shift.y)
        case .letterboxed:
            let picture = dismissTransformed(restingContent).offsetBy(dx: shift.x, dy: shift.y)
            contentLayer.frame = picture
            // The player letterboxes itself in its band; moved with the throw.
            playerLayer?.frame = dismissTransformed(videoArea).offsetBy(dx: shift.x, dy: shift.y)
        }
        let showsNeighbors = pageOffset != 0 || committingPage != 0
        previousLayer.isHidden = !showsNeighbors || previous == nil
        nextLayer.isHidden = !showsNeighbors || next == nil
        if let previous {
            previousLayer.frame = restingFrame(of: previous).offsetBy(dx: pageOffset - pageStride, dy: 0)
        }
        if let next {
            nextLayer.frame = restingFrame(of: next).offsetBy(dx: pageOffset + pageStride, dy: 0)
        }
        layoutExtras()
    }

    /// The dismissal, applied last: a squeeze about the picture's own centre
    /// and a translation, so it reads as the picture being taken away rather
    /// than the zoom changing.
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

    // MARK: Flights

    /// Opens the stage out of `home`'s thumbnail as soon as there is a stage
    /// to open onto — or materialises it where the thumbnail is out of sight.
    func prepareOpen(home: @escaping () -> MediaSources.Thumbnail?) {
        pendingOpen = home
        startPendingOpen()
    }

    private func startPendingOpen() {
        guard let home = pendingOpen, bounds.width > 1, bounds.height > 1, window != nil else { return }
        pendingOpen = nil
        let stage = MediaFlight.stage(content: restingContent)
        let from: MediaFlight.Frame
        if !reducesMotion, let thumbnail = home(), let box = homeBox(thumbnail) {
            from = MediaFlight.home(
                box: box,
                cornerRadius: thumbnail.cornerRadius,
                pictureSize: pictureSize,
                cropsToFill: thumbnail.cropsToFill
            )
            // No gesture began it: critically damped, the reposition class.
            flightSpring = Motion.reposition.spring
        } else {
            from = reducesMotion
                ? MediaFlight.Frame(clip: stage.clip, content: stage.content, cornerRadius: 0, alpha: 0)
                : MediaFlight.dissolve(content: stage.content)
            flightSpring = reducesMotion ? Self.reducedSpring : Motion.panel.spring
        }
        startFlight(MediaFlight(from: from, to: stage), opening: true, velocity: .zero, morphVelocity: 0)
    }

    /// Flies the picture home — into its thumbnail where it is on screen, or
    /// away where it is not — at the gesture's release velocity, and says so
    /// when it lands (`onClosed`).
    func close(home: MediaSources.Thumbnail?, velocity released: CGPoint = .zero, morphVelocity: CGFloat = 0) {
        guard !isClosing else { return }
        isClosing = true
        pendingOpen = nil
        stopZoomSettle()
        // Where the picture is now, on screen — the flight starts from what
        // the reader sees, never from where anything was heading (§3).
        let current = currentFrame()
        let destination: MediaFlight.Frame
        if !reducesMotion, let home, let box = homeBox(home) {
            destination = MediaFlight.home(
                box: box,
                cornerRadius: home.cornerRadius,
                pictureSize: pictureSize,
                cropsToFill: home.cropsToFill
            )
            // A release that carried force lands with a little give; one that
            // did not, without — `Motion.momentum` only with a handoff.
            let hasForce = hypot(released.x, released.y) > 80 || abs(morphVelocity) > 0.5
            flightSpring = hasForce ? Motion.momentum.spring : Motion.reposition.spring
        } else {
            destination = reducesMotion
                ? MediaFlight.Frame(clip: current.clip, content: current.content, cornerRadius: current.cornerRadius, alpha: 0)
                : MediaFlight.dissolve(content: current.content)
            flightSpring = reducesMotion ? Self.reducedSpring : Motion.panel.spring
        }
        clearDismissState()
        pageOffset = 0
        pageVelocity = 0
        startFlight(
            MediaFlight(from: current, to: destination),
            opening: false,
            velocity: released,
            morphVelocity: morphVelocity
        )
    }

    /// The thumbnail's box in this view's coordinates.
    private func homeBox(_ thumbnail: MediaSources.Thumbnail) -> CGRect? {
        guard let window, thumbnail.window === window else { return nil }
        let box = convert(thumbnail.frame, from: nil)
        guard box.width > 1, box.height > 1 else { return nil }
        return box
    }

    /// The picture's own shape, for fitting it into a thumbnail's box.
    private var pictureSize: CGSize {
        switch fill {
        case .transformable(let size): return size
        case .letterboxed: return videoSize.width > 0 ? videoSize : restingContent.size
        }
    }

    /// What is on screen right now, as a flight's end.
    private func currentFrame() -> MediaFlight.Frame {
        if let flight {
            return flight.frame(progress: flightProgress, contentCenter: flightCenter)
        }
        let content = dismissTransformed(restingContent).offsetBy(dx: pageOffset, dy: 0)
        // A picture zoomed past the stage is seen through the stage.
        let clip = content.intersection(bounds).isNull ? content : content.intersection(bounds)
        return MediaFlight.Frame(clip: clip, content: content, cornerRadius: 0, alpha: 1)
    }

    private func startFlight(_ newFlight: MediaFlight, opening: Bool, velocity released: CGPoint, morphVelocity: CGFloat) {
        flight = newFlight
        flightIsOpening = opening
        flightProgress = 0
        flightProgressVelocity = morphVelocity
        flightCenter = CGPoint(x: newFlight.from.content.midX, y: newFlight.from.content.midY)
        flightCenterTarget = CGPoint(x: newFlight.to.content.midX, y: newFlight.to.content.midY)
        flightCenterVelocity = released
        previousLayer.isHidden = true
        nextLayer.isHidden = true
        layoutContent()
        publishPresence()
        startSettle()
    }

    private func finishFlight() {
        guard let flight else { return }
        flightProgress = 1
        flightCenter = flightCenterTarget
        flightProgressVelocity = 0
        flightCenterVelocity = .zero
        if flightIsOpening {
            self.flight = nil
            layoutContent()
            publishPresence()
        } else {
            // Left where it landed — over the thumbnail, which comes back in
            // the same pass as the stage goes.
            _ = flight
            publishPresence()
            onClosed?()
        }
    }

    /// The fade a flight becomes under Reduce Motion: quick, and with nothing
    /// to overshoot.
    private static let reducedSpring = Spring(duration: Motion.reducedDuration, bounce: 0)

    private func publishPresence() {
        let presence: Double
        if flight != nil {
            presence = MediaFlight.presence(progress: flightProgress, isOpening: flightIsOpening)
        } else {
            presence = isClosing ? 0 : 1
        }
        guard abs(presence - reportedPresence) > 0.01 || presence == 0 || presence == 1 else { return }
        guard presence != reportedPresence else { return }
        reportedPresence = presence
        onPresence?(presence)
    }

    // MARK: Commands

    /// Zooms about the stage's centre — the zoom bar's slider and buttons.
    func setZoom(_ scale: CGFloat, animated: Bool = true) {
        guard isTransformable, flight == nil else { return }
        zoomTo(scale, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: animated)
    }

    func reset() {
        guard isTransformable, flight == nil else { return }
        settle(to: .fit)
    }

    /// Fit ↔ actual size, about the stage's centre — space; a double click
    /// anchors at the pointer instead.
    func toggleZoom() {
        guard isTransformable, flight == nil else { return }
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

    /// Turns the page — the arrows, the chevrons — sliding the next picture in
    /// from the side it is on (a direction-aware transition), or cross-fading
    /// under Reduce Motion. A page already sliding lands at once first, so a
    /// held arrow walks the gallery rather than stalling it.
    func page(by direction: Int) {
        guard canPage, flight == nil, !isClosing, direction != 0 else { return }
        if committingPage != 0 { finishPage() }
        guard (direction > 0 ? next : previous) != nil else {
            onPage?(direction)
            return
        }
        if zoom.scale > 1.001 || dismissTranslation != .zero {
            stopZoomSettle()
            clearDismissState()
            apply(.fit)
        }
        guard !reducesMotion else {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.reducedDuration
            clipLayer.add(fade, forKey: "page")
            committingPage = direction > 0 ? 1 : -1
            finishPage()
            return
        }
        committingPage = direction > 0 ? 1 : -1
        pageTarget = -CGFloat(committingPage) * pageStride
        pageVelocity = 0
        startSettle()
    }

    /// The incoming picture takes the stage: its layer's picture becomes the
    /// content, the offset goes back to zero, and the item follows.
    private func finishPage() {
        let direction = committingPage
        committingPage = 0
        pageOffset = 0
        pageTarget = 0
        pageVelocity = 0
        guard direction != 0, let incoming = direction > 0 ? next : previous else {
            layoutContent()
            return
        }
        if incoming.isVideo {
            // The player arrives with the item; until then its poster.
            shownImage = incoming.image
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.contents = incoming.image
            ambient.setImage(incoming.image)
            CATransaction.commit()
            contentIdentity = incoming.identity
            film = nil
            unsubscribeFromClock()
            playerLayer?.player = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            videoSize = incoming.pixelSize
            setFill(.letterboxed)
        } else {
            setStill(incoming.image, pixelSize: incoming.pixelSize, identity: incoming.identity)
        }
        previous = nil
        next = nil
        previousLayer.contents = nil
        nextLayer.contents = nil
        layoutContent()
        onPage?(direction)
    }

    // MARK: Film

    private func subscribeToClock() {
        // `throughScroll`: in this surface the moving picture IS the content,
        // and the gate is process-wide.
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

    /// The frame on screen — for an animation, the frame the reader is looking
    /// at. Nil for video, whose frames belong to the decoder.
    func currentImage() -> CGImage? { shownImage }

    /// Parks the playhead on one frame — the scrubber.
    func seekFilm(toFrame index: Int) {
        guard let film, film.frameCount > 0 else { return }
        let clamped = min(film.frameCount - 1, max(0, index))
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
        ambient.setImage(shownImage)
        CATransaction.commit()
        onFrameChange?(index)
    }

    // MARK: Pointer

    private var dragOrigin: CGPoint?
    private var dragStartOffset = CGPoint.zero
    private var dragVelocity = GestureVelocity()

    override func resetCursorRects() {
        guard isTransformable, zoom.scale > 1.001 else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard flight == nil, !isClosing else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard isTransformable else {
            // Video: the letterboxed picture is what takes a click.
            guard let playerLayer, playerLayer.convert(playerLayer.videoRect, to: layer).contains(point) else {
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
        // Interrupting takes the value on screen, never the target — §3.
        stopZoomSettle()
        dragOrigin = point
        dragStartOffset = zoom.offset
        dragVelocity.reset()
        dragVelocity.add(point, at: event.timestamp)
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
        dragVelocity.add(point, at: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        NSCursor.pop()
        let released = dragVelocity.velocity
        let rest = geometry.projectedRest(from: zoom.offset, velocity: released, scale: zoom.scale)
        settle(to: MediaZoom(scale: zoom.scale, offset: rest), velocity: released)
    }

    // MARK: Trackpad

    override func scrollWheel(with event: NSEvent) {
        guard flight == nil, !isClosing else { return }
        // A wheel with Command, or any wheel with no precise deltas, zooms.
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

        // Zoomed in, two fingers pan — what they do over every picture here.
        if isTransformable, zoom.scale > 1.001, axis == .undecided {
            // Momentum after a release is the settle's to carry, not the
            // pan's: a second push would double the throw.
            guard event.momentumPhase.isEmpty else { return }
            stopZoomSettle()
            let proposed = CGPoint(
                x: zoom.offset.x + event.scrollingDeltaX,
                y: zoom.offset.y - event.scrollingDeltaY
            )
            apply(MediaZoom(scale: zoom.scale, offset: geometry.resisted(proposed, scale: zoom.scale)))
            if event.phase == .began { dragVelocity.reset() }
            dragVelocity.add(zoom.offset, at: event.timestamp)
            if event.phase == .ended || event.phase == .cancelled {
                let released = dragVelocity.velocity
                settle(
                    to: MediaZoom(
                        scale: zoom.scale,
                        offset: geometry.projectedRest(from: zoom.offset, velocity: released, scale: zoom.scale)
                    ),
                    velocity: released
                )
            }
            return
        }
        twoFingerGesture(event)
    }

    /// Two fingers at fit: sideways pages, up or down takes the picture away —
    /// decided once the fingers have moved ~10 points, then tracked 1:1 to the
    /// release, which projects and hands its speed on.
    private func twoFingerGesture(_ event: NSEvent) {
        switch event.phase {
        case .began:
            // Grab whatever is moving, where it is.
            stopSettle()
            axis = .undecided
            gestureTranslation = .zero
            gestureVelocity.reset()
            pageGrab = pageOffset
            dismissGrab = dismissTranslation
            if committingPage != 0 {
                // A page in flight, caught: it is the reader's again.
                committingPage = 0
            }
        case .changed:
            gestureTranslation.x += event.scrollingDeltaX
            gestureTranslation.y -= event.scrollingDeltaY
            gestureVelocity.add(gestureTranslation, at: event.timestamp)
            if axis == .undecided {
                axis = GestureAxis.resolve(gestureTranslation)
                // A page caught mid-slide stays a page.
                if axis == .dismissing, pageGrab != 0 { axis = .paging }
            }
            switch axis {
            case .paging:
                let proposed = pageGrab + gestureTranslation.x
                pageOffset = canPage
                    ? proposed
                    : Motion.rubberBand(offset: proposed, limit: max(1, bounds.width))
                layoutContent()
            case .dismissing:
                dismissTranslation = CGPoint(x: dismissGrab.x + gestureTranslation.x, y: dismissGrab.y + gestureTranslation.y)
                // The squeeze follows the throw: one gesture, one progress.
                let distance = hypot(dismissTranslation.x, dismissTranslation.y)
                dismissPinch = 1 - min(0.3, distance / 1200)
                publishDismissProgress()
                layoutContent()
            case .undecided:
                break
            }
        case .ended, .cancelled:
            let released = gestureVelocity.velocity
            switch axis {
            case .paging:
                let landing = MediaPaging.landing(
                    offset: pageOffset, velocity: released.x, pageWidth: pageStride, canPage: canPage
                )
                if landing != 0, (landing > 0 ? next : previous) != nil {
                    committingPage = landing
                    pageTarget = -CGFloat(landing) * pageStride
                } else {
                    pageTarget = 0
                }
                pageVelocity = released.x
                startSettle()
            case .dismissing:
                let projected = CGPoint(
                    x: Motion.projectedPosition(from: dismissTranslation.x, velocity: released.x),
                    y: Motion.projectedPosition(from: dismissTranslation.y, velocity: released.y)
                )
                if hypot(projected.x, projected.y) >= Self.dismissThrowThreshold {
                    reportedProgress = 1
                    onDismissProgress?(1)
                    onRequestClose?(released)
                } else {
                    springDismissBack(velocity: released)
                }
            case .undecided:
                // Let go before choosing a way: whatever was caught mid-air
                // goes home.
                if pageOffset != 0 {
                    pageTarget = 0
                    pageVelocity = 0
                    startSettle()
                } else if dismissTranslation != .zero || dismissPinch < 0.999 {
                    springDismissBack(velocity: .zero)
                }
            }
            axis = .undecided
        default:
            // Momentum after the release: the springs carry it.
            break
        }
    }

    override func magnify(with event: NSEvent) {
        guard flight == nil, !isClosing else { return }
        switch event.phase {
        case .began:
            stopSettle()
            pinchBaseScale = zoom.scale
            pinchFactor = 1
            pinchVelocity.reset()
        case .changed:
            pinchFactor *= (1 + event.magnification)
            pinchVelocity.add(CGPoint(x: pinchFactor, y: 0), at: event.timestamp)
            let proposed = pinchBaseScale * pinchFactor
            if proposed >= 1 {
                // Back above fit: the dismissal is abandoned in the motion that
                // started it, which is what makes it feel cancellable.
                if dismissPinch < 1 {
                    dismissPinch = 1
                    dismissTranslation = .zero
                    publishDismissProgress()
                }
                guard isTransformable else { return }
                zoomTo(proposed, anchor: convert(event.locationInWindow, from: nil), animated: false)
                return
            }
            // Below fit, resisted, so the picture never simply collapses.
            dismissPinch = 1 - Motion.rubberBand(offset: 1 - proposed, limit: 0.9, coefficient: 1.6)
            publishDismissProgress()
            layoutContent()
        case .ended, .cancelled:
            if dismissPinch <= Self.dismissPinchThreshold {
                reportedProgress = 1
                onDismissProgress?(1)
                // The squeeze's rate carries into the flight's shrink.
                onRequestClose?(.zero)
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
    private var pinchVelocity = GestureVelocity()

    /// The pinch's own rate, scale per second, for the flight that follows it.
    var releasedPinchRate: CGFloat { pinchVelocity.velocity.x }

    /// The trackpad's two-finger double tap: the double click's gesture.
    override func smartMagnify(with event: NSEvent) {
        guard isTransformable, flight == nil, !isClosing else { return }
        zoomTo(
            zoom.scale > 1.001 ? 1 : geometry.toggleScale,
            anchor: convert(event.locationInWindow, from: nil),
            animated: true
        )
    }

    // MARK: Dismissal

    /// 0 at rest, 1 at the point of no return — one number for the scrim
    /// whichever way the reader is doing this.
    private var dismissProgress: Double {
        let fromPinch = Double((1 - dismissPinch) / (1 - Self.dismissPinchThreshold))
        let fromThrow = Double(hypot(dismissTranslation.x, dismissTranslation.y) / Self.dismissThrowThreshold)
        return min(1, max(0, max(fromPinch, fromThrow)))
    }

    private func publishDismissProgress() {
        let progress = dismissProgress
        // Reported on a change of a hundredth (§3): what reads it is a scrim
        // and a control bar.
        guard abs(progress - reportedProgress) > 0.01 || progress == 0 || progress == 1 else { return }
        reportedProgress = progress
        onDismissProgress?(progress)
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
        reportedProgress = 0
    }

    // MARK: The springs

    private var settleLink: CADisplayLink?
    private var lastSettleTime: CFTimeInterval?
    private static let spring = Motion.momentum.spring
    private static let pageSpring = Motion.reposition.spring
    private var isZoomSettling = false

    private func apply(_ newZoom: MediaZoom) {
        let scaleChanged = abs(newZoom.scale - zoom.scale) > 0.0005
        zoom = newZoom
        layoutContent()
        if scaleChanged {
            onZoomChange?(newZoom.scale)
            window?.invalidateCursorRects(for: self)
        }
    }

    private func settle(to landing: MediaZoom, velocity released: CGPoint = .zero) {
        target = landing
        guard !reducesMotion else {
            self.velocity = .zero
            scaleVelocity = 0
            apply(landing)
            return
        }
        velocity = released
        isZoomSettling = true
        startSettle()
    }

    /// Stops the zoom's settle where it is, leaving any page or flight moving.
    private func stopZoomSettle() {
        isZoomSettling = false
        target = zoom
        velocity = .zero
        scaleVelocity = 0
    }

    private func startSettle() {
        guard settleLink == nil else { return }
        lastSettleTime = nil
        let link = displayLink(target: self, selector: #selector(stepSettle(_:)))
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    /// Stops every spring where it is — a new gesture grabbing what moves.
    private func stopSettle() {
        settleLink?.invalidate()
        settleLink = nil
        lastSettleTime = nil
        isZoomSettling = false
        target = zoom
        velocity = .zero
        scaleVelocity = 0
        dismissTranslationTarget = dismissTranslation
        dismissPinchTarget = dismissPinch
        dismissVelocity = .zero
        dismissPinchVelocity = 0
        pageTarget = pageOffset
        pageVelocity = 0
    }

    @objc private func stepSettle(_ link: CADisplayLink) {
        let now = link.timestamp
        guard let lastSettleTime else {
            self.lastSettleTime = now
            return
        }
        // A step longer than a moment means the app was busy; a spring
        // integrated over it lands in one visible jump.
        let delta = min(now - lastSettleTime, 1.0 / 30)
        self.lastSettleTime = now
        var moving = false

        // The flight: the centre on one spring per axis, everything else on the
        // morph — so a throw keeps its sideways speed.
        if flight != nil {
            var x = Double(flightCenter.x), vx = Double(flightCenterVelocity.x)
            var y = Double(flightCenter.y), vy = Double(flightCenterVelocity.y)
            var p = Double(flightProgress), vp = Double(flightProgressVelocity)
            flightSpring.update(value: &x, velocity: &vx, target: Double(flightCenterTarget.x), deltaTime: delta)
            flightSpring.update(value: &y, velocity: &vy, target: Double(flightCenterTarget.y), deltaTime: delta)
            flightSpring.update(value: &p, velocity: &vp, target: 1, deltaTime: delta)
            flightCenter = CGPoint(x: x, y: y)
            flightCenterVelocity = CGPoint(x: vx, y: vy)
            flightProgress = CGFloat(p)
            flightProgressVelocity = CGFloat(vp)
            let settled = abs(p - 1) < 0.002 && abs(vp) < 0.05
                && abs(x - Double(flightCenterTarget.x)) < 0.4 && abs(y - Double(flightCenterTarget.y)) < 0.4
                && abs(vx) < 8 && abs(vy) < 8
            layoutContent()
            publishPresence()
            if settled {
                finishFlight()
            } else {
                moving = true
            }
        }

        // The page.
        if flight == nil, pageOffset != pageTarget || pageVelocity != 0 {
            var offset = Double(pageOffset), velocity = Double(pageVelocity)
            Self.pageSpring.update(value: &offset, velocity: &velocity, target: Double(pageTarget), deltaTime: delta)
            pageOffset = CGFloat(offset)
            pageVelocity = CGFloat(velocity)
            if abs(offset - Double(pageTarget)) < 0.4, abs(velocity) < 8 {
                pageOffset = pageTarget
                pageVelocity = 0
                if committingPage != 0 { finishPage() } else { layoutContent() }
            } else {
                layoutContent()
                moving = true
            }
        }

        // The zoom and pan, and the throw springing back.
        if flight == nil, isZoomSettling || dismissTranslation != dismissTranslationTarget
            || dismissPinch != dismissPinchTarget || dismissVelocity != .zero
        {
            var x = Double(zoom.offset.x), vx = Double(velocity.x)
            var y = Double(zoom.offset.y), vy = Double(velocity.y)
            var scale = Double(zoom.scale), vs = Double(scaleVelocity)
            var dx = Double(dismissTranslation.x), dvx = Double(dismissVelocity.x)
            var dy = Double(dismissTranslation.y), dvy = Double(dismissVelocity.y)
            var pinch = Double(dismissPinch), vpinch = Double(dismissPinchVelocity)
            if isZoomSettling {
                Self.spring.update(value: &x, velocity: &vx, target: Double(target.offset.x), deltaTime: delta)
                Self.spring.update(value: &y, velocity: &vy, target: Double(target.offset.y), deltaTime: delta)
                Self.spring.update(value: &scale, velocity: &vs, target: Double(target.scale), deltaTime: delta)
            }
            Self.spring.update(value: &dx, velocity: &dvx, target: Double(dismissTranslationTarget.x), deltaTime: delta)
            Self.spring.update(value: &dy, velocity: &dvy, target: Double(dismissTranslationTarget.y), deltaTime: delta)
            Self.spring.update(value: &pinch, velocity: &vpinch, target: Double(dismissPinchTarget), deltaTime: delta)
            velocity = CGPoint(x: vx, y: vy)
            scaleVelocity = CGFloat(vs)
            dismissVelocity = CGPoint(x: dvx, y: dvy)
            dismissPinchVelocity = CGFloat(vpinch)
            dismissTranslation = CGPoint(x: dx, y: dy)
            dismissPinch = CGFloat(pinch)
            apply(MediaZoom(scale: CGFloat(scale), offset: CGPoint(x: x, y: y)))
            publishDismissProgress()

            let zoomSettled = !isZoomSettling || (
                abs(x - Double(target.offset.x)) < 0.4 && abs(y - Double(target.offset.y)) < 0.4
                    && abs(scale - Double(target.scale)) < 0.002
                    && abs(vx) < 8 && abs(vy) < 8 && abs(vs) < 0.05
            )
            let dismissSettled = abs(dx - Double(dismissTranslationTarget.x)) < 0.4
                && abs(dy - Double(dismissTranslationTarget.y)) < 0.4
                && abs(pinch - Double(dismissPinchTarget)) < 0.002
                && abs(dvx) < 8 && abs(dvy) < 8 && abs(vpinch) < 0.05
            if zoomSettled, isZoomSettling {
                isZoomSettling = false
                velocity = .zero
                scaleVelocity = 0
                apply(target)
            }
            if dismissSettled {
                dismissVelocity = .zero
                dismissPinchVelocity = 0
                dismissTranslation = dismissTranslationTarget
                dismissPinch = dismissPinchTarget
                layoutContent()
                publishDismissProgress()
            }
            if !(zoomSettled && dismissSettled) { moving = true }
        }

        if !moving {
            settleLink?.invalidate()
            settleLink = nil
            self.lastSettleTime = nil
        }
    }
}
