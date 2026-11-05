import Foundation

/// Something that sounds enough like talking to have a waveform: a pitched buzz through
/// three vowel resonances, in syllables with pauses between phrases.
///
/// **Not the system's speech**, which needs a run loop and takes a while to answer. This
/// is a loop that can't fail, for a recording the demo has to start at once.
nonisolated struct SyntheticVoice {
    private var sample = 0
    private var phase = 0.0
    private var filters = [Resonator(), Resonator(), Resonator()]
    private var syllable = 0
    private var syllableStart = 0
    private var syllableLength = 12_000
    private var loudness = 0.6
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    private mutating func random() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 10_000) / 10_000
    }

    /// One frame of samples, and how loud it came out.
    mutating func fill(_ frame: inout [Int16]) -> Float {
        var sum = 0.0
        for index in frame.indices {
            let elapsed = sample - syllableStart
            if elapsed >= syllableLength { nextSyllable() }
            let progress = Double(sample - syllableStart) / Double(syllableLength)
            // Every seventh syllable's a breath, and that's where a waveform dips.
            let isPause = syllable % 7 == 6
            let envelope = isPause ? 0 : pow(sin(.pi * min(1, progress)), 0.6)
            let pitch = 118 + 26 * sin(Double(sample) / 48_000 * 1.7) - 14 * progress
            phase += pitch / 48_000
            if phase >= 1 { phase -= 1 }
            // A buzz with a sharp edge, which is what the vowels below have to shape.
            let source = (phase < 0.12 ? 1 - phase / 0.12 : 0) * 2 - 0.25
            var output = 0.0
            for filter in filters.indices { output += filters[filter].process(source) }
            let value = max(-1, min(1, output * envelope * 0.05 * loudness))
            frame[index] = Int16(value * 32_000)
            sum += value * value
            sample += 1
        }
        return Float((sum / Double(frame.count)).squareRoot())
    }

    private mutating func nextSyllable() {
        syllable += 1
        syllableStart = sample
        syllableLength = Int(7_200 + random() * 11_000)
        // Some stressed and some not: what makes speech's bars the shape they are.
        loudness = 0.2 + pow(random(), 1.6) * 0.8
        // Open vowels, near enough: low, middle and high resonances.
        let first = 340 + random() * 480
        let second = 900 + random() * 1_200
        filters[0].tune(frequency: first, bandwidth: 90)
        filters[1].tune(frequency: second, bandwidth: 120)
        filters[2].tune(frequency: 2_600, bandwidth: 180)
    }
}

/// A two-pole filter: one vowel's resonance.
nonisolated private struct Resonator {
    private var a1 = 0.0
    private var a2 = 0.0
    private var gain = 0.1
    private var y1 = 0.0
    private var y2 = 0.0

    init() {
        tune(frequency: 500, bandwidth: 90)
    }

    mutating func tune(frequency: Double, bandwidth: Double) {
        let radius = exp(-.pi * bandwidth / 48_000)
        a1 = 2 * radius * cos(2 * .pi * frequency / 48_000)
        a2 = -radius * radius
        gain = 1 - radius
    }

    mutating func process(_ input: Double) -> Double {
        let output = gain * input * 8 + a1 * y1 + a2 * y2
        y2 = y1
        y1 = output
        return output
    }
}
