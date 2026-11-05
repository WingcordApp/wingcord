import CoreGraphics
import Foundation

/// A voice message's waveform: what's sent, what's read, and where its bars go.
///
/// **Discord's rules, from its web build**, so a note made here looks right there
/// and one made there looks right here: `264391`'s sampling, `934581`'s averaging,
/// and `87466`'s bars.
public enum VoiceWaveform {

    /// The most bytes a message carries.
    public static let maximumSamples = 256

    // MARK: Bars

    /// A bar's width, and how far one is from the next.
    public static let barWidth: CGFloat = 2
    public static let barStep: CGFloat = 6
    public static let barCorner: CGFloat = 1
    /// How tall a bar gets, and the least it ever is: silence is still a dot.
    public static let barMaximumHeight: CGFloat = 24
    public static let barMinimumHeight: CGFloat = 2

    /// How tall a value draws: `87466`'s `22v + 2`.
    public static func barHeight(_ value: Float) -> CGFloat {
        CGFloat(max(0, min(1, value))) * (barMaximumHeight - barMinimumHeight) + barMinimumHeight
    }

    /// How many bars fit a width: `87466`'s `(w + 4) / 6`. The last has no gap after it.
    public static func barCount(forWidth width: CGFloat) -> Int {
        max(0, Int(((width + 4) / barStep).rounded(.down)))
    }

    /// How wide a message's bars are, by how long it runs: 40 points at half a
    /// second, 294 at 45 seconds and beyond, snapped to whole bars (`87466`'s `N`).
    public static func width(forDuration seconds: Double) -> CGFloat {
        let wanted: Double = if seconds <= 0.5 {
            40
        } else if seconds >= 45 {
            294
        } else {
            (min(seconds, 45) - 0.5) / 44.5 * 254 + 40
        }
        return barStep * (CGFloat((wanted + 4) / Double(barStep))).rounded(.down) - 4
    }

    // MARK: Sampling

    /// One frame's level as a byte: `264391`'s dB, clamped to −100…0 and mapped to
    /// 0…255.
    public static func sample(level: Float) -> UInt8 {
        let decibels = level > 0 ? 20 * log10(level) : -100
        let clamped = max(-100, min(0, decibels))
        return UInt8(((clamped + 100) / 100 * 255).rounded())
    }

    /// Averages down to `count`: `934581`, whose buckets are rounded rather than
    /// cut, so none is left empty and the last reaches the end.
    public static func downsample(_ values: [Double], to count: Int) -> [Double] {
        guard count > 0, values.count > count else { return values }
        let width = Double(values.count) / Double(count)
        var result: [Double] = []
        result.reserveCapacity(count)
        var start = 0
        while result.count < count {
            let end = Int((Double(result.count + 1) * width).rounded())
            let bucket = values[start..<min(max(end, start), values.count)]
            result.append(bucket.isEmpty ? 0 : bucket.reduce(0, +) / Double(bucket.count))
            start = end
        }
        return result
    }

    /// What a message carries: at most 256 bytes, in base64. Empty for nothing.
    public static func encode(_ samples: [UInt8]) -> String {
        guard !samples.isEmpty else { return "" }
        let values = downsample(samples.map(Double.init), to: maximumSamples)
        return Data(values.map { UInt8(min($0.rounded(), 255)) }).base64EncodedString()
    }

    /// The values 0…1 a message carried. Empty when it has none, or when they aren't
    /// base64: a row that can't read its bars still plays.
    public static func decode(_ base64: String?) -> [Float] {
        guard let base64, let data = Data(base64Encoded: base64) else { return [] }
        return data.map { Float($0) / 255 }
    }

    /// As many bars as there's room for: `87466`. Too many are averaged. Too few are
    /// spread out to fill it, which is the composer's review; a message's own width
    /// follows its length, so it rarely has to.
    public static func bars(_ values: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        guard values.count != count else { return values }
        if values.count > count {
            return downsample(values.map(Double.init), to: count).map(Float.init)
        }
        guard values.count > 1, count > 1 else { return Array(repeating: values[0], count: count) }
        return (0..<count).map { index in
            let position = Double(index) * Double(values.count - 1) / Double(count - 1)
            let below = Int(position)
            let above = min(values.count - 1, below + 1)
            let fraction = Float(position - Double(below))
            return values[below] * (1 - fraction) + values[above] * fraction
        }
    }

    // MARK: What's drawn

