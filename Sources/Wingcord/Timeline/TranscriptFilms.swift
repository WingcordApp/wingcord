import AVFoundation
import AppKit
import Lottie
import QuartzCore
import WingcordCore

/// The moving pictures in the transcript, as layers over its canvas.
///
/// **Layers, not repaints.** The canvas used to draw every sticker, GIF and
/// animated emoji itself: a clock capped at twenty-four ticks a second
/// invalidated each picture's box and the painter drew the frame the clock was
/// on — so nothing moved faster than twenty-four frames a second, nothing moved
/// at all while the reader scrolled, and every frame of every picture cost a
/// pass through the painter. Here each picture is a layer that plays by itself
/// — see `FilmPlayer` — and moves with the rows because it sits in the canvas's
/// own coordinate space: a scroll moves the canvas's bounds, and the layers
/// with them, and nobody is asked to redraw anything.
///
/// **Only the pictures near the viewport have a layer.** The canvas asks for
/// the rows on screen and half a screen either side, so a picture is already
/// playing when it scrolls in, and one scrolled away gives its frames back.
///
/// The painter leaves each layered picture's box empty — see
/// `TimelineRowPainter.State.layered`, which `layered` here feeds — and a layer
/// that has no frame yet wears the placeholder the painter used to draw.
@MainActor
final class TranscriptFilms {

    /// One picture the canvas wants on a layer.
    struct Request: Equatable {
        enum Source: Hashable {
            /// A GIF, an APNG or an animated WebP.
            case film(FilmPlayer.Key)
            /// A Lottie sticker, played by Lottie's Core Animation engine.
            case vector(URL)
            /// A GIF that is really an MP4 — a `gifv` — muted and looping.
            case video(URL)
        }

        var slot: TimelineCanvasView.FilmSlot
        var source: Source
        /// In the canvas's own coordinates, which scroll with it.
        var frame: CGRect
        var gravity: CALayerContentsGravity = .resize
        var cornerRadius: CGFloat = 0
        /// What the box shows until the first frame lands — the plate the
        /// painter would have drawn there. Nil for a picture that sits on
        /// nothing, a sticker or an emoji, whose box is simply empty until then.
        var placeholder: CGColor?
    }

    /// The favourite star over a hovered GIF, which the canvas draws on top of
    /// the picture — and which a layer over that picture would otherwise hide.
    struct Badge: Equatable {
        var state: TimelineRowPainter.FavoriteBadge
        var frame: CGRect
        /// The picture it sits on; the star rides above it only while that
        /// picture is on a layer.
        var slot: TimelineCanvasView.FilmSlot
    }

    /// Holds every layer. Sits at the canvas's origin, so a layer's frame is
    /// its position in the canvas.
    let container = CALayer()

    private var players: [TimelineCanvasView.FilmSlot: any TranscriptFilm] = [:]
    /// Which of each message's pictures are on layers, for the painter.
    private(set) var layered: [MessageID: TimelineRowPainter.Layered] = [:]
    private var sources: [TimelineCanvasView.FilmSlot: Request.Source] = [:]
    private var isPlaying = NSApp?.isActive ?? true
    private var badgeLayer: CALayer?
    private var badge: Badge?
    private var activityObservers: [NSObjectProtocol] = []

