import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord
import WingcordCore

/// Send Compressed, Auto-compress Images and Discord's HEIC conversion, on
/// real files written for each test: what fits, what is refused, and in whose
/// words.
@Suite("Media compression")
@MainActor
struct MediaCompressionTests {

    private let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "MediaCompressionTests-\(UUID())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A picture of noise, which no encoder can shrink for free.
    private func noise(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    private func write(_ image: CGImage, as type: UTType, named name: String, quality: Double = 1) throws -> URL {
        let url = folder.appending(path: name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func pixels(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @Test("A photograph over the limit comes back a JPEG under it, upright and smaller")
    func picture() async throws {
        let original = try write(noise(width: 2400, height: 1600), as: .jpeg, named: "holiday.png", quality: 1)
        let limit = 400_000
        #expect(size(original) > limit)
        let copy = try #require(await MediaCompressor.compress(original, toFit: limit))
        #expect(copy.lastPathComponent == "holiday.jpg")
        #expect(size(copy) <= limit)
        let (width, height) = try #require(pixels(copy))
        #expect(width <= 2400 && height <= 1600)
        // The shape is kept.
        #expect(abs(Double(width) / Double(height) - 1.5) < 0.01)
    }

    @Test("A picture with transparency stays a PNG and only gives up size")
    func transparent() async throws {
        let original = try write(noise(width: 1200, height: 1200, alpha: true), as: .png, named: "sticker.png")
        let limit = size(original) / 3
        let copy = try #require(await MediaCompressor.compress(original, toFit: limit))
        #expect(copy.pathExtension == "png")
        #expect(size(copy) <= limit)
    }

    @Test("A GIF is not compressed: a re-encode would keep one frame")
    func gif() {
        #expect(!MediaCompressor.canCompress(.gif))
        #expect(MediaCompressor.canCompress(.jpeg))
        #expect(MediaCompressor.canCompress(.mpeg4Movie))
        #expect(!MediaCompressor.canCompress(.zip))
    }

    @Test("A HEIC picture goes up as a JPEG under Discord's name, a big one as it is")
    func heic() throws {
        let original = try write(noise(width: 640, height: 480), as: .heic, named: "IMG_0001.HEIC", quality: 0.9)
        let jpeg = try #require(MediaCompressor.convertToJPEG(original, named: "IMG_0001.HEIC", size: size(original), .heic))
        #expect(jpeg.lastPathComponent == "IMG_0001.jpg")
        let source = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(MediaCompressor.convertToJPEG(original, named: "IMG_0001.HEIC", size: 21 * 1_048_576, .heic) == nil)
    }

    /// A short clip of noise at a bitrate far over what the limit allows.
    private func clip(seconds: Int = 2, width: Int = 1280, height: Int = 720) async throws -> URL {
        let url = folder.appending(path: "clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            arc4random_buf(CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test("A video over the limit comes back an MP4 under it, smaller and the same length")
    func video() async throws {
        let original = try await clip()
        let limit = 700_000
        #expect(size(original) > limit)
        let copy = try #require(await MediaCompressor.compress(original, toFit: limit))
        #expect(copy.lastPathComponent == "clip.mp4")
        #expect(size(copy) <= limit)
        let asset = AVURLAsset(url: copy)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        #expect(natural.width < 1280)
        #expect(abs(natural.width / natural.height - 1280.0 / 720.0) < 0.02)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.2)
    }

    @Test("The size a bitrate carries keeps the shape, is even, and never grows")
    func encodedSize() {
        let small = VideoTranscode.encodedSize(CGSize(width: 1920, height: 1080), bitrate: 1_000_000, frameRate: 30)
        #expect(small.width.truncatingRemainder(dividingBy: 2) == 0 && small.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(small.width < 1920)
        #expect(abs(small.width / small.height - 16.0 / 9.0) < 0.02)
        let same = VideoTranscode.encodedSize(CGSize(width: 640, height: 360), bitrate: 50_000_000, frameRate: 30)
        #expect(same == CGSize(width: 640, height: 360))
    }

    // MARK: Staging

    private let dm = ChannelID(rawValue: 1001)

    private func model() -> AppModel {
        let model = AppModel()
        model.channelIndex.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [UserID(rawValue: 2)]),
        ])
        return model
    }

    @Test("A picture over the limit is offered Send Compressed, in Discord's words")
    func offered() throws {
        let model = model()
        let big = try write(noise(width: 3000, height: 3000), as: .png, named: "big.png")
        let limit = model.uploadLimit(in: dm)
        try #require(size(big) > limit)
        model.stageAttachments([big], in: dm)
        let refusal = try #require(model.messages(in: dm)?.attachmentRefusal)
        #expect(refusal.title == "Your files are too powerful")
        #expect(refusal.help.hasPrefix("To upload images larger than 10.00 MB"))
        #expect(refusal.compressible == [big])
        #expect(refusal.offersAlwaysCompress)
        #expect(model.messages(in: dm)?.attachments.isEmpty == true)
    }

    @Test("A file nothing can shrink is refused with the limit, and an empty one is empty")
    func refused() throws {
        let model = model()
        let archive = folder.appending(path: "archive.zip")
        try Data(count: model.uploadLimit(in: dm) + 1).write(to: archive)
        model.stageAttachments([archive], in: dm)
        let refusal = try #require(model.messages(in: dm)?.attachmentRefusal)
        #expect(refusal.help == "Max file size is 10.00 MB please.")
        #expect(refusal.compressible.isEmpty)

        let empty = folder.appending(path: "empty.txt")
        try Data().write(to: empty)
        model.stageAttachments([empty], in: dm)
        #expect(model.messages(in: dm)?.attachmentRefusal == .empty)
        model.stageAttachments([folder], in: dm)
        #expect(model.messages(in: dm)?.attachmentRefusal == .empty)
    }

    @Test("Send Compressed stages the copy and leaves nothing to refuse")
    func sendCompressed() async throws {
        let model = model()
        let big = try write(noise(width: 3000, height: 3000), as: .png, named: "big.png")
        model.stageAttachments([big], in: dm)
        let offered = try #require(model.messages(in: dm)?.attachmentRefusal?.compressible)
        model.compressAttachments(offered, in: dm)
        #expect(model.messages(in: dm)?.compressingFiles == 1)
        #expect(model.messages(in: dm)?.attachmentRefusal == nil)
        for _ in 0..<600 where model.messages(in: dm)?.compressingFiles != 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let staged = try #require(model.messages(in: dm)?.attachments.first)
        #expect(staged.filename == "big.jpg")
        #expect(staged.size <= model.uploadLimit(in: dm))
        #expect(model.messages(in: dm)?.attachmentRefusal == nil)
    }
}
