import AVFoundation
import AVKit
import AppKit

/// The viewer's full player: AVKit's own (docs/ACTIVITIES-CALLS-PICKER.md,
/// decision 24). Native scrubbing and volume, the file's own subtitles and
/// closed captions, Picture in Picture, AirPlay, speeds, full screen.
///
/// **Over the canvas only while the video is still.** The canvas flies the
/// video out of its thumbnail, pages it and follows a throw on its own layer;
/// this sits on top at rest and steps aside for any of those, so the motion is
/// the canvas's and the controls are the system's. Both draw the same player.
@MainActor
final class ViewerSystemPlayer {
    private var view: ViewerPlayerView?
    private weak var host: NSView?

    init(host: NSView) {
        self.host = host
    }

    /// Shows the player over `frame` (the letterboxed picture), or hides it.
    func show(_ player: AVPlayer, frame: CGRect, visible: Bool) {
        guard let host else { return }
        let view = self.view ?? make(in: host)
        if view.player !== player { view.player = player }
        if view.frame != frame { view.frame = frame }
        if view.isHidden == visible { view.isHidden = !visible }
    }

    func hide() {
        view?.isHidden = true
    }

    /// Lets go of the player: another item, or the viewer going.
    func detach() {
        view?.player = nil
        view?.removeFromSuperview()
        view = nil
    }

    private func make(in host: NSView) -> ViewerPlayerView {
        let view = ViewerPlayerView(frame: .zero)
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        // Live Text and Look Up on a paused frame, as QuickTime has.
        view.allowsVideoFrameAnalysis = true
        view.isHidden = true
        host.addSubview(view)
        self.view = view
        return view
    }
}

/// AVKit's view, kept off the keyboard: Escape, the arrows and space belong to
/// the viewer (`MediaViewer.handle(key:)`), which plays and pauses the same
/// player.
final class ViewerPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { false }
}
