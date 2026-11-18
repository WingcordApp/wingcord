import AppKit
import Lottie
import QuartzCore

/// Plays one animated picture in a layer: every frame, at the asset's own
/// rate, at the size it is drawn.
///
/// **Two ways to play, chosen by what the frames cost.**
///
/// - A small loop — an emoji, a reaction — is decoded whole and handed to the
///   render server as one keyframe animation. From then on nothing in this
///   process runs per frame: the picture keeps moving through a scroll, on a
///   busy main thread, at its own timing.
/// - Anything larger — a sticker, a GIF — streams: a few frames are decoded
///   ahead on the source's own queue and swapped in on the shared clock at the
///   asset's own rate. Memory is those few frames, not the loop.
///
/// Either way nothing is thinned: the filmstrip this replaces for the
/// transcript kept forty-eight frames of any loop and whatever fitted six
/// megabytes of a large one.
///
/// A picture of one frame is shown rather than played, for an owner that asks
/// — see `init(key:placeholder:drawsStills:)`.
///
/// **A Lottie sticker plays as vectors** (`loadVector`): ImageIO cannot open
/// its JSON, and before this an owner that asked for one — the picker's grid,
/// the hover row — was told there was nothing to play and kept a still that a
/// Lottie sticker does not have (Alex, 2026-11-18: Chaos Cat, Robo Nelly and
/// seven other stock packs drew empty).
@MainActor
final class FilmPlayer {

    struct Key: Hashable, Sendable {
        var url: URL
        /// The longest side, in pixels, the picture is decoded at.
        var maximumPixelSize: Int
    }

    let layer = CALayer()
    let key: Key

    /// The most a loop may occupy to be held whole. Past it the frames stream.
    ///
    /// Three megabytes holds a hundred frames of a jumbo emoji; a sticker's
    /// six frames or a GIF's two are already past it, and those are the
    /// pictures that cost a whole loop's memory to hold.
    static let residentLimit = 3 * 1024 * 1024

    /// Tells the owner whether frames are up: true once the first one shows,
    /// false when there is nothing here to show — an asset that cannot be
    /// read, or a still the owner draws itself — so a still drawn under it
    /// can be taken away, or kept.
    ///
    /// **An answer given before anybody listened is given again to whoever
    /// starts.** A loop already held is shown from `init`, with no hop, so a
    /// row scrolled back draws it on its first frame — and an owner can only
    /// attach this once `init` has returned. Dropped there, `AnimatedDecoration`
    /// never heard that frames were up and left its still under the film: two
    /// copies of a decoration on every show after the first.
    var onPlayback: ((Bool) -> Void)? {
        didSet {
            if let playback { onPlayback?(playback) }
        }
    }

    /// The last answer `onPlayback` was given, or would have been.
    private var playback: Bool?

    /// Whether a picture of one frame is drawn here. See `init`.
    private let drawsStills: Bool
    private var loadTask: Task<Void, Never>?
    private var stream: FilmStream?
    /// A Lottie sticker's own layer, sized with this one.
    private var vector: LottieAnimationLayer?
    /// Whether the picture is moving now.
    private var isPlaying = true
    /// Whether its owner wants it moving. The app being in the background is
    /// the other half of the answer; see `applyPlayback`.
    private var isWanted = true

    /// - Parameter placeholder: what the box shows until the first frame.
    /// - Parameter placeholderImage: a blurred stand-in drawn over it
    ///   meanwhile — Discord's `placeholder`.
    /// - Parameter drawsStills: whether a picture that turns out to have one
    ///   frame is drawn here. True for an owner that leaves the box empty for
    ///   this layer — the transcript — where the alternative is a plate for
    ///   good; false for one that draws its own still underneath and only needs
    ///   telling there is nothing to play.
    init(key: Key, placeholder: CGColor? = nil, placeholderImage: CGImage? = nil, drawsStills: Bool = false) {
        self.key = key
        self.drawsStills = drawsStills
        layer.backgroundColor = placeholder
        layer.contents = placeholderImage
        layer.masksToBounds = true
        layer.contentsGravity = .resize
        // The layer is placed and resized with the rows; none of that is a
        // transition.
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        Self.watchActivity()
        Self.live.add(self)
        applyPlayback()
        load()
    }

