import Foundation
import Synchronization

// MARK: - Sound kept for a clip, as Opus
//
// docs/CLIPS-PRESENCE.md, Phase 3.1–3.2. Every sound a clip can carry — the
// game's, the reader's microphone, each person in the call — is kept the same
// way: one 20 ms Opus frame at a time, stamped with when it was (or will be)
// heard on the host clock that ScreenCaptureKit stamps pictures with. A voice
// is kept as the packets that arrived, so it costs no encoder at all and about
// a megabyte per speaker for two minutes; the game's sound is encoded once,
// as a stream's sound is. Nothing is decoded until a clip is saved.

/// One 20 ms frame of kept sound.
public struct TimedAudioFrame: Sendable {
    public enum Payload: Sendable {
        /// The frame as Opus.
        case opus([UInt8])
        /// Lost, and rebuilt from the redundant copy inside the packet after
        /// it — the jitter buffer's FEC path, replayed at save time.
        case recovered(successor: [UInt8])
        /// Lost with nothing to rebuild it from: Opus's concealer.
        case concealed
    }

    /// Host-clock seconds — `CACurrentMediaTime`'s clock, which is the one
    /// ScreenCaptureKit's presentation times are on.
    public var time: Double
    public var payload: Payload

    public init(time: Double, payload: Payload) {
        self.time = time
        self.payload = payload
    }

    var byteCount: Int {
        switch payload {
        case .opus(let bytes), .recovered(let bytes): bytes.count
        case .concealed: 0
        }
    }
}

/// The last stretch of one source's frames, oldest first.
///
/// A value: the tap and the game recorder each keep theirs behind their own
/// lock, and a save takes a copy — the arrays are copy-on-write, so that copy
/// costs nothing until the next frame lands.
public struct TimedAudioTrack: Sendable {
    public private(set) var frames: [TimedAudioFrame] = []
    /// Where the kept frames start — trimming moves this rather than shifting
    /// the array on every frame.
    private var head = 0

    public init() {}

    public init(frames: [TimedAudioFrame]) {
        self.frames = frames
    }

    public var isEmpty: Bool { head >= frames.count }
    public var newest: Double? { isEmpty ? nil : frames.last?.time }

    public var byteCount: Int {
        frames[head...].reduce(0) { $0 + $1.byteCount }
    }

    public mutating func append(_ frame: TimedAudioFrame, keeping window: Double) {
        frames.append(frame)
        let cutoff = frame.time - window
        while head < frames.count, frames[head].time < cutoff { head += 1 }
        // Compacted in a batch, a few seconds' worth at a time.
        if head > 512 {
            frames.removeFirst(head)
            head = 0
        }
    }

    /// The frames heard between `start` and `end`.
    public func frames(from start: Double, to end: Double) -> [TimedAudioFrame] {
        guard !isEmpty else { return [] }
        return frames[head...].filter { $0.time >= start - OpusFrame.duration && $0.time <= end }
    }
}

/// One source's frames behind a lock, for a writer on a real-time thread — a
/// Go Live stream's sound, kept for its clips.
public final class TimedAudioBuffer: Sendable {
    private let state: Mutex<(track: TimedAudioTrack, window: Double)>

    public init(window: Double) {
        state = Mutex((TimedAudioTrack(), window))
    }

    public func append(_ frame: TimedAudioFrame) {
        state.withLock { $0.track.append(frame, keeping: $0.window) }
    }

    public var track: TimedAudioTrack { state.withLock { $0.track } }

    public func setWindow(_ window: Double) {
        state.withLock { $0.window = window }
    }

    public func reset() {
        state.withLock { $0.track = TimedAudioTrack() }
    }
}

enum OpusFrame {
    /// Seconds in one frame.
    static let duration = Double(OpusFormat.frameSize) / Double(OpusFormat.sampleRate)
}

// MARK: - The call's side of a clip

/// What the call hands a clip: each kept speaker's frames, the reader's own,
/// the soundboard, and who spoke when.
///
/// Owned by the app's clip recorder and handed to the voice session, which
/// writes into it from the mix thread and the microphone's — so every method
/// here is cheap, takes one lock and allocates at most the frame it keeps.
public final class ClipAudioTap: Sendable {

    /// Whose sound is kept — the app decides it from Discord's rules (see
    /// docs/CLIPS-PRESENCE.md, Phase 3: nobody in a stage channel; the reader
    /// whenever clips are on; anybody else only when their client says
    /// `ALLOW_VOICE_RECORDING`).
    public struct Plan: Sendable, Equatable {
        /// Seconds kept behind the newest frame.
        public var window: Double
        public var voices: Set<UInt64>
        public var keepsMicrophone: Bool
        public var keepsSoundboard: Bool

