import AVFoundation
import Foundation
import Observation

/// One video, playing.
///
/// **The player is reused across items.** `replaceCurrentItem(with:)` keeps the
/// audio session, the render pipeline and the layer's connection to it, so
/// stepping to the next clip in a message is a swap rather than a fresh
/// `AVPlayer` and a fresh `AVPlayerLayer` per press.
///
/// **The clock is read at ten hertz and published as two values.** A scrubber
/// wants a smooth number and a timestamp label wants a whole second, and
/// publishing one value for both means the label's view re-evaluates ten times a
/// second to draw the same three characters. Observation tracks per property, so
/// splitting them costs one integer and buys nine tenths of that back.
///
/// Everything it holds is released by `tearDown`, behind a one-way latch — a
/// periodic time observer left on an `AVPlayer` is the classic leak in a view
/// like this, and it keeps its closure and the whole controller alive for the
/// life of the process.
@Observable
@MainActor
final class VideoPlayback {
    @ObservationIgnored let player = AVPlayer()

    /// The clip's length. Zero until the item is ready, which is a real state:
    /// a scrubber over an unknown duration must not pretend to a position.
    private(set) var duration: Double = 0
    /// Fine-grained, for the scrubber.
    private(set) var currentTime: Double = 0
    /// Whole seconds, for the two labels. See the note above.
    private(set) var elapsedSeconds = 0
    private(set) var remainingSeconds = 0

    private(set) var isPlaying = false
    /// Waiting on the network with playback intended — the only state worth a
    /// spinner. `AVPlayer` reports it directly rather than it being inferred
    /// from a stalled clock.
    private(set) var isBuffering = false
    private(set) var failure: String?

    /// Suppresses the clock while the reader is dragging the scrubber. Without
    /// it the observer writes the *old* position back over the drag, ten times a
    /// second, and the thumb fights the pointer.
    private(set) var isScrubbing = false

    var isLooping: Bool {
        get { settings.loopsVideo }
        set { settings.loopsVideo = newValue }
    }

    /// Shared with every other clip, and persisted: a volume that resets to full
    /// on the next video is a volume nobody set.
    var volume: Double {
        get { settings.mediaVolume }
        set {
            settings.mediaVolume = newValue
            player.volume = Float(newValue)
            // Nudging the slider up from silence is the same gesture as
            // unmuting, and leaving it silent afterwards reads as broken.
            if newValue > 0, player.isMuted { player.isMuted = false }
        }
    }

    var isMuted: Bool {
        get { settings.mutesMedia }
        set {
            settings.mutesMedia = newValue
            player.isMuted = newValue
        }
    }

    /// The speeds the menu offers. 1 first, because it is the answer nearly
    /// every time and a list that starts at half speed reads as a list of
    /// oddities.
    static let rates: [Double] = [1, 0.5, 0.75, 1.25, 1.5, 2]

    var rate: Double = 1 {
        didSet {
            guard rate != oldValue else { return }
            // `defaultRate` is what `play()` resumes at; assigning `rate`
            // directly on a paused player *starts* it, which is a speed control
            // that also un-pauses.
            player.defaultRate = Float(rate)
            if isPlaying { player.rate = Float(rate) }
        }
    }

    private let settings: AppSettings
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var controlObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var itemID: AttachmentIdentity?
    private var isTornDown = false

    /// A stand-in for the attachment's id, so this type needs no model import.
    typealias AttachmentIdentity = UInt64

    init(settings: AppSettings = .shared) {
        self.settings = settings
        player.volume = Float(settings.mediaVolume)
        player.isMuted = settings.mutesMedia
        player.defaultRate = 1
        // Nothing here is a stream that should keep playing while a frame is
        // late; a lightbox wants the newest frame, not a queue of stale ones.
        player.automaticallyWaitsToMinimizeStalling = true
    }

    // MARK: Loading

    /// Points the player at `url`, or takes it away.
    ///
    /// Idempotent on the identity, because `updateNSView` runs on every SwiftUI
    /// update and re-loading there would restart the clip whenever anything at
    /// all changed in the window.
    func load(url: URL?, identity: AttachmentIdentity?, autoplay: Bool) {
        guard !isTornDown, itemID != identity else { return }
        itemID = identity
        detachItem()

        duration = 0
        currentTime = 0
        elapsedSeconds = 0
        remainingSeconds = 0
        failure = nil
        isPlaying = false
        isBuffering = false

        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observe(item)
        if autoplay {
            player.defaultRate = Float(rate)
            player.play()
            isPlaying = true
        }
    }

