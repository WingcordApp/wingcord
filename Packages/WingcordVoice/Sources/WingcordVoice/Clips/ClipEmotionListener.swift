import AVFoundation
import Foundation
import SoundAnalysis
import Synchronization

// MARK: - Laughter and shouting, heard on this Mac
//
// docs/CLIPS-PRESENCE.md, Phase 7.2 (D19). Discord's Auto Clips listens for
// laughter and shouting with a model it downloads (`/clips/module-assets`);
// the Mac has one already — SoundAnalysis's built-in classifier, whose 303
// labels include `laughter`, `belly_laugh`, `giggling`, `chuckle_chortle`,
// `snicker` and `shout`, `yell`, `screaming`, `battle_cry` (listed on macOS
// 27). Nothing leaves the machine and nothing is downloaded.
//
// **What it listens to is what a clip may keep** — the call's voices the
// consent rules let the tap keep, and the reader's own microphone — so Auto
// Clips hears nobody a manual clip could not.

public final class ClipEmotionListener: @unchecked Sendable {

    /// The strongest of each, 0…1, over what was heard.
    public struct Heard: Sendable, Equatable {
        public var laughter: Double
        public var shouting: Double

        public static let nothing = Heard(laughter: 0, shouting: 0)
    }

    public static let laughterLabels: Set<String> = [
        "laughter", "belly_laugh", "giggling", "chuckle_chortle", "snicker", "baby_laughter",
    ]
    public static let shoutingLabels: Set<String> = [
        "shout", "yell", "screaming", "battle_cry", "children_shouting",
    ]

    private static let rate = Double(OpusFormat.sampleRate)

    public init() {}

    /// Decodes `[start, end]` of the call's kept voices and the microphone to
    /// one mono signal and classifies it. Cheap enough to run every second or
    /// two: three seconds of a call is a few hundred Opus frames.
    public func listen(to snapshot: ClipAudioTap.Snapshot, from start: Double, to end: Double) -> Heard {
        guard end > start else { return .nothing }
        var tracks = Array(snapshot.voices.values)
        tracks.append(snapshot.microphone)
        let samples = Self.mix(tracks, from: start, to: end)
        guard samples.contains(where: { abs($0) > 0.01 }) else { return .nothing }
        return Self.classify(samples)
    }

    /// The tracks summed to mono, at 48 kHz, from `start`.
    static func mix(_ tracks: [TimedAudioTrack], from start: Double, to end: Double) -> [Float] {
        let count = Int(((end - start) * rate).rounded())
        guard count > 0 else { return [] }
        var mono = [Float](repeating: 0, count: count)
        let width = Int(OpusFormat.frameSize)
        var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
        for track in tracks {
            // A little before the window, so the decoder is warm when it
            // reaches the first frame that counts.
            let frames = track.frames(from: start - 0.2, to: end)
            guard !frames.isEmpty, let decoder = try? OpusDecoder() else { continue }
            for frame in frames {
                let written: Int? = pcm.withUnsafeMutableBufferPointer { buffer in
                    switch frame.payload {
                    case .opus(let bytes): try? decoder.decode(bytes, into: buffer.baseAddress!)
                    case .recovered(let successor):
                        try? decoder.decode(successor, recoverFromFEC: true, into: buffer.baseAddress!)
                    case .concealed: try? decoder.decode(nil, into: buffer.baseAddress!)
                    }
                }
                guard written != nil else { continue }
                let position = Int(((frame.time - start) * rate).rounded())
                for index in 0 ..< width {
                    let target = position + index
                    guard target >= 0, target < count else { continue }
                    let left = Float(pcm[index * 2]) / 32_768
                    let right = Float(pcm[index * 2 + 1]) / 32_768
                    mono[target] += (left + right) * 0.5
                }
            }
        }
        for index in mono.indices { mono[index] = min(max(mono[index], -1), 1) }
        return mono
    }

    /// The classifier over `samples`, in windows of a second and a half.
    static func classify(_ samples: [Float]) -> Heard {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
        else { return .nothing }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let observer = Collector()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            return .nothing
        }
        analyzer.analyze(buffer, atAudioFramePosition: 0)
        analyzer.completeAnalysis()
        return observer.heard
    }

    /// Keeps the strongest laughter and shouting the analyzer reports.
    private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let state = Mutex(Heard.nothing)

        var heard: Heard { state.withLock { $0 } }

        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var laughter = 0.0
            var shouting = 0.0
            for classification in result.classifications {
                if ClipEmotionListener.laughterLabels.contains(classification.identifier) {
                    laughter = max(laughter, classification.confidence)
                } else if ClipEmotionListener.shoutingLabels.contains(classification.identifier) {
                    shouting = max(shouting, classification.confidence)
                }
            }
            state.withLock { heard in
                heard.laughter = max(heard.laughter, laughter)
                heard.shouting = max(heard.shouting, shouting)
            }
        }
    }
}