    /// How a note's values draw.
    ///
    /// **The bytes stay Discord's and only the drawing moves.** Discord's mapping
    /// spans −100…0 dB, and speech sits in a small part of that: measured on a spoken
    /// sentence, almost every byte fell between 0.7 and 0.85, so the bars were a flat
    /// comb with a nick at each pause. So each note's own quiet end and loud end are
    /// pulled apart for the eye. A note that really is one level stays flat rather
    /// than having its noise blown up, and silence stays silent.
    ///
    /// **Only a note with a voice in it.** Stretching a quiet room to the full height makes
    /// nobody talking look like somebody shouting: measured at −49 dB, its noise spans enough
    /// to fill the bars. So what's stretched is blended with `liveValue`'s fixed scale, by how
    /// loud the note's peak is: all fixed for a room at −40 dB, all stretched from −25.
    public static func displayed(_ values: [Float]) -> [Float] {
        guard values.count > 1 else { return values }
        let sorted = values.sorted()
        let low = sorted[(sorted.count - 1) / 10]
        let high = sorted[(sorted.count - 1) * 49 / 50]
        guard high - low > 0.04 else { return values }
        let stretch = max(0, min(1, (high - 0.6) / 0.15))
        return values.map { value in
            let spread = max(0, min(1, (value - low) / (high - low)))
            // A touch of curve: a pause should read as a pause, not as a low bar.
            let stretched = spread * spread * (3 - 2 * spread)
            // −55…−10 dB, as bytes on Discord's scale of −100…0.
            let fixed = max(0, min(1, (value - 0.45) / 0.45))
            return stretched * stretch + fixed * (1 - stretch)
        }
    }

    /// A level as the live bars draw it: a scale that speech actually fills, from a
    /// quiet room at −55 dB to a loud voice at −10. Not what's sent, only what's
    /// shown while it's being said.
    public static func liveValue(level: Float) -> Float {
        guard level > 0 else { return 0 }
        return max(0, min(1, (20 * log10(level) + 55) / 45))
    }

    // MARK: How they move

    /// Discord's `easeOutBack`, 0…1, overshooting on the way.
    public static func easeOutBack(_ progress: Double, overshoot: Double) -> Double {
        let t = max(0, min(1, progress)) - 1
        return t * t * ((overshoot + 1) * t + overshoot) + 1
    }

    /// A bar the playhead has passed, this many seconds ago: it swells past its own
    /// height and settles, Discord's `539451`, 500 ms with an overshoot of 4.
    ///
    /// **Worked out from the playhead, so nothing holds per-bar state**, and a seek
    /// doesn't set off a burst: everything but the last half second is simply settled.
    public static func popped(_ value: Float, age: Double) -> Float {
        guard age < 0.5 else { return value }
        return max(value * Float(easeOutBack(age / 0.5, overshoot: 4)), value - 0.1)
    }

    /// How much longer the fall and the rise take than Discord's.
    ///
    /// **Its shape, at 1.6 times its length.** Filmed across a window-wide capsule, Discord's
    /// own 100 ms and 160 ms were over in a few frames and read as a flicker, not as bars
    /// falling and rising. The stagger and the overshoot are its numbers.
    private static let stoppingPace = 1.6

    /// Bars rising from dots across the width, this many seconds after they started:
    /// Discord's `g`, a 60 ms stagger and 100 ms each, ease-out-back.
    public static func entrance(elapsed: Double, index: Int, count: Int) -> Float {
        let milliseconds = elapsed * 1_000 / stoppingPace
        let delay = count > 1 ? Double(index) / Double(count - 1) * 60 : 0
        return Float(max(0, easeOutBack((milliseconds - delay) / 100, overshoot: 2)))
    }

    /// Whether the entrance has finished, and the bars can be drawn as they are.
    public static let entranceDuration = 0.16 * stoppingPace

    /// Live bars falling to dots, left to right: Discord's `eZ`, a 40 ms stagger and
    /// 60 ms each, so all of them are down by 100 ms at its pace.
    public static func collapsed(_ value: Float, elapsed: Double, index: Int, count: Int) -> Float {
        let milliseconds = elapsed * 1_000 / stoppingPace
        let delay = count > 1 ? Double(index) / Double(count - 1) * 40 : 0
        let progress = Float(max(0, min(1, (milliseconds - delay) / 60)))
        return value * (1 - progress * progress)
    }

    public static let collapseDuration = 0.1 * stoppingPace

    // MARK: How long

    /// "0:12", "19:59": `eK.rB`.
    public static func timeLabel(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// Discord's limits on recording (`518950`).
public enum VoiceMessageLimits {
    /// It stops itself here.
    public static let maximumSeconds = 1_199.5
    /// The timer turns red and blinks every half second, with 30 seconds left…
    public static let warningSeconds = 1_169.5
    /// …and every quarter second, with 15 left.
    public static let urgentSeconds = 1_184.5
    /// Shorter than this is a slip of the hand, and is dropped.
    public static let minimumSeconds = 0.5
    /// The file's name on the wire.
    public static let filename = "voice-message.ogg"
    /// The speeds a message plays at, which the row's pill steps through.
    public static let playbackRates: [Float] = [0.75, 1, 1.5, 2]
}
