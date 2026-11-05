import AVFoundation
import Foundation
import OSLog
import WingcordCore

/// What a voice note's row draws: where the player is, for this moment.
///
/// **A value, handed to the painter at paint time**, because the painter's `nonisolated`
/// and its rows are drawn from whatever's in front of it. `current` is the one playing or
/// paused with the player on it; the rest of the notes are in `leftAt`.
nonisolated struct VoiceNotePlayback: Sendable {
    var current: AttachmentID?
    var position: Double = 0
    var isPlaying = false
    var isLoading = false
    var rate: Float = 1
    /// Where each note was left. Absent is never played.
    var leftAt: [AttachmentID: Double] = [:]
    var failed: Set<AttachmentID> = []

    /// How far along a note is: nil is untouched.
    func position(of id: AttachmentID) -> Double? {
        current == id ? position : leftAt[id]
    }
}

/// Plays voice messages, one at a time, across the app.
///
/// **`AVPlayer` on a file on this machine.** It plays Ogg Opus on macOS 27 with speed and
/// exact seeking (docs/VOICE-MESSAGES.md), and a downloaded copy makes replay instant and
/// outlives Discord's signed URLs.
///
/// **Keeps going while the reader scrolls, and stops when they leave the channel** (D9).
@MainActor
@Observable
final class VoiceNotePlayer {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "VoiceNote")

    /// The note in the composer, which has no attachment yet.
    static let heldNote = AttachmentID(rawValue: 1)

    private(set) var current: AttachmentID?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var failed: Set<AttachmentID> = []
    /// The one speed all notes play at, remembered (D9).
    private(set) var rate: Float
    /// Moves on every change a row has to redraw for. The canvas keys on it, since it's
    /// drawn and SwiftUI won't tell it otherwise.
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var statusWatch: Task<Void, Never>?
    @ObservationIgnored private var duration: Double = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var leftAt: [AttachmentID: Double] = [:]
    /// Where a seek is going. The player's own clock lags behind one for a moment, and
    /// the bars shouldn't jump back and then forward.
    @ObservationIgnored private var seekTarget: Double?
    /// Tells the rest of the app a note's about to make sound.
    @ObservationIgnored var onWillPlay: () -> Void = {}

    private static let rateKey = "voiceNotes.playbackRate"

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.float(forKey: Self.rateKey)
        rate = VoiceMessageLimits.playbackRates.contains(saved) ? saved : 1
    }

    // MARK: What's drawn

    /// Where things stand, right now. Read once per repaint.
    var playback: VoiceNotePlayback {
        VoiceNotePlayback(
            current: current,
            position: position,
            isPlaying: isPlaying,
            isLoading: isLoading,
            rate: rate,
            leftAt: leftAt,
            failed: failed
        )
    }

    /// Where the current note is, in seconds.
    var position: Double {
        if let seekTarget { return seekTarget }
        guard let player else { return current.flatMap { leftAt[$0] } ?? 0 }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? min(max(0, seconds), duration) : 0
    }

    /// How far along a note is. Nil is untouched.
    func position(of id: AttachmentID) -> Double? {
        current == id ? position : leftAt[id]
    }

    // MARK: Playing

    /// Plays it, or pauses it if it's the one playing.
    func toggle(_ id: AttachmentID, source: URL?, duration: Double) {
        if current == id, isPlaying {
            pause()
        } else {
            play(id, source: source, duration: duration)
        }
    }

    /// Plays a note from where it was left, or from a fraction of the way through.
    func play(_ id: AttachmentID, source: URL?, duration: Double, from fraction: Double? = nil) {
        guard let source else { return }
        failed.remove(id)
        let startAt = fraction.map { $0 * duration }
        if current == id, let player {
            if let startAt { seek(to: startAt) }
            onWillPlay()
            start(player)
            return
        }
        hold()
        current = id
        self.duration = duration
        if let startAt { leftAt[id] = startAt }
        bump()
        if source.isFileURL {
            begin(url: source, id: id)
            return
        }
        if let cached = VoiceNoteCache.url(for: id) {
            begin(url: cached, id: id)
            return
        }
        isLoading = true
        bump()
        loadTask = Task { [weak self] in
            do {
                let file = try await VoiceNoteCache.download(source, for: id)
                guard let self, self.current == id else { return }
                self.isLoading = false
                self.begin(url: file, id: id)
            } catch {
                guard let self, !Task.isCancelled, self.current == id else { return }
                Self.log.error("download failed: \(String(describing: error), privacy: .public)")
                self.failed.insert(id)
                self.isLoading = false
                self.current = nil
                self.bump()
            }
        }
    }

    private func begin(url: URL, id: AttachmentID) {
        let item = AVPlayerItem(url: url)
        // Speech, sped up without going squeaky. Discord's rates are all inside what
        // this does well.
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished(id) }
        }
        // **A file that won't play says nothing by itself**: the player stays "playing" at
        // nought for ever. Asked of the item directly, so the row can offer a retry, and
        // a copy that's bad doesn't get played from again.
        statusWatch = Task { [weak self, item] in
            for await status in item.publisher(for: \.status).values {
                guard status == .failed else { continue }
                self?.couldNotPlay(id, file: url)
                return
            }
        }
        self.player = player
        if let resume = leftAt[id], resume > 0 { seek(to: resume) }
        onWillPlay()
        start(player)
    }

    private func start(_ player: AVPlayer) {
        player.defaultRate = rate
        player.rate = rate
        isPlaying = true
        bump()
    }

    private func couldNotPlay(_ id: AttachmentID, file: URL) {
        guard current == id else { return }
        Self.log.error("a voice note wouldn't play: \(id.rawValue, privacy: .public)")
        VoiceNoteCache.remove(file)
        leftAt[id] = nil
        failed.insert(id)
        tearDown()
        current = nil
        bump()
    }

    private func finished(_ id: AttachmentID) {
        guard current == id else { return }
        // Back to the start and untouched, as Discord's: the time shows its whole
        // length again.
        leftAt[id] = nil
        tearDown()
        current = nil
        bump()
    }

    func pause() {
        guard let current, isPlaying else { return }
        leftAt[current] = position
        player?.pause()
        isPlaying = false
        bump()
    }

    /// Moves within the current note.
    func seek(toFraction fraction: Double) {
        seek(to: max(0, min(1, fraction)) * duration)
        bump()
    }

    private func seek(to seconds: Double) {
        guard let player else {
            if let current { leftAt[current] = seconds }
            return
        }
        if let current { leftAt[current] = seconds }
        seekTarget = seconds
        Task { [weak self, player] in
            _ = await player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 48_000),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            // A newer seek's own to clear.
            guard let self, self.seekTarget == seconds else { return }
            self.seekTarget = nil
        }
    }

    /// A note just got its real id, in place of its echo's.
    func rename(_ old: AttachmentID, to new: AttachmentID) {
        if current == old { current = new }
        if let position = leftAt.removeValue(forKey: old) { leftAt[new] = position }
        bump()
    }

    /// Discord's speed pill: the next speed, wrapping around.
    func cycleRate(defaults: UserDefaults = .standard) {
        let rates = VoiceMessageLimits.playbackRates
        let index = rates.firstIndex(of: rate) ?? 1
        rate = rates[(index + 1) % rates.count]
        defaults.set(rate, forKey: Self.rateKey)
        if isPlaying { player?.rate = rate }
        player?.defaultRate = rate
        bump()
    }

    // MARK: Stopping

    /// Stops the note and forgets every position. The reader's left the channel.
    func stop() {
        guard current != nil || !leftAt.isEmpty else { return }
        leftAt.removeAll()
        tearDown()
        current = nil
        bump()
    }

    /// Stops one note and forgets it: the held note being thrown away.
    func stop(_ id: AttachmentID) {
        leftAt[id] = nil
        guard current == id else {
            bump()
            return
        }
        tearDown()
        current = nil
        bump()
    }

    /// Lets go of whatever's on the player, keeping its place for when it's next played.
    private func hold() {
        if let current, isPlaying { leftAt[current] = position }
        tearDown()
    }

    private func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        player?.pause()
        player = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusWatch?.cancel()
        statusWatch = nil
        seekTarget = nil
        isPlaying = false
        isLoading = false
    }

    private func bump() {
        revision &+= 1
    }
}
