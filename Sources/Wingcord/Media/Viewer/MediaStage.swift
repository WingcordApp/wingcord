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
    /// Whether this kind of media zooms at all. Video does not.
    private(set) var isZoomable = false

    /// Frames in the loaded filmstrip, or zero when the media does not move —
    /// the honest answer to "is this a GIF", which only the decode knows.
    private(set) var frameCount = 0
    private(set) var frameIndex = 0

    private(set) var isLoading = true
    private(set) var failure: String?

    /// How far a throw or a squeeze has gone: 0 at rest, 1 at the point of no
    /// return. Read by the scrim and the bars and nothing else, so a gesture in
    /// flight invalidates a fade and not the stage.
    private(set) var dismissProgress: Double = 0

    /// How far the stage is in: 0 at the thumbnail, 1 open. The scrim and the
    /// chrome follow the picture's flights through it.
    private(set) var presence: Double = 0

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

    /// Slides to the picture `direction` away — see `MediaCanvasView.page`.
    func page(by direction: Int) { canvas?.page(by: direction) }

    /// Slides straight to `item`, from the side it is on — the gallery
    /// strip's pick of a picture that is not beside this one.
    func jump(to item: MediaItem, direction: Int) { jumpHandler?(item, direction) }
    @ObservationIgnored fileprivate var jumpHandler: ((MediaItem, Int) -> Void)?

    /// Flies the picture home, into `home` where it is on screen, and calls
    /// `onClosed` when it has landed. A second call while it flies is ignored.
    func close(home: MediaSources.Thumbnail?, velocity: CGPoint = .zero) {
        guard let canvas else {
            onClosed?()
            return
        }
        canvas.close(home: home, velocity: velocity)
    }

    var isClosing: Bool { canvas?.isClosing ?? false }

    /// What landing home means to the viewer: the stage going.
    @ObservationIgnored var onClosed: (() -> Void)?

    // MARK: Written by the stage

    fileprivate func report(zoom: CGFloat, maximum: CGFloat, zoomable: Bool) {
        // An equal write still invalidates every reader, and a settle reports
        // one of these per frame.
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

    fileprivate func report(presence value: Double) {
        guard presence != value else { return }
        presence = value
    }
}

/// The SwiftUI face of `MediaCanvasView`: it owns the fetches and the decode,
/// lays the neighbours beside the stage, and hands the view things to show.
///
/// **Two decode ceilings, and the second is only ever paid by somebody who
/// zoomed.** A phone photograph is four thousand pixels wide and forty-four
/// megabytes decoded — more than the whole attachment cache — so it opens at a
/// 2048-pixel rendition, sharp at fit and to about 200%. Past that the reader
/// has asked to look closely, and the original is fetched once.
struct MediaStage: NSViewRepresentable {
    var item: MediaItem
    /// The pictures either side, for paging. Nil where there are none.
    var previous: MediaItem?
    var next: MediaItem?
    var controller: MediaStageController
    /// The player, for video. Nil for everything else.
    var player: AVPlayer?
    /// Where the picture's thumbnail is, for the opening flight.
    var home: () -> MediaSources.Thumbnail?
    /// A throw, a squeeze or a click beside the media asking to close.
    var onRequestClose: (CGPoint) -> Void
    /// A page turned under the fingers or the arrows.
    var onPage: (Int) -> Void
    /// A click on the video itself.
    var onContentClick: () -> Void

    /// The rendition a picture opens at. See the note above.
    static let openingPixels = 2048
    /// The rendition a zoomed picture escalates to.
    static let closeUpPixels = 4096
    /// Zoom past this and the close-up is worth its bytes.
    static let closeUpThreshold: CGFloat = 1.9

