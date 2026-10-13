import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WingcordCore

/// A picture or a video made small enough for the account's upload limit —
/// Send Compressed and Auto-compress Images (DESIGN-NOTES §14) — and Discord's
/// desktop conversion of a HEIC or JXR picture to a JPEG.
///
/// **Adaptive, not a fixed preset.** A picture keeps its size and gives up
/// quality first, down to a floor, and only then gives up pixels. A video's
/// bitrate is what the limit leaves for its length, and its size is what that
/// bitrate carries well. Each is measured after it is written, and a video
/// that overshot is written again at a bitrate scaled by how far over it went.
///
/// **A copy, in a folder of its own** in the temporary directory, under the
/// original's name with the new format's ending: the reader's file is never
/// touched, and two pictures called `IMG_0001.HEIC` never meet. The copy
/// carries no metadata — a compressed photograph does not take its location
/// with it.
nonisolated enum MediaCompressor {
    /// The share of the limit aimed at, so a container's own bytes and an
    /// encoder's overshoot land under it.
    static let headroom = 0.95

    /// Whether `compress` can try: a still picture or a video. A GIF moves,
    /// and a re-encode would keep one frame of it.
    static func canCompress(_ type: UTType?) -> Bool {
        guard let type, !type.conforms(to: .gif) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// Whether the file at `url` is a picture — what Auto-compress Images
    /// speaks for.
    static func isPicture(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) ?? false
    }

    /// A copy of `url` that fits `limit`, or nil when nothing here can make
    /// one — not a picture or a video, a picture that moves, or a video too
    /// long for the limit to carry.
    static func compress(
        _ url: URL,
        toFit limit: Int,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> URL? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard canCompress(type), let type else { return nil }
        if type.conforms(to: .movie) {
            return await VideoTranscode.compress(url, toFit: limit, progress: progress)
        }
        return await Task.detached(priority: .userInitiated) { compressPicture(url, toFit: limit) }.value
    }

    // MARK: Pictures

    /// The smallest side a picture is taken down to before giving up.
    static let minimumSide = 256
    /// The lowest JPEG quality tried: below it a photograph is blocks.
    static let qualityFloor = 0.4

    /// The best JPEG that fits at full size; failing that, at three quarters
    /// of the size, and so on. A picture with transparency stays a PNG and
    /// only ever gives up size.
    static func compressPicture(_ url: URL, toFit limit: Int) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let keepsAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let target = Int(Double(limit) * headroom)
        var side = max(width, height)
        while side >= minimumSide {
            guard let image = orientedImage(source, side: side) else { return nil }
            let data = keepsAlpha ? encode(image, as: .png) : bestJPEG(image, under: target)
            if let data, data.count <= target {
                return write(data, named: url.deletingPathExtension().lastPathComponent + (keepsAlpha ? ".png" : ".jpg"))
            }
            side = side * 3 / 4
        }
        return nil
    }

    /// Discord's desktop conversion (`85582`): a HEIC or JXR picture, whole, as
    /// a JPEG at Discord's quality and under Discord's name for it — nil for
    /// one bigger than Discord converts, which goes up as it is.
    static func convertToJPEG(_ url: URL, named filename: String, size: Int, _ conversion: UploadConversion) -> URL? {
        guard size <= conversion.maximumBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = orientedImage(source, side: max(width, height)),
              let data = encode(image, as: .jpeg, quality: conversion.quality)
        else { return nil }
        return write(data, named: UploadConversion.jpegName(for: filename))
    }

    /// The picture upright — its orientation applied rather than carried as
    /// metadata the copy drops — at most `side` pixels on its longer edge.
    private static func orientedImage(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary)
    }

    /// The highest quality between 0.9 and the floor that comes in under
    /// `target`: five halvings of the range.
    static func bestJPEG(_ image: CGImage, under target: Int) -> Data? {
        if let top = encode(image, as: .jpeg, quality: 0.9), top.count <= target { return top }
        var low = qualityFloor
        var high = 0.9
        var best: Data?
        for _ in 0..<5 {
            let middle = (low + high) / 2
            guard let data = encode(image, as: .jpeg, quality: middle) else { return nil }
            if data.count <= target {
                best = data
                low = middle
            } else {
                high = middle
            }
        }
        if best == nil, let floor = encode(image, as: .jpeg, quality: qualityFloor), floor.count <= target {
            best = floor
        }
        return best
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// A new folder for one copy, under the name it will be sent as.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Wingcord Compressed", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func write(_ data: Data, named filename: String) -> URL? {
        guard let url = try? folder().appending(path: AttachmentDownloads.safeName(filename)) else { return nil }
        return (try? data.write(to: url)) == nil ? nil : url
    }
}