        public init(window: Double, voices: Set<UInt64> = [], keepsMicrophone: Bool, keepsSoundboard: Bool) {
            self.window = window
            self.voices = voices
            self.keepsMicrophone = keepsMicrophone
            self.keepsSoundboard = keepsSoundboard
        }

        public static let nothing = Plan(window: 0, keepsMicrophone: false, keepsSoundboard: false)
    }

    /// One soundboard sound, as it was played into the call.
    public struct SoundboardPlay: @unchecked Sendable {
        public var time: Double
        /// Interleaved stereo at 48 kHz — the decoded clip the mixer played.
        /// `@unchecked` only because `[Float]` is shared, never mutated.
        public var samples: [Float]
        public var volume: Float
    }

    /// What a save takes away.
    public struct Snapshot: Sendable {
        public var voices: [UInt64: TimedAudioTrack]
        public var microphone: TimedAudioTrack
        public var soundboard: [SoundboardPlay]
        /// Every speaking change kept, plus one at `-infinity` per person for
        /// the state carried in from before the oldest — so a clip knows who
        /// was already talking when it starts.
        public var speaking: [(time: Double, userID: UInt64, flags: Int)]
    }

    private struct State {
        var plan = Plan.nothing
        var voices: [UInt64: TimedAudioTrack] = [:]
        var microphone = TimedAudioTrack()
        var soundboard: [SoundboardPlay] = []
        var speaking: [(time: Double, userID: UInt64, flags: Int)] = []
        /// Where the kept changes start, as `TimedAudioTrack.head`.
        var speakingHead = 0
        /// The last flags per person from changes that fell out of the window.
        var carried: [UInt64: Int] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Changes whose sound is kept. A voice that stops being allowed is
    /// forgotten at once, not left to age out.
    public func setPlan(_ plan: Plan) {
        state.withLock { state in
            state.plan = plan
            state.voices = state.voices.filter { plan.voices.contains($0.key) }
            if !plan.keepsMicrophone { state.microphone = TimedAudioTrack() }
            if !plan.keepsSoundboard { state.soundboard = [] }
        }
    }

    public var plan: Plan { state.withLock { $0.plan } }

    /// Forgets everything kept — the call ended, or clips were turned off.
    public func reset() {
        state.withLock { state in
            let plan = state.plan
            state = State()
            state.plan = plan
        }
    }

    // MARK: Written by the call

    /// Whether `userID`'s voice is kept — asked before anything is copied.
    func keepsVoice(of userID: UInt64) -> Bool {
        state.withLock { $0.plan.voices.contains(userID) }
    }

    func noteVoice(_ userID: UInt64, _ frame: TimedAudioFrame) {
        state.withLock { state in
            guard state.plan.voices.contains(userID) else { return }
            state.voices[userID, default: TimedAudioTrack()].append(frame, keeping: state.plan.window)
        }
    }

    func noteMicrophone(_ frame: TimedAudioFrame) {
        state.withLock { state in
            guard state.plan.keepsMicrophone else { return }
            state.microphone.append(frame, keeping: state.plan.window)
        }
    }

    func noteSoundboard(_ samples: [Float], volume: Float, at time: Double) {
        state.withLock { state in
            guard state.plan.keepsSoundboard else { return }
            state.soundboard.append(SoundboardPlay(time: time, samples: samples, volume: volume))
            // A sound outlives its start by its own length, so the cut is the
            // window plus the longest a soundboard sound runs.
            let cutoff = time - state.plan.window - 10
            state.soundboard.removeAll { $0.time < cutoff }
        }
    }

    /// A speaking state changed. `flags` is Discord's: 1 voice, 0 stopped.
    func noteSpeaking(_ userID: UInt64, flags: Int, at time: Double) {
        state.withLock { state in
            guard state.plan.window > 0 else { return }
            state.speaking.append((time, userID, flags))
            let cutoff = time - state.plan.window
            while state.speakingHead < state.speaking.count, state.speaking[state.speakingHead].time < cutoff {
                let old = state.speaking[state.speakingHead]
                state.carried[old.userID] = old.flags
                state.speakingHead += 1
            }
            if state.speakingHead > 256 {
                state.speaking.removeFirst(state.speakingHead)
                state.speakingHead = 0
            }
        }
    }

    // MARK: Read by a save

    public func snapshot() -> Snapshot {
        state.withLock { state in
            let carried = state.carried.map { (time: -Double.infinity, userID: $0.key, flags: $0.value) }
            return Snapshot(
                voices: state.voices,
                microphone: state.microphone,
                soundboard: state.soundboard,
                speaking: carried.sorted { $0.userID < $1.userID } + state.speaking[state.speakingHead...]
            )
        }
    }
}
