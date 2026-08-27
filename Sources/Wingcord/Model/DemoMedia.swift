import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WingcordCore

/// Real media files for `--demo`, written once into the caches directory.
///
/// **The viewer cannot be seen without something to view**, and every other
/// fixture URL in this app deliberately 404s — which is the honest outcome for a
/// fabricated guild icon and a useless one for a lightbox. So these are actual
/// files: a picture large enough to zoom into, a loop with enough frames to
/// scrub, and a clip with a soundtrack-shaped duration.
///
/// The same argument the banner fixture already makes. An arrangement with real
/// arithmetic behind it that has never been on screen without an account is an
/// arrangement nobody has checked.
///
/// Written once and reused: the second launch finds them on disk and does
/// nothing at all.
nonisolated enum DemoMedia {

    /// Deliberately wider than `MediaStage.openingPixels`, so zooming past the
    /// close-up threshold actually escalates to the second rendition — the one
    /// branch in the loader that a small fixture would never reach.
    private static let stillSize = CGSize(width: 2400, height: 1500)
    private static let loopSide = 420
    private static let loopFrames = 24
    private static let clipSize = CGSize(width: 960, height: 540)
    private static let clipFrames = 90

    /// Where the files live. Caches rather than Application Support: they are
    /// derived, reproducible and worth nothing after a purge.
    private static var directory: URL {
        URL.cachesDirectory.appending(path: "dev.wingcord.Wingcord/DemoMedia", directoryHint: .isDirectory)
    }

    /// The three attachments, with their files already on disk.
    ///
    /// **Generated once for the process, not once per message that carries
    /// them.** The fixture builder asks per message and there are several, and
    /// the first version of this spawned an encoder per ask — seven
    /// `AVAssetWriter`s racing to write one file, every one of which failed and
    /// left no clip at all. A `static let` is initialised lazily and atomically,
    /// which is exactly the guarantee wanted here.
    static func attachments() -> [Attachment] { generated }

    private static let generated: [Attachment] = build()

    private static func build() -> [Attachment] {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let still = directory.appending(path: "demo-still.png")
        let loop = directory.appending(path: "demo-loop.gif")
        let clip = directory.appending(path: "demo-clip.mp4")

        writeStillIfNeeded(to: still)
        writeLoopIfNeeded(to: loop)
        if !FileManager.default.fileExists(atPath: clip.path(percentEncoded: false)) {
            Task { await writeClip(to: clip) }
        }

        return [
            attachment(
                id: 5_000_000_000_000_000_001,
                file: still,
                name: "wingcord-still.png",
                type: "image/png",
                size: stillSize,
                bytes: 1_482_016
            ),
            attachment(
                id: 5_000_000_000_000_000_002,
                file: loop,
                name: "wingcord-loop.gif",
                type: "image/gif",
                size: CGSize(width: loopSide, height: loopSide),
                bytes: 612_400
            ),
            attachment(
                id: 5_000_000_000_000_000_003,
                file: clip,
                name: "wingcord-clip.mp4",
                type: "video/mp4",
                size: clipSize,
                bytes: 2_104_888,
                duration: 3
            ),
        ]
    }

    /// The same picture again, hidden.
    ///
    /// A spoilered attachment is named `SPOILER_…` by the uploader and Discord
    /// carries no flag for it, so the fixture has to say it the same way — which
    /// is also the only way the reveal-then-open path is ever exercised.
    static func spoiler() -> Attachment? {
        guard var hidden = attachments().first else { return nil }
        hidden.id = AttachmentID(rawValue: 5_000_000_000_000_000_004)
        hidden.filename = "SPOILER_" + hidden.filename
        return hidden
    }

    private static func attachment(
        id: UInt64,
        file: URL,
        name: String,
        type: String,
        size: CGSize,
        bytes: Int,
        duration: Double? = nil
    ) -> Attachment {
        let string = file.absoluteString
        return Attachment(
            id: AttachmentID(rawValue: id),
            filename: name,
            url: string,
            proxyURL: string,
            contentType: type,
            size: bytes,
            width: Int(size.width),
            height: Int(size.height),
            description: "A generated fixture, so the viewer has something to view.",
            durationSeconds: duration
        )
    }

    // MARK: Drawing

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }

    /// A picture with detail at several scales, so zooming into it shows
    /// something rather than a larger blur — a flat gradient proves nothing
    /// about a decode ceiling.
    private static func writeStillIfNeeded(to file: URL) {
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        let width = Int(stillSize.width)
        let height = Int(stillSize.height)
        guard let context = context(width: width, height: height) else { return }

        context.setFillColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Concentric rings, then a fine grid over them. The rings read at fit;
        // the grid only resolves once the reader has zoomed in, which is the
        // point of drawing both.
        for step in stride(from: 0, to: 40, by: 1) {
            let fraction = Double(step) / 40
            context.setStrokeColor(
                red: 0.35 + fraction * 0.5,
                green: 0.2 + fraction * 0.3,
                blue: 0.75 - fraction * 0.35,
                alpha: 0.55
            )
            context.setLineWidth(3)
            let radius = Double(height) * (0.06 + fraction * 0.62)
            context.strokeEllipse(
                in: CGRect(
                    x: Double(width) / 2 - radius,
                    y: Double(height) / 2 - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.12)
        context.setLineWidth(1)
        for x in stride(from: 0, to: width, by: 24) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, to: height, by: 24) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        guard let image = context.makeImage() else { return }
        write(images: [image], delays: nil, to: file, type: .png)
    }

    /// A loop with enough frames that the scrubber has somewhere to go.
    private static func writeLoopIfNeeded(to file: URL) {
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        var frames: [CGImage] = []
        frames.reserveCapacity(loopFrames)
        for index in 0..<loopFrames {
            guard let context = context(width: loopSide, height: loopSide) else { continue }
            let phase = Double(index) / Double(loopFrames)
            context.setFillColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: loopSide, height: loopSide))
            let centre = CGPoint(x: Double(loopSide) / 2, y: Double(loopSide) / 2)
            context.setFillColor(
                red: 0.35 + phase * 0.5, green: 0.35, blue: 0.95 - phase * 0.4, alpha: 1
            )
            context.move(to: centre)
            context.addArc(
                center: centre,
                radius: Double(loopSide) * 0.4,
                startAngle: phase * 2 * .pi,
                endAngle: phase * 2 * .pi + 1.2,
                clockwise: false
            )
            context.closePath()
            context.fillPath()
            if let image = context.makeImage() { frames.append(image) }
        }
        guard frames.count > 1 else { return }
        write(images: frames, delays: Array(repeating: 1.0 / 12, count: frames.count), to: file, type: .gif)
    }

    private static func write(
        images: [CGImage],
        delays: [Double]?,
        to file: URL,
        type: UTType
    ) {
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, type.identifier as CFString, images.count, nil
        ) else { return }
        if type == .gif {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
            ] as CFDictionary)
        }
        for (index, image) in images.enumerated() {
            let properties: CFDictionary? = delays.map { delays in
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFUnclampedDelayTime: delays[index],
                        kCGImagePropertyGIFDelayTime: delays[index],
                    ],
                ] as CFDictionary
            }
            CGImageDestinationAddImage(destination, image, properties)
        }
        CGImageDestinationFinalize(destination)
    }

    // MARK: The clip

    /// Three seconds of H.264, encoded behind the caller.
    ///
    /// Written to a sibling path and moved into place at the end, so a launch
    /// interrupted halfway through leaves no half-file for the next one to find
    /// and trust.
    ///
    /// **The SDK 27 receiver API, not the adaptor.** `AVAssetWriterInput`'s
    /// `isReadyForMoreMediaData` spin loop is deprecated and was always a poll;
    /// `PixelBufferReceiver.append` suspends until the encoder wants the frame,
    /// which is the same thing said correctly.
    private static func writeClip(to file: URL) async {
        let staging = file.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        guard let writer = try? AVAssetWriter(outputURL: staging, fileType: .mp4) else { return }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(clipSize.width),
            AVVideoHeightKey: Int(clipSize.height),
        ])
        let receiver = writer.inputPixelBufferReceiver(
            for: input,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
                size: CVImageSize(width: Int(clipSize.width), height: Int(clipSize.height))
            )
        )
        do {
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            guard let pool = receiver.pixelBufferPool else { return }
            for index in 0..<clipFrames {
                var buffer = try pool.makeMutablePixelBuffer()
                draw(frame: index, into: &buffer)
                try await receiver.append(
                    CVReadOnlyPixelBuffer(consume buffer),
                    with: CMTime(value: CMTimeValue(index), timescale: 30)
                )
            }
            receiver.finish()
            await writer.finishWriting()
        } catch {
            DiagnosticLog.trace("demo", "clip encode failed: \(error)")
            try? FileManager.default.removeItem(at: staging)
            return
        }
        guard writer.status == .completed else {
            DiagnosticLog.trace("demo", "clip encode ended \(writer.status.rawValue)")
            try? FileManager.default.removeItem(at: staging)
            return
        }
        try? FileManager.default.moveItem(at: staging, to: file)
        DiagnosticLog.trace("demo", "clip written")
    }

    /// A bar sweeping left to right over a shifting ground: enough motion that a
    /// dropped frame is visible, and enough structure that a scrub lands
    /// somewhere recognisable.
    private static func draw(frame: Int, into buffer: inout CVMutablePixelBuffer) {
        buffer.accessUnsafeMutableRawPlaneBytes { planes in
            guard let plane = planes.first,
                  let base = plane.bytes.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: plane.properties.size.width,
                      height: plane.properties.size.height,
                      bitsPerComponent: 8,
                      bytesPerRow: plane.properties.bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                  )
            else { return }

            let phase = Double(frame) / Double(clipFrames)
            context.setFillColor(red: 0.05 + phase * 0.1, green: 0.05, blue: 0.12, alpha: 1)
            context.fill(CGRect(origin: .zero, size: clipSize))
            context.setFillColor(red: 0.4, green: 0.75, blue: 1, alpha: 1)
            context.fill(CGRect(
                x: phase * (clipSize.width - 120),
                y: clipSize.height * 0.25,
                width: 120,
                height: clipSize.height * 0.5
            ))
        }
    }
}
