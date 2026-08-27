import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// What the stage is showing, and every command the chrome can give it.
///
/// **The controls read this and never reach the view.** A representable's
/// `updateNSView` runs on every SwiftUI update, so driving a zoom or a scrub
/// through it would mean the whole viewer re-evaluating to move a slider — and
/// reading the view's state back the same way would be a feedback loop. The
/// canvas writes here as it settles; the bars read the one property each of them
/// draws, which is all Observation then has to invalidate.
@Observable
@MainActor
final class MediaStageController {

    // MARK: What the chrome draws

    /// A multiple of the fit scale: 1 shows the whole picture.
    private(set) var zoomScale: CGFloat = 1
    private(set) var maximumZoom: CGFloat = 3
    /// Whether this kind of media zooms at all. Video does not — see
    /// `MediaCanvasView.Fill`.
    private(set) var isZoomable = false

    /// Frames in the loaded filmstrip, or zero when the media does not move.
    ///
    /// **The honest answer to "is this a GIF".** A `.gif` that turns out to hold
    /// one frame is a still, and its controls should not appear; the decode is
    /// the only thing that knows.
    private(set) var frameCount = 0
    private(set) var frameIndex = 0

    private(set) var isLoading = true
    private(set) var failure: String?

    /// How far a dismiss gesture has travelled: 0 at rest, 1 at the point of no
    /// return.
    ///
    /// **Read by the scrim and the two bars and by nothing else.** Observation
    /// tracks per property, so a gesture in flight invalidates a fade and not
    /// the stage, the controls' contents or the info the bars are built from.
    private(set) var dismissProgress: Double = 0

    /// Playback, written by the chrome and forwarded to the canvas.
    var isFilmPlaying = true {
        didSet { canvas?.isFilmPlaying = isFilmPlaying }
    }

    var filmRate: Double = 1 {
        didSet { canvas?.filmRate = filmRate }
    }

    // MARK: Commands

    @ObservationIgnored weak var canvas: MediaCanvasView?

    func setZoom(_ scale: CGFloat) { canvas?.setZoom(scale) }
    func zoomIn() { canvas?.setZoom(min(maximumZoom, zoomScale * 1.6)) }
    func zoomOut() { canvas?.setZoom(max(1, zoomScale / 1.6)) }
    func resetZoom() { canvas?.reset() }
    func toggleZoom() { canvas?.toggleZoom() }
    func seekFilm(toFrame index: Int) { canvas?.seekFilm(toFrame: index) }
    /// The frame on screen, for the pasteboard.
    func currentImage() -> CGImage? { canvas?.currentImage() }

    // MARK: Written by the stage

    fileprivate func report(zoom: CGFloat, maximum: CGFloat, zoomable: Bool) {
        // A `@State`-shaped write of an equal value still invalidates every
        // reader, and the settle reports one of these per frame.
        if abs(zoomScale - zoom) > 0.0005 { zoomScale = zoom }
        if abs(maximumZoom - maximum) > 0.0005 { maximumZoom = maximum }
        if isZoomable != zoomable { isZoomable = zoomable }
    }

    fileprivate func report(frame: Int) {
        guard frameIndex != frame else { return }
        frameIndex = frame
    }

    fileprivate func report(frameCount count: Int) {
        guard frameCount != count else { return }
        frameCount = count
    }

    fileprivate func report(loading: Bool, failure reason: String?) {
        if isLoading != loading { isLoading = loading }
        if failure != reason { failure = reason }
    }

    fileprivate func report(dismissProgress progress: Double) {
        guard dismissProgress != progress else { return }
        dismissProgress = progress
    }
}

/// The SwiftUI face of `MediaCanvasView`: it owns the fetch and the decode, and
/// hands the view something to composite.
///
/// **Two decode ceilings, and the second is only ever paid by somebody who
/// zoomed.** A photograph from a phone is four thousand pixels wide and decodes
/// to forty-four megabytes at full size, which is more than the whole attachment
/// cache is allowed to hold — so the picture opens at a 2048-pixel rendition,
/// which is sharp at fit and sharp to roughly 200% on any display this runs on.
/// Past that the reader has asked to look closely, and the original is fetched
/// once. Nobody who simply opened a picture pays for either.
struct MediaStage: NSViewRepresentable {
    var item: MediaItem
    var controller: MediaStageController
    /// The player, for video. Nil for everything else.
    var player: AVPlayer?
    /// A pinch, a throw or a click beside the media. Held by the coordinator and
    /// refreshed on every update, so the viewer's close action can never go
    /// stale behind it.
    var onDismiss: () -> Void
    /// A click on the video itself.
    var onContentClick: () -> Void