    private func observe(_ item: AVPlayerItem) {
        // The clock. Ten hertz: fast enough that a scrubber moves smoothly, slow
        // enough that a clip playing behind a still window is not sixty
        // publications a second into a view tree nobody is looking at.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.clockDidAdvance(to: time.seconds) }
        }

        // **Read back on the main actor rather than carried out of the
        // callback.** KVO delivers on whatever queue changed the value, and
        // `AVPlayerItem` is not `Sendable`; hopping first and reading second is
        // the only shape that is correct without copying half the item across.
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        controlObserver = player.observe(
            \.timeControlStatus, options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
    }

    private func detachItem() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        controlObserver?.invalidate()
        controlObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    // MARK: State

    private func clockDidAdvance(to seconds: Double) {
        guard !isScrubbing, seconds.isFinite else { return }
        publish(time: seconds)
    }

    private func publish(time seconds: Double) {
        let clamped = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        if abs(currentTime - clamped) > 0.001 { currentTime = clamped }
        let elapsed = Int(clamped)
        if elapsedSeconds != elapsed { elapsedSeconds = elapsed }
        let remaining = duration > 0 ? Int((duration - clamped).rounded(.down)) : 0
        if remainingSeconds != remaining { remainingSeconds = remaining }
    }

    private func refreshStatus() {
        guard !isTornDown, let item = player.currentItem else { return }

        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0, abs(duration - seconds) > 0.001 {
            duration = seconds
            publish(time: currentTime)
        }

        switch item.status {
        case .failed:
            let reason = item.error?.localizedDescription ?? "This video could not be played."
            if failure != reason { failure = reason }
            if isPlaying { isPlaying = false }
        case .readyToPlay, .unknown:
            if failure != nil { failure = nil }
        @unknown default:
            break
        }

        let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isBuffering != buffering { isBuffering = buffering }
        let playing = player.timeControlStatus != .paused
        if isPlaying != playing { isPlaying = playing }
    }

    private func didReachEnd() {
        guard !isTornDown else { return }
        guard isLooping else {
            isPlaying = false
            publish(time: duration)
            return
        }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    // MARK: Commands

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        // Replaying from the end rather than sitting on the last frame doing
        // nothing, which is what a Play button at the end of a clip otherwise
        // does.
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            publish(time: 0)
        }
        player.defaultRate = Float(rate)
        player.play()
        isPlaying = true
    }

    func beginScrub() {
        isScrubbing = true
    }

    /// Follows the thumb. Loose tolerances: an exact seek per drag event asks
    /// the decoder for a keyframe-accurate frame ten times a second, which is
    /// what makes a scrubber stutter on a long clip.
    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        publish(time: seconds)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: CMTime(value: 1, timescale: 4),
            toleranceAfter: CMTime(value: 1, timescale: 4)
        )
    }

    /// The exact landing, once.
    func endScrub(at seconds: Double) {
        guard duration > 0 else {
            isScrubbing = false
            return
        }
        publish(time: seconds)
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isScrubbing = false }
        }
    }

    /// A relative jump, for the arrow keys.
    func skip(by seconds: Double) {
        guard duration > 0 else { return }
        let target = min(duration, max(0, currentTime + seconds))
        publish(time: target)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(value: 1, timescale: 10),
            toleranceAfter: CMTime(value: 1, timescale: 10)
        )
    }

    func toggleMute() { isMuted.toggle() }

    // MARK: Teardown

    /// Releases the observers and the item. Idempotent, and one-way: a seek
    /// completion or a KVO hop that resumes after this writes nothing.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        detachItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemID = nil
        isPlaying = false
    }
}

/// `mm:ss`, or `h:mm:ss` past an hour.
///
/// Written out rather than reached for through a formatter: a `Duration` style
/// localises the separator, and a scrubber's two labels have to stay the same
/// width as the number under them changes or the bar jitters as it plays.
nonisolated func mediaTimeLabel(_ seconds: Int) -> String {
    let total = max(0, seconds)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    let ss = s < 10 ? "0\(s)" : "\(s)"
    guard h > 0 else { return "\(m):\(ss)" }
    let mm = m < 10 ? "0\(m)" : "\(m)"
    return "\(h):\(mm):\(ss)"
}
