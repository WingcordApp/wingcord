import SwiftUI
import WingcordCore

/// What the composer needs to draw a voice message.
///
/// **Plain values and closures, for the reason everything else on `Composer` is**: this
/// view reaches for nothing observable, and the settings preview draws it with nothing
/// behind it. A nil here is a composer with no microphone at all.
struct ComposerVoiceNote {
    enum Phase: Hashable {
        case idle, recording, review
    }

    var phase: Phase = .idle
    /// Whether the mic is offered while idle. Absent rather than dimmed where it can't
    /// work: see `VoiceNoteEligibility`.
    var isOffered = false
    var isPlaying = false
    var durationSeconds: Double = 0
    /// The held note's values, as the message will carry them.
    var values: [Float] = []
    /// What moves every frame, read by whoever's drawing it.
    var clock = VoiceNoteClock()

    var start: () -> Void = {}
    var stop: () -> Void = {}
    var discard: () -> Void = {}
    /// Sends it, told where it was on screen: the start of its flight, in bubbles.
    var send: (SendLaunch?) -> Void = { _ in }
    var togglePlay: () -> Void = {}
    /// A press on the bars, a fraction of the way through, and whether it's the press
    /// itself, which plays from there, or the drag after it.
    var seek: (Double, Bool) -> Void = { _, _ in }

    var isActive: Bool { phase != .idle }
    var isShown: Bool { isOffered || isActive }
}

/// What the bars and the timer read as they draw.
///
/// **Closures, not observation.** These change sixty times a second, and only mean
/// anything to a `Canvas` that's already redrawing.
@MainActor
struct VoiceNoteClock {
    var meter = VoiceNoteMeter()
    var level: () -> Float = { 0 }
    var elapsed: () -> Double = { 0 }
    /// When the recording stopped, on `Date`'s reference clock.
    var stoppedAt: () -> TimeInterval? = { nil }
    /// How far through the held note the player is. Nil is untouched.
    var position: () -> Double? = { nil }
    var rate: () -> Float = { 1 }
}

/// The strip's measurements, and how much of it the controls take in each phase.
///
/// **The strip's width doesn't change between phases.** The controls come and go over it
/// and it's told how much room they'll leave, so a bar's position is only ever what the
/// drawing says, never whatever a spring's made of the layout this frame.
struct ComposerVoiceLayout: Equatable {
    /// From the strip's trailing edge to where the bars must stop.
    var recordingReserve: CGFloat
    var reviewReserve: CGFloat

    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 6
    /// Room for "19:59", so the bars don't shift as the time counts.
    static let time: CGFloat = 36
    static let barsGap: CGFloat = 10

    /// Where bars may start, recording and in review. The dot's only there recording.
    static var liveMinX: CGFloat { dot + dotGap + time + barsGap }
    static var reviewMinX: CGFloat { time + barsGap }

    /// Messages' capsule: stop on its own at the end, then play with send beside it.
    static let messages = ComposerVoiceLayout(
        recordingReserve: MessagesSendButton.side + barsGap,
        reviewReserve: Metrics.composerControl + Spacing.hair + MessagesSendButton.side + barsGap
    )
    /// The other arrangements, whose send isn't in the field: the control keeps its place.
    static let inline = ComposerVoiceLayout(
        recordingReserve: Metrics.composerControl + barsGap,
        reviewReserve: Metrics.composerControl + barsGap
    )
}