    /// The rendition a picture opens at. See the note above.
    static let openingPixels = 2048
    /// The rendition a zoomed picture escalates to.
    static let closeUpPixels = 4096
    /// Zoom past this and the close-up is worth its bytes.
    static let closeUpThreshold: CGFloat = 1.9

    /// A filmstrip's ceiling, in decoded bytes.
    ///
    /// **A byte budget is a frame count in disguise and belongs to the caller** —
    /// `INVARIANTS.md` §2. A GIF drawn at a lightbox's size is a hundred times
    /// the pixels of one drawn beside a name, so the decoration's 6 MB default
    /// would buy three frames of it. Thirty-two megabytes at the ceiling below is
    /// around forty frames of a typical 600-pixel reaction GIF, which is the
    /// whole loop.
    static let filmByteBudget = 32 * 1024 * 1024
    /// And its pixel ceiling, which is what keeps the budget buying frames
    /// rather than resolution nobody asked for. A GIF authored at 480 pixels
    /// gains nothing from a larger box; ImageIO does not upscale, so a small
    /// asset costs its own size and no more.
    static let filmPixels = 1280

    @Environment(\.motion) private var motion

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> MediaCanvasView {
        let view = MediaCanvasView(frame: .zero)
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: MediaCanvasView, context: Context) {
        view.reducesMotion = motion.reduceMotion
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onContentClick = onContentClick
        context.coordinator.configure(item: item, player: player)
    }

    static func dismantleNSView(_ view: MediaCanvasView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private let controller: MediaStageController
        var onDismiss: () -> Void = {}
        var onContentClick: () -> Void = {}
        private weak var view: MediaCanvasView?
        private var itemID: AttachmentID?
        private var loadedPixels = 0
        private var loadTask: Task<Void, Never>?
        private var isTornDown = false
        /// Whether anything is on screen. A failure over a picture the reader can
        /// already see is a message contradicted by the thing behind it.
        private var hasVisibleContent = false
        /// The item currently installed, kept so an escalation has something to
        /// re-request without the chrome handing it back down.
        private var pendingItem: MediaItem?

        init(controller: MediaStageController) {
            self.controller = controller
        }

        func attach(_ view: MediaCanvasView) {
            self.view = view
            controller.canvas = view
            view.isFilmPlaying = controller.isFilmPlaying
            view.filmRate = controller.filmRate
            view.onZoomChange = { [weak self] scale in
                guard let self, let view = self.view else { return }
                self.controller.report(
                    zoom: scale,
                    maximum: view.maximumZoom,
                    zoomable: view.isTransformable
                )
                self.escalateIfNeeded(scale)
            }
            view.onFrameChange = { [weak self] index in
                self?.controller.report(frame: index)
            }
            view.onDismissProgress = { [weak self] progress in
                self?.controller.report(dismissProgress: progress)
            }
            view.onDismiss = { [weak self] in
                self?.onDismiss()
            }
            view.onBackgroundClick = { [weak self] in
                self?.onDismiss()
            }
            view.onContentClick = { [weak self] in
                self?.onContentClick()
            }
        }

        func configure(item: MediaItem, player: AVPlayer?) {
            guard !isTornDown, itemID != item.id else { return }
            itemID = item.id
            loadTask?.cancel()
            loadTask = nil
            loadedPixels = 0
            hasVisibleContent = false

            guard let view else { return }
            controller.report(frameCount: 0)
            controller.report(frame: 0)

            guard item.kind != .video else {
                view.setPlayer(player)
                controller.report(zoom: 1, maximum: 1, zoomable: false)
                controller.report(loading: false, failure: nil)
                return
            }
            view.setPlayer(nil)

            // **The picture the transcript already decoded, drawn on this
            // frame.** Without it the lightbox opens onto a grey rectangle for
            // as long as a full-size fetch takes, which on a picture the reader
            // is looking at *right now* reads as the viewer having failed.
            let poster = posterImage(for: item)
            view.setStill(poster, pixelSize: pixelSize(of: poster, fallback: item))
            hasVisibleContent = poster != nil
            controller.report(loading: poster == nil, failure: nil)
            load(item, pixels: MediaStage.openingPixels)
        }

        /// A closer look, once, when the reader has actually asked for one.
        private func escalateIfNeeded(_ scale: CGFloat) {
            guard scale >= MediaStage.closeUpThreshold,
                  loadedPixels == MediaStage.openingPixels,
                  let itemID,
                  let item = pendingItem, item.id == itemID, item.kind == .image,
                  (item.pixelWidth ?? 0) > MediaStage.openingPixels
            else { return }
            load(item, pixels: MediaStage.closeUpPixels)
        }

        private func load(_ item: MediaItem, pixels: Int) {
            pendingItem = item
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await Self.fetch(item, pixels: pixels)
                guard !Task.isCancelled, !self.isTornDown,
                      self.itemID == item.id, let view = self.view
                else { return }
                switch outcome {
                case .film(let film):
                    self.loadedPixels = pixels
                    self.hasVisibleContent = true
                    view.setFilm(film)
                    self.controller.report(frameCount: film.frameCount)
                    self.controller.report(loading: false, failure: nil)
                case .still(let image):
                    self.loadedPixels = pixels
                    self.hasVisibleContent = true
                    view.setStill(
                        image,
                        pixelSize: CGSize(width: image.width, height: image.height)
                    )
                    self.controller.report(loading: false, failure: nil)
                case .failed:
                    // A poster already on screen is a better answer than an
                    // error drawn over the top of it — the reader can see the
                    // picture, and being told it failed to load is nonsense.
                    guard !self.hasVisibleContent else {
                        self.controller.report(loading: false, failure: nil)
                        return
                    }
                    self.controller.report(
                        loading: false,
                        failure: "Couldn’t load \(item.filename)"
                    )
                }
            }
        }