/// One video's re-encode: a reader for its first video and audio tracks, a
/// writer for an MP4 of H.264 and AAC — which every Discord client plays —
/// and a pump between each pair on a queue of its own.
///
/// **Unchecked-sendable because AVFoundation's types are not**, and each is
/// only touched on the one queue its pump runs on, or before the pumps start
/// and after they finish.
nonisolated final class VideoTranscode: @unchecked Sendable {
    /// The sound's bitrate, which every budget pays first.
    static let audioBitrate = 96_000
    /// Below this a video is mush at any size: not worth sending.
    static let minimumVideoBitrate = 150_000.0
    /// Bits a pixel a frame that H.264 needs to look like the video — 720p at
    /// 30 frames is 2.8 Mbps.
    static let bitsPerPixel = 0.1

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderTrackOutput?
    private let audioInput: AVAssetWriterInput?
    private let duration: Double
    private let progress: @Sendable (Double) -> Void

    /// A copy of the video at `url` that fits `limit`, written at most three
    /// times, or nil.
    static func compress(
        _ url: URL,
        toFit limit: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await video.load(.naturalSize),
              let frameRate = try? await video.load(.nominalFrameRate)
        else { return nil }
        let transform = (try? await video.load(.preferredTransform)) ?? .identity
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        var budget = Double(limit) * MediaCompressor.headroom * 8 / duration
        for _ in 0..<3 {
            let videoBitrate = budget - Double(audio == nil ? 0 : audioBitrate)
            guard videoBitrate >= minimumVideoBitrate else { return nil }
            let size = encodedSize(natural, bitrate: videoBitrate, frameRate: Double(frameRate))
            guard let folder = try? MediaCompressor.folder() else { return nil }
            let output = folder.appending(path: AttachmentDownloads.safeName(
                url.deletingPathExtension().lastPathComponent + ".mp4"
            ))
            guard let transcode = try? VideoTranscode(
                asset: asset, video: video, audio: audio, to: output, size: size,
                transform: transform, videoBitrate: videoBitrate, frameRate: Double(frameRate),
                duration: duration, progress: progress
            ), await transcode.run()
            else {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
            let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if bytes <= limit { return output }
            try? FileManager.default.removeItem(at: folder)
            budget *= Double(limit) * MediaCompressor.headroom / Double(bytes)
        }
        return nil
    }

    /// The largest size, in the video's own shape, whose pixels the bitrate
    /// carries at `bitsPerPixel` a frame — never larger than it was, and even
    /// on both sides, as H.264's chroma needs.
    static func encodedSize(_ natural: CGSize, bitrate: Double, frameRate: Double) -> CGSize {
        let frames = max(1, min(frameRate, 60))
        let area = max(1, natural.width * natural.height)
        let scale = min(1, (bitrate / (bitsPerPixel * frames) / area).squareRoot())
        func even(_ side: CGFloat) -> CGFloat { max(2, (side * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(natural.width), height: even(natural.height))
    }

    private init(
        asset: AVAsset,
        video: AVAssetTrack,
        audio: AVAssetTrack?,
        to output: URL,
        size: CGSize,
        transform: CGAffineTransform,
        videoBitrate: Double,
        frameRate: Double,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // The index first, so a player can start before the end has arrived.
        writer.shouldOptimizeForNetworkUse = true
        self.duration = duration
        self.progress = progress

        videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            // The frames are scaled to the size; their shape was kept above.
            AVVideoScalingModeKey: AVVideoScalingModeResize,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(videoBitrate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(frameRate.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        // Turned as it was recorded, by the player rather than by re-drawing.
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw CocoaError(.fileWriteUnknown) }
        reader.add(videoOutput)
        writer.add(videoInput)

        if let audio {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: Self.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioOutput = output
                audioInput = input
            } else {
                audioOutput = nil
                audioInput = nil
            }
        } else {
            audioOutput = nil
            audioInput = nil
        }
    }

    /// Reads, encodes and writes the whole video; true when the file is whole.
    private func run() async -> Bool {
        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        async let video: Void = pump(videoOutput, into: videoInput, reportsProgress: true)
        if let audioOutput, let audioInput {
            await pump(audioOutput, into: audioInput, reportsProgress: false)
        }
        await video
        guard reader.status == .completed else {
            writer.cancelWriting()
            return false
        }
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// Moves one track's samples from the reader to the writer whenever the
    /// writer can take more, until the track ends or the writer refuses one.
    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, reportsProgress: Bool) async {
        let queue = DispatchQueue(label: "dev.wingcord.Wingcord.compress.\(input.mediaType.rawValue)")
        let finished = Finished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData, !finished.isSet {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        finished.isSet = true
                        continuation.resume()
                        return
                    }
                    if reportsProgress {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if time.isFinite { progress(min(1, max(0, time / duration))) }
                    }
                }
            }
        }
    }

    /// Whether a pump has finished — read and written only on its queue.
    private final class Finished: @unchecked Sendable {
        var isSet = false
    }
}
