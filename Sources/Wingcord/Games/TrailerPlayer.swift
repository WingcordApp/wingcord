import AVFoundation
import AVKit
import SwiftUI

/// A game's trailer, in the system's own player.
///
/// **AVKit's `AVPlayerView` with its inline controls** — play, the scrubber,
/// the volume and full screen are the system's (Alex, 2026-10-07: "use the
/// native video player"). `LoopingVideo` stays what it is, a moving picture
/// with nothing to control; a trailer is a video somebody may want to scrub.
///
/// **Muted until the first click on it.** Discord's game profile plays its
/// trailer with `autoMute` (chunk `464cd197…`, `lv`): the page is opened to
/// look at a game, not to be played at. The first click anywhere on the player
/// turns the sound on; the volume control does the rest.
///
/// **It plays on its own unless Reduce Motion is on** — Discord's
/// `autoPlay: !reducedMotion` — and **the poster stands in until it does**,
/// `<video poster>`'s behaviour: the store asset's `.webp` sits in the
/// player's content overlay until the first frame plays, so a trailer that is
/// not playing shows the game rather than a black box.
struct TrailerPlayer: NSViewRepresentable {
    var url: URL
    var poster: URL?
    var autoplays: Bool
    /// Whether the stage can be seen in its scroll view.
    ///
    /// **A trailer nobody can see is not decoded.** It used to play on under
    /// the header for as long as the page was open — a video decoder and a
    /// layer redrawn sixty times a second for a picture scrolled away. Off
    /// screen it pauses, and comes back playing only if it was. The same goes
    /// for the app's windows being hidden, which the coordinator hears from
    /// `AppVisibility` itself.
    var isOnScreen = true
    /// Told whenever playback starts or stops, for the tray's play mark.
    var onPlayingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        context.coordinator.onPlayingChange = onPlayingChange
        context.coordinator.attach(to: view)
        context.coordinator.isOnScreen = isOnScreen
        context.coordinator.load(url, poster: poster, autoplays: autoplays, in: view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onPlayingChange = onPlayingChange
        context.coordinator.load(url, poster: poster, autoplays: autoplays, in: view)
        context.coordinator.setOnScreen(isOnScreen, in: view)
    }

    /// Everything the player holds goes with the page: without this the
    /// decoder and the connection outlive a profile somebody closed.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop(view)
        AppVisibility.shared.stopObserving(coordinator)
    }

    final class Coordinator: NSObject {
        var onPlayingChange: (Bool) -> Void = { _ in }
        private var current: URL?
        private var playback: NSKeyValueObservation?
        private var posterHost: NSView?
        private var isPlaying = false
        /// Whether the stage is scrolled into view, and whether any of the
        /// app's windows can be seen. Playback needs both.
        var isOnScreen = true
        private var isAppVisible = AppVisibility.shared.isVisible
        /// Whether the trailer was playing when it lost its audience, so it
        /// comes back as it left: a trailer somebody paused stays paused.
        private var resumesWhenSeen = false
        private weak var view: AVPlayerView?

        private var canBeSeen: Bool { isOnScreen && isAppVisible }

        func attach(to view: AVPlayerView) {
            // **Not delaying the click**: the controls under the pointer still
            // get it, so the first press on the scrubber both scrubs and turns
            // the sound on.
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
            self.view = view
            AppVisibility.shared.observe(self) { [weak self] visible in
                guard let self, let view = self.view else { return }
                let before = canBeSeen
                isAppVisible = visible
                audienceChanged(from: before, in: view)
            }
        }

        func setOnScreen(_ onScreen: Bool, in view: AVPlayerView) {
            guard onScreen != isOnScreen else { return }
            let before = canBeSeen
            isOnScreen = onScreen
            audienceChanged(from: before, in: view)
        }

        private func audienceChanged(from before: Bool, in view: AVPlayerView) {
            guard canBeSeen != before, let player = view.player else { return }
            if canBeSeen {
                if resumesWhenSeen { player.play() }
                resumesWhenSeen = false
            } else {
                resumesWhenSeen = player.timeControlStatus != .paused
                player.pause()
            }
        }

        func load(_ url: URL, poster: URL?, autoplays: Bool, in view: AVPlayerView) {
            guard current != url else { return }
            stop(view)
            current = url
            let player = AVPlayer(url: url)
            player.isMuted = true
            // A muted trailer on a page is not a film: it does not keep the
            // display awake.
            player.preventsDisplaySleepDuringVideoPlayback = false
            view.player = player
            showPoster(poster, in: view)
            playback = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.timeControlStatus == .playing
                Task { @MainActor [weak self] in self?.playbackChanged(playing) }
            }
            // Not for nobody: a trailer loaded off screen starts when it is
            // scrolled to.
            if autoplays {
                if canBeSeen { player.play() } else { resumesWhenSeen = true }
            }
        }

        func stop(_ view: AVPlayerView) {
            playback = nil
            view.player?.pause()
            view.player = nil
            posterHost?.removeFromSuperview()
            posterHost = nil
            current = nil
            resumesWhenSeen = false
            if isPlaying {
                isPlaying = false
                report(false)
            }
        }

        @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let player = (recognizer.view as? AVPlayerView)?.player, player.isMuted else { return }
            player.isMuted = false
        }

        private func playbackChanged(_ playing: Bool) {
            if playing {
                // The first frame is up: the poster has done its job.
                posterHost?.removeFromSuperview()
                posterHost = nil
            }
            guard playing != isPlaying else { return }
            isPlaying = playing
            report(playing)
        }

        /// **On the next main-actor turn, always.** `stop` runs inside
        /// `updateNSView` and the dismantle, and a state write made on that
        /// stack does not stick (INVARIANTS §1).
        ///
        /// The callback is taken now rather than through `self`: the last
        /// report, the one the dismantle makes, lands after the coordinator
        /// has gone, and a weak hop would drop it and leave the tray saying
        /// Pause over a trailer nobody is playing.
        private func report(_ playing: Bool) {
            let callback = onPlayingChange
            Task { @MainActor in callback(playing) }
        }

        private func showPoster(_ poster: URL?, in view: AVPlayerView) {
            guard let poster, let overlay = view.contentOverlayView else { return }
            let host = NSHostingView(rootView: TrailerPoster(url: poster))
            host.frame = overlay.bounds
            host.autoresizingMask = [.width, .height]
            overlay.addSubview(host)
            posterHost = host
        }
    }
}

/// The poster, fitted as the video is, over the player's own black.
private struct TrailerPoster: View {
    var url: URL

    var body: some View {
        RemoteImage(url: url, side: 900, bucket: .artwork) { Color.black }
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .allowsHitTesting(false)
    }
}
