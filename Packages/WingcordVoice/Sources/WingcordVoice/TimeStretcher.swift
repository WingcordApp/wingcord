import Foundation

// MARK: - Time stretching (docs/ACTIVITIES-CALLS-PICKER.md, decision 11)
//
// NetEQ's two playout tools, in their simplest honest form. The jitter buffer
// sets its delay at the start of each talkspurt; inside one, a delay that has
// grown (a burst arrived) or is about to run out (packets slowing) had no
// remedy but to wait for the next silence or to go quiet mid-word. These change
// the length of one decoded frame by exactly one pitch period, which the ear
// does not hear: the waveform repeats every period anyway.
//
// - **Accelerate** drops one period: the frame plays shorter and the buffer
//   drains by that much (WebRTC's `Accelerate`).
// - **Preemptive expand** repeats one: the frame plays longer and the next
//   packet gets that much more time to arrive (`PreemptiveExpand`).
//
// Both splice with a cross-fade over the period (WSOLA), so the joins are
// continuous. A frame that isn't periodic enough (noise, a plosive) is left
// alone unless it's quiet, where nothing is heard either way.

public enum TimeStretcher {
    public enum Action: Sendable, Equatable {
        case none
        case accelerate
        case expand
    }

    /// The pitch periods searched, in 48 kHz samples: 100 Hz to 400 Hz,
    /// the range of the human voice's fundamental.
    static let shortestPeriod = 120
    static let longestPeriod = 480
    /// How alike two periods must be to splice inaudibly. NetEQ's own
    /// threshold for voiced speech is about this.
    static let correlationNeeded: Float = 0.6
    /// Below this level a splice is inaudible whatever the waveform.
    static let quietLevel: Float = 0.002

    /// The frame, one pitch period shorter or longer, or as it was.
    ///
    /// - Parameters:
    ///   - frame: interleaved samples, `channels` per instant.
    public static func stretch(_ frame: [Float], channels: Int, action: Action) -> [Float] {
        guard action != .none, channels > 0 else { return frame }
        let length = frame.count / channels
        guard length >= longestPeriod * 2 else { return frame }
        let mono = mixdown(frame, channels: channels, length: length)
        let level = rms(mono)
        let period: Int
        if let found = pitchPeriod(mono), found.correlation >= correlationNeeded {
            period = found.period
        } else if level < quietLevel {
            period = shortestPeriod * 2
        } else {
            return frame
        }
        switch action {
        case .none: return frame
        case .accelerate: return accelerate(frame, channels: channels, length: length, period: period)
        case .expand: return expand(frame, channels: channels, length: length, period: period)
        }
    }

    /// `blend(x[0..<P] out, x[P..<2P] in) ++ x[2P...]`: one period shorter.
    static func accelerate(_ frame: [Float], channels: Int, length: Int, period: Int) -> [Float] {
        var out = [Float](repeating: 0, count: (length - period) * channels)
        for index in 0..<period {
            let fadeIn = Float(index) / Float(period - 1)
            for channel in 0..<channels {
                let first = frame[index * channels + channel]
                let second = frame[(index + period) * channels + channel]
                out[index * channels + channel] = first * (1 - fadeIn) + second * fadeIn
            }
        }
        let tail = (2 * period) * channels
        out.replaceSubrange(period * channels..<out.count, with: frame[tail...])
        return out
    }

    /// `x[0..<P] ++ blend(x[P..<2P] out, x[0..<P] in) ++ x[P...]`: one period longer.
    static func expand(_ frame: [Float], channels: Int, length: Int, period: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity((length + period) * channels)
        out.append(contentsOf: frame[0..<(period * channels)])
        for index in 0..<period {
            let fadeIn = Float(index) / Float(period - 1)
            for channel in 0..<channels {
                let leaving = frame[(index + period) * channels + channel]
                let arriving = frame[index * channels + channel]
                out.append(leaving * (1 - fadeIn) + arriving * fadeIn)
            }
        }
        out.append(contentsOf: frame[(period * channels)...])
        return out
    }

    /// The lag at which the frame best resembles itself, coarse then fine:
    /// a search on a quarter-rate copy, refined at full rate around the best.
    static func pitchPeriod(_ mono: [Float]) -> (period: Int, correlation: Float)? {
        let window = longestPeriod
        guard mono.count >= longestPeriod + window else { return nil }
        // Coarse: every fourth sample.
        var bestLag = 0
        var best: Float = -1
        var lag = shortestPeriod
        while lag <= longestPeriod {
            let score = correlation(mono, lag: lag, window: window, stride: 4)
            if score > best { best = score; bestLag = lag }
            lag += 4
        }
        guard bestLag > 0 else { return nil }
        // Fine: every lag within the coarse step, every sample.
        var period = bestLag
        best = -1
        for candidate in max(shortestPeriod, bestLag - 4)...min(longestPeriod, bestLag + 4) {
            let score = correlation(mono, lag: candidate, window: window, stride: 1)
            if score > best { best = score; period = candidate }
        }
        return (period, best)
    }

    /// Normalised cross-correlation of `x[0..<window]` with `x[lag..<lag+window]`.
    static func correlation(_ x: [Float], lag: Int, window: Int, stride: Int) -> Float {
        var cross: Float = 0
        var first: Float = 0
        var second: Float = 0
        var index = 0
        while index < window {
            let a = x[index]
            let b = x[index + lag]
            cross += a * b
            first += a * a
            second += b * b
            index += stride
        }
        let denominator = (first * second).squareRoot()
        return denominator > 0 ? cross / denominator : 0
    }

    static func mixdown(_ frame: [Float], channels: Int, length: Int) -> [Float] {
        guard channels > 1 else { return Array(frame.prefix(length)) }
        var mono = [Float](repeating: 0, count: length)
        let scale = 1 / Float(channels)
        for index in 0..<length {
            var sum: Float = 0
            for channel in 0..<channels { sum += frame[index * channels + channel] }
            mono[index] = sum * scale
        }
        return mono
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