    /// A filmstrip's ceiling, in decoded bytes — a frame count in disguise
    /// (`INVARIANTS.md` §2): about forty frames of a 600-pixel reaction GIF.
    static let filmByteBudget = 32 * 1024 * 1024
    /// And its pixel ceiling, which keeps the budget buying frames rather than
    /// resolution nobody asked for.
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
        let coordinator = context.coordinator
        coordinator.onRequestClose = onRequestClose
        coordinator.onPage = onPage
        coordinator.onContentClick = onContentClick
        coordinator.configure(item: item, player: player, home: home)
        coordinator.lay(previous: previous, next: next)
    }

    static func dismantleNSView(_ view: MediaCanvasView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private let controller: MediaStageController
        var onRequestClose: (CGPoint) -> Void = { _ in }
        var onPage: (Int) -> Void = { _ in }
        var onContentClick: () -> Void = {}
        private weak var view: MediaCanvasView?
        private var itemID: AttachmentID?
        private var loadedPixels = 0
        private var loadTask: Task<Void, Never>?
        private var neighborTask: Task<Void, Never>?
        private var neighborIDs: (AttachmentID?, AttachmentID?) = (nil, nil)
        private var isTornDown = false
        private var hasOpened = false
        /// Whether anything is on screen. A failure over a picture the reader
        /// can already see is a message contradicted by the thing behind it.
        private var hasVisibleContent = false
        /// The item currently installed, so an escalation can re-request it.
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
                self.controller.report(zoom: scale, maximum: view.maximumZoom, zoomable: view.isTransformable)
                self.escalateIfNeeded(scale)
            }
            view.onFrameChange = { [weak self] index in self?.controller.report(frame: index) }
            view.onDismissProgress = { [weak self] progress in self?.controller.report(dismissProgress: progress) }
            view.onPresence = { [weak self] presence in self?.controller.report(presence: presence) }
            view.onRequestClose = { [weak self] velocity in self?.onRequestClose(velocity) }
            view.onBackgroundClick = { [weak self] in self?.onRequestClose(.zero) }
            view.onContentClick = { [weak self] in self?.onContentClick() }
            view.onClosed = { [weak self] in self?.controller.onClosed?() }
            view.onPage = { [weak self] direction in self?.onPage(direction) }
            controller.jumpHandler = { [weak self] item, direction in self?.jump(to: item, direction: direction) }
        }

        /// Lays `item` on the side it is coming from and turns the page to it.
        private func jump(to item: MediaItem, direction: Int) {
            guard let view, direction != 0 else { return }
            let incoming = neighbor(item)
            view.setNeighbors(
                previous: direction < 0 ? incoming : neighbor(neighborItems.previous),
                next: direction > 0 ? incoming : neighbor(neighborItems.next)
            )
            // The pair the canvas holds is no longer the one `lay` set.
            neighborIDs = (nil, nil)
            view.page(by: direction)
        }

        func configure(item: MediaItem, player: AVPlayer?, home: @escaping () -> MediaSources.Thumbnail?) {
            guard !isTornDown, itemID != item.id, let view else { return }
            itemID = item.id
            loadTask?.cancel()
            loadTask = nil
            loadedPixels = 0
            pendingItem = item
            controller.report(frameCount: 0)
            controller.report(frame: 0)

            // **A page has already put this item's picture on stage** — the
            // neighbour's, which may be sharper than the poster. Kept, and
            // only the sharper renditions are asked for.
            let isOnStage = view.contentIdentity == AnyHashable(item.id)
            hasVisibleContent = isOnStage

            if item.kind == .video {
                view.setPlayer(player, videoSize: Self.pixelSize(of: nil, fallback: item))
                if !isOnStage { view.showPoster(posterImage(for: item), identity: item.id) }
                controller.report(zoom: 1, maximum: 1, zoomable: false)
                controller.report(loading: false, failure: nil)
            } else {
                view.setPlayer(nil)
                if !isOnStage {
                    // **The picture the transcript already decoded, on this
                    // frame.** Without it the lightbox opens onto a grey
                    // rectangle for as long as a full-size fetch takes.
                    let poster = posterImage(for: item)
                    view.setStill(poster, pixelSize: Self.pixelSize(of: poster, fallback: item), identity: item.id)
                    hasVisibleContent = poster != nil
                }
                controller.report(loading: !hasVisibleContent, failure: nil)
                load(item, pixels: MediaStage.openingPixels)
            }

            if !hasOpened {
                hasOpened = true
                view.prepareOpen(home: home)
            }
        }

        /// Lays the pictures either side of the stage: what is in memory now,
        /// and a sharper copy of each as it arrives — Discord preloads them as
        /// well (`947056`'s `R`), so a page lands on a picture already sharp.
        func lay(previous: MediaItem?, next: MediaItem?) {
            guard let view else { return }
            view.canPage = previous != nil || next != nil
            neighborItems = (previous, next)
            guard neighborIDs != (previous?.id, next?.id) else { return }
            neighborIDs = (previous?.id, next?.id)
            view.setNeighbors(previous: neighbor(previous), next: neighbor(next))
            neighborTask?.cancel()
            let pictures = [previous, next].compactMap { $0 }.filter { $0.kind == .image }
            guard !pictures.isEmpty else { return }
            neighborTask = Task { [weak self] in
                for item in pictures {
                    let url = item.renditionURL(forPixelWidth: MediaStage.openingPixels)
                    let key = ImageStore.Key(url: url, maximumPixelSize: MediaStage.openingPixels)
                    guard let image = await ImageStore.shared.image(for: key, bucket: .stage),
                          !Task.isCancelled, let self, !self.isTornDown
                    else { continue }
                    self.view?.updateNeighbor(item.id, image: image)
                }
            }
        }

        private var neighborItems: (previous: MediaItem?, next: MediaItem?) = (nil, nil)

        private func neighbor(_ item: MediaItem?) -> MediaCanvasView.Neighbor? {
            guard let item else { return nil }
            let poster = posterImage(for: item)
            return MediaCanvasView.Neighbor(
                identity: item.id,
                image: poster,
                pixelSize: Self.pixelSize(of: poster, fallback: item),
                isVideo: item.isVideo
            )
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
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await Self.fetch(item, pixels: pixels)
                guard !Task.isCancelled, !self.isTornDown, self.itemID == item.id, let view = self.view else { return }
                switch outcome {
                case .film(let film):
                    self.loadedPixels = pixels
                    self.hasVisibleContent = true
                    view.setFilm(film)
                    self.controller.report(frameCount: film.frameCount)
                    self.controller.report(loading: false, failure: nil)
                case .still(let image):
                    self.loadedPixels = pixels
                    if self.hasVisibleContent {
                        // The same picture, sharper: the reader's zoom stays.
                        view.sharpen(image)
                    } else {
                        view.setStill(image, pixelSize: CGSize(width: image.width, height: image.height), identity: item.id)
                    }
                    self.hasVisibleContent = true
                    self.controller.report(loading: false, failure: nil)
                case .failed:
                    // A poster on screen is a better answer than an error over
                    // it — the reader can see the picture.
                    guard !self.hasVisibleContent else {
                        self.controller.report(loading: false, failure: nil)
                        return
                    }
                    self.controller.report(loading: false, failure: "Couldn’t load \(item.filename)")
                }
            }
        }

        private enum Outcome {
            case film(AnimatedImage)
            case still(CGImage)
            case failed
        }

        /// Off the main actor by construction: both stores are `nonisolated`.
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
                // A single-frame GIF is a still; falling through makes that free.
            }
            let url = item.renditionURL(forPixelWidth: pixels)
            let key = ImageStore.Key(url: url, maximumPixelSize: pixels)
            // The viewer's own bucket — the transcript's cannot be evicted by
            // a close-up (`ImageStore.Bucket`).
            if let image = await ImageStore.shared.image(for: key, bucket: .stage) {
                return .still(image)
            }
            return .failed
        }

        /// The transcript's own rendition, peeked synchronously. **The key has
        /// to equal the one the transcript's prefetch built**, or this looks in a
        /// slot nothing was ever put in (`INVARIANTS.md` §2).
        private func posterImage(for item: MediaItem) -> CGImage? {
            guard let url = item.posterURL else { return nil }
            let scale = view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let key = ImageStore.Key(url: url, maximumPixelSize: Int((item.posterWidth * scale).rounded(.up)))
            return ImageStore.shared.cached(key, bucket: .attachment)
        }

        /// The aspect to lay a picture out at: the decoded picture's, or the
        /// dimensions Discord sent, or nothing — and nothing letterboxes rather
        /// than guessing a square.
        private static func pixelSize(of image: CGImage?, fallback item: MediaItem) -> CGSize {
            if let image { return CGSize(width: image.width, height: image.height) }
            guard let width = item.pixelWidth, let height = item.pixelHeight, width > 0, height > 0 else { return .zero }
            return CGSize(width: width, height: height)
        }

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            loadTask?.cancel()
            loadTask = nil
            neighborTask?.cancel()
            neighborTask = nil
            // The renditions go with the viewer; the transcript's thumbnails,
            // in their own bucket, stay.
            ImageStore.shared.emptyStage()
            controller.canvas = nil
            onRequestClose = { _ in }
            onPage = { _ in }
            onContentClick = {}
            view?.tearDown()
            view = nil
        }
    }
}
