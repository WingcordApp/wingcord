import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import WingcordCore

// MARK: - Exporting an edited clip
//
// docs/CLIPS-PRESENCE.md, Phases 4.3–4.4 and 5.6. The editor's metadata
// applied for real: the graph (`ClipRenderGraph`) read back drawn and mixed —
// a shared clip has one sound, as Discord's export does — and the picture
// encoded at a bitrate chosen to **fit under the account's upload limit**
// when there is one; or the same frames written as a GIF. The macOS 27 reader
// and writer: `outputProvider`, `inputReceiver`.

public enum ClipExporter {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    public struct Request: @unchecked Sendable {
        public var input: ClipRenderInput
        public var format: ClipExportSettings.Format
        /// The largest the file may be — the account's upload limit.
        public var maxBytes: Int?
        /// The canvas's shorter side is never written larger than this.
        public var maxShortSide: Int?
        public var destination: URL

        public init(
            input: ClipRenderInput, format: ClipExportSettings.Format = .mp4, maxBytes: Int? = nil,
            maxShortSide: Int? = nil, destination: URL
        ) {
            self.input = input
            self.format = format
            self.maxBytes = maxBytes
            self.maxShortSide = maxShortSide
            self.destination = destination
        }

        /// v1's shape: one kept stretch, a crop, the camera, overlays on the
        /// source's clock.
        public init(
            source: URL, camera: URL? = nil, cameraOffset: Double = 0, range: ClosedRange<Double>,
            crop: CGRect? = nil, cameraPlacement: (x: Double, y: Double, diameter: Double)? = nil,
            audioTracks: [Int]? = nil, overlays: [RenderedOverlay] = [], maxHeight: Int = 1_080,
            maxBytes: Int? = nil, destination: URL
        ) {
            input = ClipRenderInput(
                source: source, camera: camera, cameraOffset: cameraOffset,
                segments: [ClipSegment(start: range.lowerBound, end: range.upperBound)],
                crop: crop, cameraPlacement: cameraPlacement, audioTracks: audioTracks, overlays: overlays
            )
            format = .mp4
            self.maxBytes = maxBytes
            maxShortSide = maxHeight
            self.destination = destination
        }
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case noPicture
        case tooLong
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noPicture: "There is no picture in that file."
            case .tooLong: "That is too long to fit under your upload limit. Trim it first."
            case .failed(let reason): "The clip could not be exported: \(reason)"
            }
        }
    }

    /// The video bitrate and picture height a clip of `duration` seconds gets
    /// under `maxBytes` — a margin for the container, the sound at 128k (64k
    /// when it is tight), and a smaller picture when the bits are few.
    public static func budget(duration: Double, maxBytes: Int?, sourceHeight: Int, maxHeight: Int, framerate: Double)
        -> (videoBitrate: Int, audioBitrate: Int, height: Int)?
    {
        let height = min(sourceHeight, maxHeight)
        let fullRate = Int(8_000_000 * Double(height * height) / Double(1_080 * 1_080) * (framerate > 30 ? 1.5 : 1))
        guard let maxBytes else { return (fullRate, 160_000, height) }
        let seconds = max(duration, 0.5)
        let totalBits = Double(maxBytes) * 8 * 0.92
        var audio = 128_000
        var video = Int(totalBits / seconds) - audio
        if video < 1_000_000 {
            audio = 64_000
            video = Int(totalBits / seconds) - audio
        }
        guard video >= 150_000 else { return nil }
        let fitted: Int = switch video {
        case ..<700_000: min(height, 480)
        case ..<2_000_000: min(height, 720)
        default: height
        }
        return (min(video, fullRate), audio, fitted)
    }

    public static func export(_ request: Request, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        do {
            switch request.format {
            case .mp4: return try await exportMovie(request, progress: progress)
            case .gif: return try await exportGIF(request, progress: progress)
            }
        } catch let failure as ClipRenderGraph.Failure {
            switch failure {
            case .noPicture: throw Failure.noPicture
            case .failed(let reason): throw Failure.failed(reason)
            }
        }
    }

    // MARK: MP4

    private static func exportMovie(_ request: Request, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        // First pass: the graph as asked, to learn the edit's length and size.
        var input = request.input
        var graph = try await ClipRenderGraph.build(input)
        if let cap = request.maxShortSide, Int(min(graph.renderSize.width, graph.renderSize.height)) > cap {
            input.shortSide = cap
            graph = try await ClipRenderGraph.build(input)
        }
        let shortSide = Int(min(graph.renderSize.width, graph.renderSize.height))
        guard let budget = budget(
            duration: graph.duration, maxBytes: request.maxBytes, sourceHeight: shortSide,
            maxHeight: shortSide, framerate: graph.framerate
        ) else { throw Failure.tooLong }
        if budget.height < shortSide {
            // Fewer bits than the picture needs: a smaller canvas.
            input.shortSide = budget.height
            graph = try await ClipRenderGraph.build(input)
        }
        let renderSize = graph.renderSize

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: graph.composition) } catch { throw Failure.failed(error.localizedDescription) }
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: graph.videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = graph.videoComposition
        let videoProvider = reader.outputProvider(for: videoOutput)
        var audioProvider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>?
        if !graph.audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: graph.audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            audioOutput.audioMix = graph.audioMix
            audioOutput.audioTimePitchAlgorithm = .spectral
            audioProvider = reader.outputProvider(for: audioOutput)
        }

        try? FileManager.default.removeItem(at: request.destination)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: request.destination, fileType: .mp4) } catch {
            throw Failure.failed(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        // H.264: every Discord client plays it; HEVC is not everywhere.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: budget.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        let videoReceiver = writer.inputReceiver(for: videoInput)
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if audioProvider != nil {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: budget.audioBitrate,
            ])
            audioReceiver = writer.inputReceiver(for: audioInput)
        }

        do {
            try reader.start()
            try writer.start()
        } catch {
            throw Failure.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? error.localizedDescription)
        }
        writer.startSession(atSourceTime: .zero)

        let total = graph.duration
        let pipes = ExportPipes(
            video: (videoProvider, videoReceiver), audio: audioProvider.flatMap { provider in audioReceiver.map { (provider, $0) } }
        )
        try await pipes.run(total: total, progress: progress)

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown")
        }
        log.info("clips: exported \(String(format: "%.1f", total), privacy: .public) s at \(Int(renderSize.width), privacy: .public)×\(Int(renderSize.height), privacy: .public)")
        return request.destination
    }

    // MARK: GIF

    /// The edit as a looping GIF: few frames, small, and — under a limit —
    /// smaller again until it fits.
    private static func exportGIF(_ request: Request, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        var input = request.input
        var shortSide = min(input.shortSide ?? ClipExportSettings.gifShortSide, ClipExportSettings.gifShortSide)
        var rate = ClipExportSettings.gifFramerate
        for _ in 0..<4 {
            input.shortSide = shortSide
            input.framerate = rate
            let graph = try await ClipRenderGraph.build(input)
            let frames = try await gifFrames(graph, rate: rate, progress: progress)
            try writeGIF(frames, delay: 1 / rate, to: request.destination)
            let bytes = (try? request.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let limit = request.maxBytes, bytes > limit else { return request.destination }
            // Too big: fewer pixels first, then fewer frames.
            shortSide = Int(Double(shortSide) * 0.75)
            rate = max(8, rate * 0.8)
        }
        throw Failure.tooLong
    }

    private static func gifFrames(_ graph: ClipRenderGraph, rate: Double, progress: (@Sendable (Double) -> Void)?) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: graph.composition)
        generator.videoComposition = graph.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = graph.renderSize
        let count = max(1, Int((graph.duration * rate).rounded(.down)))
        let times = (0..<count).map { CMTime(seconds: Double($0) / rate, preferredTimescale: 600) }
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for await result in generator.images(for: times) {
            if let image = try? result.image { frames.append(image) }
            progress?(Double(frames.count) / Double(count))
        }
        guard !frames.isEmpty else { throw Failure.failed("no frames") }
        return frames
    }

    static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw Failure.failed("no GIF writer") }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let properties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(destination, frame, properties) }
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("the GIF could not be written") }
    }
}

/// The reader's providers joined to the writer's receivers, each pair on a
/// task of its own — the writer holds back whichever runs ahead, which is
/// what interleaves them. `@unchecked` for the AVFoundation objects handed
/// over `sending`, each touched by its own task only.
private final class ExportPipes: @unchecked Sendable {
    typealias Provider = AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
    let video: (Provider, AVAssetWriterInput.SampleBufferReceiver)
    let audio: (Provider, AVAssetWriterInput.SampleBufferReceiver)?

    init(video: (Provider, AVAssetWriterInput.SampleBufferReceiver), audio: (Provider, AVAssetWriterInput.SampleBufferReceiver)?) {
        self.video = video
        self.audio = audio
    }

    func run(total: Double, progress: (@Sendable (Double) -> Void)?) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let sample = try await self.video.0.next() {
                    try await self.video.1.append(sample)
                    if total > 0 { progress?(min(1, sample.presentationTimeStamp.seconds / total)) }
                }
                self.video.1.finish()
            }
            if let audio = self.audio {
                group.addTask {
                    while let sample = try await audio.0.next() {
                        try await audio.1.append(sample)
                    }
                    audio.1.finish()
                }
            }
            try await group.waitForAll()
        }
    }
}
