import AVFoundation
import Foundation
import OSLog

/// Plays the thirty-second clip behind a Spotify card.
///
/// **`AVPlayer`, not the call's own audio path.** `VoiceSoundPlayer` exists to
/// put a blip through a mixer that is already running, and its notification
/// engine is there because the voice processing unit opens the *microphone* —
/// `INVARIANTS.md` §1.5. A preview is an ordinary piece of media going to the
/// default output and has no business anywhere near that machinery.
///
/// **One at a time, across the whole app.** Two cards playing at once is two
/// songs, and there is no arrangement in which somebody wanted that — the same
/// rule a moving cosmetic follows (§4.6).
@MainActor
@Observable
final class SpotifyPreviewPlayer {
    @ObservationIgnored private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Preview")

    /// What is playing, or nil. Read by the card so its chip says which way the
    /// click goes.
    private(set) var playing: URL?

    @ObservationIgnored private var player: AVPlayer?
    /// The end-of-clip observer, kept so it can be taken off again. An observer
    /// left behind fires for the *next* clip and stops it a second in.
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    /// What to call when playback starts or stops, so the transcript can redraw
    /// the one chip that changed.
    @ObservationIgnored var onChange: ((URL?) -> Void)?

    /// How far into the clip, for the card's progress line. Read on a timer
    /// while it plays, never observed.
    func elapsed() -> Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    /// The clip's length, once known; thirty seconds is Spotify's preview.
    func length() -> Double {
        let seconds = player?.currentItem?.duration.seconds ?? 30
        return seconds.isFinite && seconds > 0 ? seconds : 30
    }

    /// Starts this clip, or stops it if it is the one already going.
    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // A preview is a foreground sound somebody asked for by clicking. It
        // should not duck or interrupt anything else the machine is doing.
        player.volume = 1
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // **Hopped explicitly.** The notification is delivered on the main
            // queue, which is not the same promise as the main actor.
            MainActor.assumeIsolated { self?.stop() }
        }
        self.player = player
        playing = url
        player.play()
        onChange?(url)
    }

    /// Stops whatever is playing. Safe when nothing is.
    func stop() {
        guard player != nil || playing != nil else { return }
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playing = nil
        onChange?(nil)
    }
}
