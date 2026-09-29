import AVFoundation
import AppKit
import SwiftUI

/// A silent, looping video that fills its box.
///
/// **An `AVPlayerLayer` through a representable, not `VideoPlayer`.** The
/// SwiftUI view brings transport controls, and there is nothing here to control:
/// this is a moving picture — an activity's preview loop, a game's trailer — and
/// a scrubber under one is chrome for a thing nobody is going to scrub.
///
/// `AVPlayerLooper` rather than an end-of-item notification: the notification
/// path shows a black frame at the seam.
///
/// Everything it holds is released in `dismantleNSView`. Without that the player
/// keeps its decoder and its network connection alive after the page is gone,
/// and both of the surfaces that use this are opened and left constantly.
struct LoopingVideo: NSViewRepresentable {
    var url: URL
    /// False holds the frame on screen, for a caller honouring Reduce Motion.
    var isPlaying = true

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.play(url, isPlaying: isPlaying)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.play(url, isPlaying: isPlaying)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: NSView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var current: URL?

        override var isFlipped: Bool { true }

        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

        func play(_ url: URL, isPlaying: Bool) {
            if current != url {
                current = url
                stop()

                wantsLayer = true
                let item = AVPlayerItem(url: url)
                let player = AVQueuePlayer()
                player.isMuted = true
                // Decoration must never duck a call or take the audio session.
                // Muted is not enough on its own — a player with audio still
                // claims one.
                player.audiovisualBackgroundPlaybackPolicy = .pauses
                looper = AVPlayerLooper(player: player, templateItem: item)
                (layer as? AVPlayerLayer)?.player = player
                (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
                self.player = player
            }
            if isPlaying { player?.play() } else { player?.pause() }
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            (layer as? AVPlayerLayer)?.player = nil
        }
    }
}