    /// Stops everything and leaves the layer tree. The player cannot be
    /// restarted: a picture that comes back gets a new one.
    func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        stream?.stop()
        stream = nil
        vector?.stop()
        vector?.removeFromSuperlayer()
        vector = nil
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
    }

    /// Holds the current frame, or plays again from where the loop now is.
    func setPlaying(_ playing: Bool) {
        isWanted = playing
        applyPlayback()
    }

    /// Moves while its owner wants it to and the app is in front.
    ///
    /// **Held while the app is in the background**, as every other moving
    /// picture in it is — one nobody is looking at is heat. A keyframe loop
    /// plays on the render server, which does not know the app went away, so
    /// this watches for it rather than leaving it to each owner.
    private func applyPlayback() {
        let playing = isWanted && Self.isAppActive && AppVisibility.shared.isVisible
        guard playing != isPlaying else { return }
        isPlaying = playing
        stream?.setPlaying(playing)
        if playing {
            layer.speed = 1
            layer.timeOffset = 0
        } else {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
    }

    private static var isAppActive = NSApp?.isActive ?? true
    private static let live = NSHashTable<FilmPlayer>.weakObjects()
    private static var activityObservers: [NSObjectProtocol] = []
    private static let visibilityOwner = NSObject()

    /// One pair of observers for every player there is.
    private static func watchActivity() {
        guard activityObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { notification in
            let active = notification.name == NSApplication.didBecomeActiveNotification
            MainActor.assumeIsolated {
                isAppActive = active
                for player in live.allObjects { player.applyPlayback() }
            }
        }
        activityObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: update),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: update),
        ]
        // Covered or minimized while still the active app.
        AppVisibility.shared.observe(FilmPlayer.visibilityOwner) { _ in
            for player in live.allObjects { player.applyPlayback() }
        }
    }

    private func load() {
        if LottieFilmstrip.handles(key.url) {
            loadVector()
            return
        }
        if let film = FilmFrames.shared.cached(key) {
            // A still held for an owner that leaves its box empty is, to one
            // that draws its own, nothing to play.
            if film.frames.count > 1 || drawsStills { play(film) } else { report(false) }
            return
        }
        let key = key
        let stills = drawsStills
        let space = FilmSource.screenSpace
        loadTask = Task { [weak self] in
            guard let data = try? await ImageStore.shared.data(for: key.url) else {
                // Nothing to show, and the owner keeps its still.
                if !Task.isCancelled { self?.report(false) }
                return
            }
            guard !Task.isCancelled else { return }
            let source = await Task.detached(priority: .userInitiated) {
                FilmSource(data: data, maximumPixelSize: key.maximumPixelSize, stills: stills, displaySpace: space)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let source else {
                self.report(false)
                return
            }
            if source.isStill {
                // Held as a loop of one, so the layer that replaces this one
                // when its row scrolls back shows it with no fetch at all.
                let still = ResidentFilm(frames: [source.firstFrame], ends: source.ends, duration: source.duration)
                FilmFrames.shared.store(still, for: key)
                self.play(still)
                return
            }
            self.show(source.firstFrame)
            self.report(true)
            if source.residentCost <= Self.residentLimit {
                let frames = await withCheckedContinuation { continuation in
                    source.decodeAll { continuation.resume(returning: $0) }
                }
                guard !Task.isCancelled, let frames else { return }
                let film = ResidentFilm(frames: frames, ends: source.ends, duration: source.duration)
                FilmFrames.shared.store(film, for: key)
                self.play(film)
            } else {
                let stream = FilmStream(source: source, layer: self.layer)
                self.stream = stream
                stream.setPlaying(self.isPlaying)
            }
        }
    }

    /// A Lottie sticker: the parsed document (`LottieDocuments`, shared with
    /// the transcript and the card), played on Lottie's Core Animation engine
    /// at the file's own rate and sharp at any size — the render server runs
    /// it, and this layer's `speed` holds it like any other film.
    ///
    /// **Installed one per turn** (`LottieTurns`): building a sticker's layer
    /// tree is a few milliseconds, and a pack scrolled onto asks for thirty.
    private func loadVector() {
        let url = key.url
        loadTask = Task { [weak self] in
            let animation = await LottieDocuments.shared.animation(for: url)
            guard !Task.isCancelled else { return }
            guard let animation else {
                self?.report(false)
                return
            }
            await LottieTurns.next()
            guard let self, !Task.isCancelled else { return }
            self.installVector(animation)
        }
    }

    private func installVector(_ animation: LottieAnimation) {
        let lottie = LottieStickerLayer.make(animation, scale: NSScreen.main?.backingScaleFactor ?? 2)
        // Follows this layer's size, which its owner sets (`LottieStickerFitter`
        // fits the drawing to it each time).
        lottie.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lottie.frame = layer.bounds
        layer.addSublayer(lottie)
        CATransaction.commit()
        vector = lottie
        lottie.play()
        report(true)
    }

    private func report(_ playing: Bool) {
        playback = playing
        onPlayback?(playing)
    }

    private func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        // A picture may be clear in places, and its placeholder must not show
        // through them.
        layer.backgroundColor = nil
        CATransaction.commit()
    }

    /// One keyframe animation over every frame, on a shared epoch — so the
    /// same emoji twice in a channel moves in step, as one picture shown twice
    /// does in a browser.
    private func play(_ film: ResidentFilm) {
        show(film.frames[0])
        report(true)
        guard film.frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = film.frames
        // Discrete keyframes take one more time than values: each frame shows
        // from its own start to the next one's.
        animation.keyTimes = ([0] + film.ends.map { $0 / film.duration }).map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.duration = film.duration
        animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(Self.epoch, from: nil)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "film")
    }

    /// The moment every resident loop counts from.
    private static let epoch = CACurrentMediaTime()
}

