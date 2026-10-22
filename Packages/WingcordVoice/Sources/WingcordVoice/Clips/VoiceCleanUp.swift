import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

// MARK: - Voice clean-up (docs/CLIPS-PRESENCE.md, D14 / Phase 5.5)
//
// One audio track of a clip run through Apple's own voice isolation
// (`AUSoundIsolation`, its high-quality voice model) offline, into a file of
// its own the editor's preview and export play instead of the track. The
// clip itself is never touched — edits are metadata; this is a derived file
// beside it, made again if it goes missing.

public enum VoiceCleanUp {
    public enum Failure: Error, LocalizedError, Sendable {
        case noTrack
        case unavailable
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noTrack: "That sound isn't in the clip."
            case .unavailable: "Voice clean-up isn't available on this Mac."
            case .failed(let reason): "The voice couldn't be cleaned up: \(reason)"
            }
        }
    }

    static let sampleRate = 48_000.0

    /// Cleans the audio track at `index` of `source` into an AAC file at
    /// `destination`.
    public static func process(
        source: URL, track index: Int, to destination: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let samples = try await readMono(source: source, track: index)
        guard !samples.isEmpty else { throw Failure.noTrack }
        try await isolate(samples, to: destination, progress: progress)
    }

    /// One audio track of `source` written out as a mono 48 kHz file — what
    /// on-device speech recognition reads captions from.
    public static func extractMono(source: URL, track index: Int, to destination: URL) async throws {
        let samples = try await readMono(source: source, track: index)
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw Failure.noTrack }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try? FileManager.default.removeItem(at: destination)
        do {
            let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch { throw Failure.failed(error.localizedDescription) }
    }

    /// The track as one run of mono float samples at 48 kHz.
    static func readMono(source: URL, track index: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.indices.contains(index) else { throw Failure.noTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.failed(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let provider = reader.outputProvider(for: output)
        do { try reader.start() } catch { throw Failure.failed(reader.error?.localizedDescription ?? error.localizedDescription) }
        var samples: [Float] = []
        while let sample = try await provider.next() {
            sample.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                guard count > 0 else { return }
                var chunk = [Float](repeating: 0, count: count)
                chunk.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            }
        }
        return samples
    }

    /// The voice model, offline: the samples played through it as fast as it
    /// renders, written as they come out.
    static func isolate(_ samples: [Float], to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { throw Failure.unavailable }
        let unit: AVAudioUnit
        do { unit = try await AVAudioUnit.instantiate(with: description, options: []) } catch { throw Failure.unavailable }
        if let tree = unit.auAudioUnit.parameterTree {
            tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value =
                AUValue(kAUSoundIsolationSoundType_HighQualityVoice)
            tree.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value = 100
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            try engine.start()
        } catch { throw Failure.failed(error.localizedDescription) }
        defer { engine.stop() }

        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { throw Failure.failed("no buffer") }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()

        try? FileManager.default.removeItem(at: destination)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw Failure.failed(error.localizedDescription) }

        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { throw Failure.failed("no buffer") }
        let total = AVAudioFramePosition(samples.count)
        while engine.manualRenderingSampleTime < total {
            try Task.checkCancellation()
            let frames = min(rendered.frameCapacity, AVAudioFrameCount(total - engine.manualRenderingSampleTime))
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(frames, to: rendered) } catch { throw Failure.failed(error.localizedDescription) }
            switch status {
            case .success:
                do { try file.write(from: rendered) } catch { throw Failure.failed(error.localizedDescription) }
                progress?(Double(engine.manualRenderingSampleTime) / Double(total))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw Failure.failed("the voice model stopped")
            @unknown default:
                throw Failure.failed("the voice model stopped")
            }
        }
    }
}
