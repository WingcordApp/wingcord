import AVFoundation
import AVKit
import AppKit
import WingcordCore

/// A video attachment playing in place, as Discord's do (Alex, 2026-11-17:
/// "pressing on a video will play it in the mini video player like on discord,
/// double pressing will open it in the full player"; decision 24).
///
/// **AVKit's own inline player**: the system's play, scrub, volume, full
/// screen and Picture in Picture, at the attachment's size. A subview of the
/// transcript's canvas in its coordinates, so it scrolls with its row; the
/// timeline moves it on relayout and takes it away when the row is gone, as it
/// does an embed's player (`EmbedPlayerView`).
final class InlineVideoView: NSView {
    let messageID: MessageID
    let attachmentIndex: Int
    /// A double click on it: the full player, from where this got to.
    var onExpand: ((Double) -> Void)?

    private let player: AVPlayer
    private let playerView = InlinePlayerView(frame: .zero)
    private var monitor: Any?

    init(messageID: MessageID, attachmentIndex: Int, url: URL, settings: AppSettings = .shared) {
        self.messageID = messageID
        self.attachmentIndex = attachmentIndex
        player = AVPlayer(url: url)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.chip
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor

        // The viewer's own saved volume, so the two never disagree.
        player.volume = Float(settings.mediaVolume)
        player.isMuted = settings.mutesMedia
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)
        player.play()

        // **The second click of a double click lands here**, not on the
        // canvas: the first one put this view over the picture.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            // Above the control strip: a quick double click on the scrubber is
            // two seeks, not a request for the full player.
            guard self.bounds.contains(point), point.y > Self.controlStrip else { return event }
            let time = self.player.currentTime().seconds
            self.onExpand?(time.isFinite ? time : 0)
            return nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// How tall AVKit's inline controls are, give or take.
    private static let controlStrip: CGFloat = 40

    override func layout() {
        super.layout()
        playerView.frame = bounds
    }

    /// Ends playback and leaves the canvas.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        player.pause()
        playerView.player = nil
        removeFromSuperview()
    }
}

/// AVKit's view, off the keyboard: the transcript's shortcuts stay the
/// transcript's.
final class InlinePlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}
