import CoreGraphics
import Foundation
import WingcordCore

/// The bars going by while a note records.
///
/// **Not observed, and read once a frame by whoever's drawing them.** Sixty updates a
/// second through the store would re-evaluate every view that reads it, and these
/// numbers only mean anything to one `Canvas`. Discord's own are in a ref for the same
/// reason.
///
/// **Discord's numbers (`eZ`).** A new bar every 48 ms, its value smoothed by `.45`, and
/// the whole row moving one step (6 points) in that time, so nothing ever jumps. Each new
/// bar grows from a dot with a small overshoot.
@MainActor
final class VoiceNoteMeter {
    struct Bar {
        /// The value, 0…1.
        var value: Float
        /// When it arrived, on the clock `advance` is given.
        var born: TimeInterval
    }

    static let tick: TimeInterval = 0.048

    private(set) var bars: [Bar] = []
    /// How many there have ever been, since the oldest fall off the front.
    private(set) var total = 0
    private var smoothed: Float = 0
    private var lastTick: TimeInterval?
    /// How far through the current step the row has moved, 0…1.
    private(set) var stepProgress: CGFloat = 0
    /// The most a window could want, and a bit: there's no point keeping what's off the
    /// end of the row.
    private let capacity = 512

    func reset() {
        bars.removeAll(keepingCapacity: true)
        total = 0
        smoothed = 0
        lastTick = nil
        stepProgress = 0
    }

    /// Catches up to now, with the latest level. Called from the drawing.
    func advance(to now: TimeInterval, level: Float) {
        guard let last = lastTick else {
            lastTick = now
            return
        }
        // A frame that came late takes all the bars it owes, so the row's speed is the
        // clock's and doesn't depend on how fast it's being drawn.
        var tickTime = last
        while now - tickTime >= Self.tick {
            tickTime += Self.tick
            smoothed += (VoiceWaveform.liveValue(level: level) - smoothed) * 0.45
            bars.append(Bar(value: smoothed, born: tickTime))
            total += 1
        }
        if bars.count > capacity { bars.removeFirst(bars.count - capacity) }
        lastTick = tickTime
        stepProgress = CGFloat((now - tickTime) / Self.tick)
    }

    /// A bar's value right now: rising with Discord's overshoot, 500 ms.
    func height(of bar: Bar, at now: TimeInterval, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return VoiceWaveform.barHeight(bar.value) }
        let eased = VoiceWaveform.easeOutBack((now - bar.born) / 0.5, overshoot: 4)
        return VoiceWaveform.barMinimumHeight
            + CGFloat(bar.value) * (VoiceWaveform.barMaximumHeight - VoiceWaveform.barMinimumHeight) * CGFloat(eased)
    }
}