extension FilmSource {
    /// The colour space a source's frames are matched to: the screen with the
    /// key window, which is where a picture decoded now is about to be shown.
    /// A window moved to another screen afterwards costs that screen's
    /// conversion again, as every frame did before — never a wrong colour.
    @MainActor static var screenSpace: CGColorSpace? {
        NSScreen.main?.colorSpace?.cgColorSpace
    }
}

/// A loop held whole: every frame, and when each one ends.
nonisolated struct ResidentFilm: Sendable {
    let frames: [CGImage]
    let ends: [Double]
    let duration: Double
}

/// The loops held whole, shared by every layer showing the same picture.
///
/// One emoji fifty times in a channel is one decode and one set of frames —
/// and one upload to the render server, which caches a picture by identity.
nonisolated final class FilmFrames: @unchecked Sendable {
    static let shared = FilmFrames()

    private final class Box: @unchecked Sendable {
        let film: ResidentFilm
        init(_ film: ResidentFilm) { self.film = film }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(_ key: FilmPlayer.Key) -> ResidentFilm? {
        cache.object(forKey: Self.name(key))?.film
    }

    func store(_ film: ResidentFilm, for key: FilmPlayer.Key) {
        let cost = film.frames.reduce(0) { $0 + $1.height * $1.bytesPerRow }
        cache.setObject(Box(film), forKey: Self.name(key), cost: cost)
    }

    func purge() {
        cache.removeAllObjects()
    }

    private static func name(_ key: FilmPlayer.Key) -> NSString {
        "\(key.maximumPixelSize)|\(key.url.absoluteString)" as NSString
    }
}

/// A loop too large to hold, played a few frames ahead.
///
/// **The frames arrive on the source's queue and are shown on the clock.** Each
/// tick asks which frame the loop is on; if it has been decoded it goes up, and
/// the next few are asked for. A frame that is not ready by its turn is
/// skipped, not waited for, so a slow decode costs smoothness and never time.
@MainActor
final class FilmStream {
    private let source: FilmSource
    private weak var layer: CALayer?
    /// Where the picture is in its own playback, in seconds — or nil while it
    /// has nothing to show, and the layer is hidden.
    private let phase: () -> Double?
    /// Whether it wraps. A picture that plays once holds its last frame past
    /// its end, as `num_plays: 1` means and a browser does.
    private let loops: Bool
    /// The frame in the layer now.
    private var shown = 0
    private var ready: [Int: CGImage] = [:]
    private var pending: Set<Int> = []
    private var isSubscribed = false

    /// How far ahead frames are decoded.
    private static let lookahead = 4

    /// - Parameter showsFirstFrame: whether the layer already has frame zero
    ///   up; one that does not is handed it on the first tick.
    /// - Parameter phase: the playback's own time; the shared clock unless the
    ///   picture keeps a timeline of its own, as a profile effect's layers do.
    init(
        source: FilmSource,
        layer: CALayer,
        showsFirstFrame: Bool = true,
        loops: Bool = true,
        phase: @escaping () -> Double? = { AnimationClock.shared.time }
    ) {
        self.source = source
        self.layer = layer
        self.loops = loops
        self.phase = phase
        if !showsFirstFrame {
            shown = -1
            ready[0] = source.firstFrame
        }
    }

    private var token: ObjectIdentifier { ObjectIdentifier(self) }

    func setPlaying(_ playing: Bool) {
        guard playing != isSubscribed else { return }
        isSubscribed = playing
        if playing {
            AnimationClock.shared.subscribe(
                token,
                // A layer moves with the rows on its own, so a scroll costs it
                // nothing to keep playing through.
                throughScroll: true,
                rate: 1 / source.shortestFrame
            ) { [weak self] in self?.tick() }
            tick()
        } else {
            AnimationClock.shared.unsubscribe(token)
        }
    }

    func stop() {
        setPlaying(false)
        ready.removeAll()
    }

    private func tick() {
        guard let time = phase() else {
            if layer?.isHidden == false { layer?.isHidden = true }
            return
        }
        if layer?.isHidden == true { layer?.isHidden = false }
        let count = source.frameCount
        let now = source.index(at: time, looping: loops)
        if now != shown, let frame = ready[now] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = frame
            CATransaction.commit()
            shown = now
        }
        ready = ready.filter { (($0.key - now + count) % count) < Self.lookahead }
        for step in 0..<Self.lookahead {
            let index = (now + step) % count
            guard index != shown, ready[index] == nil, !pending.contains(index) else { continue }
            pending.insert(index)
            source.decode(index) { [weak self] image in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pending.remove(index)
                    if self.isSubscribed, let image { self.ready[index] = image }
                }
            }
        }
    }
}