        private enum Outcome {
            case film(AnimatedImage)
            case still(CGImage)
            case failed
        }

        /// Off the main actor by construction: both stores are `nonisolated`, so
        /// the decode of a megapixel picture never lands in a display pass.
        private static func fetch(_ item: MediaItem, pixels: Int) async -> Outcome {
            if item.kind == .animated {
                let key = AnimatedImageStore.Key(
                    url: item.sourceURL,
                    maximumPixelSize: MediaStage.filmPixels,
                    byteBudget: MediaStage.filmByteBudget
                )
                if let film = await AnimatedImageStore.shared.image(for: key) {
                    return .film(film)
                }
                // A single-frame GIF is a still, and every renderer has to cope
                // with one. Falling through is what makes that free.
            }
            let url = item.renditionURL(forPixelWidth: pixels)
            let key = ImageStore.Key(url: url, maximumPixelSize: pixels)
            if let image = await ImageStore.shared.image(for: key, bucket: .attachment) {
                return .still(image)
            }
            return .failed
        }

        /// The transcript's own rendition, peeked synchronously.
        ///
        /// **The key has to equal the one the transcript's prefetch built**, or
        /// this looks in a slot nothing was ever put in — the same trap
        /// `INVARIANTS.md` §2 records for the painter.
        private func posterImage(for item: MediaItem) -> CGImage? {
            guard let url = item.posterURL, let view else { return nil }
            let scale = view.window?.backingScaleFactor ?? 2
            let key = ImageStore.Key(
                url: url,
                maximumPixelSize: Int((item.posterWidth * scale).rounded(.up))
            )
            return ImageStore.shared.cached(key, bucket: .attachment)
        }

        /// The aspect to lay the poster out at: the decoded picture's, or the
        /// dimensions Discord sent, or nothing — and nothing is a real answer
        /// that letterboxes rather than guessing a square.
        private func pixelSize(of image: CGImage?, fallback item: MediaItem) -> CGSize {
            if let image { return CGSize(width: image.width, height: image.height) }
            guard let width = item.pixelWidth, let height = item.pixelHeight,
                  width > 0, height > 0
            else { return .zero }
            return CGSize(width: width, height: height)
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            loadTask?.cancel()
            loadTask = nil
            controller.canvas = nil
            onDismiss = {}
            onContentClick = {}
            view?.tearDown()
            view = nil
        }
    }
}