    init() {
        container.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.actions = ["sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
        // **Held while the app is in the background**, as every other moving
        // picture is. The layers play on the render server, which does not
        // know the app went away; the clock that used to drive them did.
        let center = NotificationCenter.default
        activityObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.setPlaying(false) } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.setPlaying(true) } },
        ]
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Whether a picture is playing on a layer, so a hit test or a painter can
    /// tell the two apart.
    func isShowing(_ slot: TimelineCanvasView.FilmSlot) -> Bool {
        players[slot] != nil
    }

    /// Brings the layers in line with `requests`: new pictures get a player,
    /// pictures gone from the list lose theirs, and the rest are moved to
    /// where their rows now are.
    func reconcile(_ requests: [Request], scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var wanted = Set<TimelineCanvasView.FilmSlot>()
        wanted.reserveCapacity(requests.count)
        var layered: [MessageID: TimelineRowPainter.Layered] = [:]
        for request in requests {
            wanted.insert(request.slot)
            Self.record(request, in: &layered)
            if let player = players[request.slot], sources[request.slot] == request.source {
                place(player.layer, for: request)
                continue
            }
            players[request.slot]?.tearDown()
            let player: any TranscriptFilm
            switch request.source {
            case .film(let key):
                player = FilmPlayer(key: key, placeholder: request.placeholder)
            case .vector(let url):
                player = VectorFilm(url: url, scale: scale)
            case .video(let url):
                player = VideoFilm(url: url)
            }
            player.setPlaying(isPlaying)
            place(player.layer, for: request)
            container.addSublayer(player.layer)
            players[request.slot] = player
            sources[request.slot] = request.source
        }
        for slot in players.keys where !wanted.contains(slot) {
            players.removeValue(forKey: slot)?.tearDown()
            sources[slot] = nil
        }
        self.layered = layered
        placeBadge()
    }

    /// Notes that a picture is on a layer, so the painter leaves its box empty
    /// — unless it is a clip, which keeps its poster under it: an MP4 has no
    /// clear parts to show the box through, and the poster is what is there
    /// until it plays.
    private static func record(
        _ request: Request, in layered: inout [MessageID: TimelineRowPainter.Layered]
    ) {
        if case .video = request.source { return }
        let index = request.slot.index
        var entry = layered[request.slot.messageID] ?? .init()
        switch request.slot.kind {
        case .sticker: entry.stickers.insert(index)
        case .attachment: entry.attachments.insert(index)
        case .embed: entry.embedImages.insert(index)
        case .emoji: entry.emoji.insert(index)
        case .reaction: entry.reactions.insert(index)
        }
        layered[request.slot.messageID] = entry
    }

    /// Holds or resumes every picture — the app going to the background.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        for player in players.values { player.setPlaying(playing) }
    }

    /// Puts the favourite star over the hovered GIF, or takes it away.
    func setBadge(_ badge: Badge?, scale: CGFloat) {
        guard badge != self.badge else { return }
        self.badge = badge
        if let badge {
            badgeLayer?.removeFromSuperlayer()
            badgeLayer = Self.badgeLayer(for: badge, scale: scale)
        } else {
            badgeLayer?.removeFromSuperlayer()
            badgeLayer = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeBadge()
        CATransaction.commit()
    }

    func removeAll() {
        for player in players.values { player.tearDown() }
        players.removeAll()
        sources.removeAll()
        layered.removeAll()
        badgeLayer?.removeFromSuperlayer()
        badgeLayer = nil
        badge = nil
    }

    private func place(_ layer: CALayer, for request: Request) {
        if layer.frame != request.frame { layer.frame = request.frame }
        layer.contentsGravity = request.gravity
        layer.cornerRadius = request.cornerRadius
        if let vector = players[request.slot] as? VectorFilm { vector.fit() }
        if let video = players[request.slot] as? VideoFilm { video.fit() }
    }

    /// The star is shown only while its picture is on a layer: otherwise the
    /// canvas's own star is visible and a second would double it.
    private func placeBadge() {
        guard let badge, let badgeLayer else { return }
        if players[badge.slot] != nil {
            badgeLayer.frame = badge.frame
            if badgeLayer.superlayer == nil { container.addSublayer(badgeLayer) }
            badgeLayer.zPosition = 1
        } else {
            badgeLayer.removeFromSuperlayer()
        }
    }

    /// The star, drawn by the same painter the canvas uses into a picture of
    /// its own.
    private static func badgeLayer(for badge: Badge, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        let size = badge.frame.size
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let context = CGContext(
                  data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return layer }
        // The painter draws top-down, as the canvas does.
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TimelineRowPainter.drawFavoriteBadge(
            badge.state, in: CGRect(origin: .zero, size: size), context: context
        )
        NSGraphicsContext.restoreGraphicsState()
        layer.contents = context.makeImage()
        layer.contentsScale = scale
        return layer
    }
}

/// What the transcript holds a picture's layer through.
@MainActor
protocol TranscriptFilm: AnyObject {
    var layer: CALayer { get }
    func setPlaying(_ playing: Bool)
    func tearDown()
}

extension FilmPlayer: TranscriptFilm {}

/// A Lottie sticker in the transcript, on Lottie's Core Animation engine.
///
/// **Not rasterised.** The strip this replaces drew twenty-four frames of the
/// vector file into bitmaps and played them on the clock; here the engine hands
/// the file's own animations to the render server, which plays them at the
/// file's rate and draws them sharp at any size.
@MainActor
final class VectorFilm: TranscriptFilm {
    let layer = CALayer()
    private var lottie: LottieAnimationLayer?
    private var loadTask: Task<Void, Never>?
    private var isPlaying = true

    init(url: URL, scale: CGFloat) {
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]
        if let animation = LottieDocuments.shared.cached(url) {
            install(animation, scale: scale)
            return
        }
        loadTask = Task { [weak self] in
            let animation = await LottieDocuments.shared.animation(for: url)
            guard let self, !Task.isCancelled, let animation else { return }
            self.install(animation, scale: scale)
        }
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        guard let lottie else { return }
        if playing {
            if !lottie.isAnimationPlaying { lottie.play() }
        } else if lottie.isAnimationPlaying {
            lottie.pause()
        }
    }

    /// Fits the drawing to the slot after the slot moves or resizes.
    func fit() {
        guard let lottie else { return }
        if lottie.frame != layer.bounds { lottie.frame = layer.bounds }
        LottieStickerLayer.fit(lottie)
    }

    func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        lottie?.stop()
        lottie?.removeFromSuperlayer()
        lottie = nil
        layer.removeFromSuperlayer()
    }

    private func install(_ animation: LottieAnimation, scale: CGFloat) {
        let lottie = LottieStickerLayer.make(animation, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lottie.frame = layer.bounds
        layer.addSublayer(lottie)
        CATransaction.commit()
        self.lottie = lottie
        fit()
        setPlaying(isPlaying)
    }
}

/// A `gifv` in the transcript: its MP4, muted and looping, over the poster the
/// canvas draws.
///
/// **Shown only once it has a frame.** A player layer with nothing decoded yet
/// draws black, which over the poster reads as the GIF failing; kept hidden
/// until the first frame is ready, the poster simply starts moving.
@MainActor
final class VideoFilm: TranscriptFilm {
    let layer = CALayer()
    private let player = AVQueuePlayer()
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var readiness: NSKeyValueObservation?
    private var isPlaying = true

    init(url: URL) {
        layer.masksToBounds = true
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "sublayers": NSNull()]
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        playerLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer.addSublayer(playerLayer)
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor in self?.playerLayer.isHidden = !ready }
        }
        player.play()
    }

    func fit() {
        if playerLayer.frame != layer.bounds { playerLayer.frame = layer.bounds }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing { player.play() } else { player.pause() }
    }

    func tearDown() {
        readiness?.invalidate()
        readiness = nil
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        playerLayer.player = nil
        layer.removeFromSuperlayer()
    }
}
