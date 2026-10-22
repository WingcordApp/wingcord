import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
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
                bytes: 1_482_016,
                placeholder: stillPlaceholder
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

    /// A source file and a README, written once, so a text preview has
    /// something to show: highlighting and the language picker on the one,
    /// Render Markdown on the other.
    static func textFiles() -> [Attachment] { textGenerated }

    private static let textGenerated: [Attachment] = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ text: String, named name: String, id: UInt64) -> Attachment {
            let url = directory.appending(path: name)
            let data = Data(text.utf8)
            if (try? Data(contentsOf: url)) != data { try? data.write(to: url) }
            return Attachment(
                id: AttachmentID(rawValue: id),
                filename: name,
                url: url.absoluteString,
                proxyURL: url.absoluteString,
                contentType: "text/plain; charset=utf-8",
                size: data.count
            )
        }
        return [
            write(sourceSample, named: "TimelineLayout.swift", id: 5_000_000_000_000_000_011),
            write(markdownSample, named: "README.md", id: 5_000_000_000_000_000_012),
        ]
    }()

    private static let sourceSample = """
    import AppKit

    /// Lays out one row of the transcript.
    struct TimelineLayout {
        var width: CGFloat
        var lineSpacing: CGFloat = 2

        // Rows are measured once and cached by width.
        func height(of text: String, font: NSFont) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let bounds = attributed.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            return ceil(bounds.height) + lineSpacing * 2
        }
    }

    @MainActor
    final class TimelineCache {
        private var heights: [Int: CGFloat] = [:]
        static let shared = TimelineCache()

        func store(_ height: CGFloat, for id: Int) {
            guard height > 0 else { return }
            heights[id] = height
        }
    }

    let layout = TimelineLayout(width: 480)
    print("Height: \\(layout.height(of: "Hello", font: .systemFont(ofSize: 13)))")
    """

    private static let markdownSample = """
    # Wingcord

    A native **macOS** client for *Discord*, built with SwiftUI and AppKit.

    ## Features

    - Frosted bubbles over your own wallpaper
    - A glass sidebar with pages
      - Messages and Servers
    - Highlighted code, `inline code` too

    1. Download the app
    2. Sign in
    3. Pick a theme

    > Every rule in INVARIANTS.md cost something.

    ```swift
    let greeting = "Hello"
    print(greeting)
    ```

    | Surface | Material |
    | --- | --- |
    | Sidebar | Liquid Glass |
    | Bubbles | Standard material |

    ---

    Read more at [the docs](https://example.com/docs) or https://example.com.
    ![Screenshot](https://example.com/shot.png)
    """

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
        duration: Double? = nil,
        placeholder: String? = nil
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
            durationSeconds: duration,
            placeholder: placeholder
        )
    }

    /// The still's ThumbHash — Discord's `placeholder` — computed once from
    /// `demo-still.png` with the reference encoder, and checked by decoding it
    /// back through `MediaPlaceholder` (average colour 20,16,22 against the
    /// picture's 20,17,24). The spoiler's cover is drawn from it (D16); redo it
    /// if `writeStillIfNeeded` draws something else.
    private static let stillPlaceholder = "xQcCBIAIGFh3h4eHdXf4iIxweA=="

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
    private static func writeClip(to file: URL) async {
        await encode(to: file, size: clipSize, frames: clipFrames) { index, context in
            draw(frame: index, in: context)
        }
    }

    /// H.264 at 30 frames a second, each frame drawn by `draw`.
    ///
    /// Written to a sibling path and moved into place at the end, so a launch
    /// interrupted halfway through leaves no half-file for the next one to find
    /// and trust.
    ///
    /// **The SDK 27 receiver API, not the adaptor.** `AVAssetWriterInput`'s
    /// `isReadyForMoreMediaData` spin loop is deprecated and was always a poll;
    /// `PixelBufferReceiver.append` suspends until the encoder wants the frame,
    /// which is the same thing said correctly.
    static func encode(
        to file: URL, size: CGSize, frames: Int, fileType: AVFileType = .mp4, voice: URL? = nil,
        draw: (Int, CGContext) -> Void
    ) async {
        let staging = file.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        guard let writer = try? AVAssetWriter(outputURL: staging, fileType: fileType) else { return }
        // A sound read from `voice` and written beside the picture as AAC.
        var sound: SoundPipe?
        // One asset for the reader and its track: a track of another asset
        // object, even of the same file, is refused with an exception.
        let voiceAsset = voice.map { AVURLAsset(url: $0) }
        if let voiceAsset, let track = try? await voiceAsset.loadTracks(withMediaType: .audio).first,
           let reader = try? AVAssetReader(asset: voiceAsset)
        {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            let provider = reader.outputProvider(for: output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            sound = SoundPipe(reader: reader, provider: provider, receiver: writer.inputReceiver(for: input))
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let receiver = writer.inputPixelBufferReceiver(
            for: input,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
                size: CVImageSize(width: Int(size.width), height: Int(size.height))
            )
        )
        do {
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            guard let pool = receiver.pixelBufferPool else { return }
            let soundTask = sound.map { pipe in Task { try await pipe.run() } }
            defer { soundTask?.cancel() }
            for index in 0..<frames {
                var buffer = try pool.makeMutablePixelBuffer()
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
                    draw(index, context)
                }
                try await receiver.append(
                    CVReadOnlyPixelBuffer(consume buffer),
                    with: CMTime(value: CMTimeValue(index), timescale: 30)
                )
            }
            receiver.finish()
            try await soundTask?.value
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
        DiagnosticLog.trace("demo", "\(file.lastPathComponent) written")
    }

    /// A bar sweeping left to right over a shifting ground: enough motion that a
    /// dropped frame is visible, and enough structure that a scrub lands
    /// somewhere recognisable.
    private static func draw(frame: Int, in context: CGContext) {
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

    // MARK: A Discord clip

    static let gameClipSize = CGSize(width: 1280, height: 720)
    static let gameClipSeconds = 20.0

    /// A game's look: its sky, top to bottom, and its target.
    struct GameLook: Sendable {
        var skyTop: (Double, Double, Double)
        var skyBottom: (Double, Double, Double)
        var target: (Double, Double, Double)

        /// Dusk — Battlefield 6's in the demo.
        static let dusk = GameLook(skyTop: (0.16, 0.12, 0.32), skyBottom: (0.85, 0.45, 0.32), target: (0.75, 0.18, 0.2))
        /// Night over teal — the second game's.
        static let night = GameLook(skyTop: (0.03, 0.05, 0.12), skyBottom: (0.1, 0.45, 0.48), target: (0.95, 0.75, 0.2))
    }

    /// The moments the game clip's picture flashes at, in seconds — the same
    /// ones its timeline names (`DemoFixtures.populateSharedClip`), so a mark
    /// on the scrubber lands on the flash it stands for.
    static let gameClipKills: [Double] = [4.2, 6.8, 9.4]

    /// Twenty seconds of something game-shaped, with the time written on it so
    /// a mark can be checked against the picture: the file a Discord clip in
    /// the demo's transcript plays (docs/CLIPS-PRESENCE.md, Phase 4.6).
    static func gameClip() -> Attachment { gameClipGenerated }

    private static let gameClipGenerated: Attachment = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "demo-game-clip.mp4")
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            Task {
                await encode(to: file, size: gameClipSize, frames: Int(gameClipSeconds * 30)) { index, context in
                    drawGame(frame: index, in: context)
                }
            }
        }
        return attachment(
            id: 5_000_000_000_000_000_010,
            file: file,
            name: "Battlefield 6 2026-10-21 at 21.14.07.mp4",
            type: "video/mp4",
            size: gameClipSize,
            bytes: 9_842_112,
            duration: gameClipSeconds
        )
    }()

    /// The same twenty seconds from a teammate's side — the night look — for
    /// the shared clip's second point of view (Phase 7.3).
    static func gameClipPointOfView() -> Attachment { gameClipPOVGenerated }

    private static let gameClipPOVGenerated: Attachment = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "demo-game-clip-pov.mp4")
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            Task {
                await encode(to: file, size: gameClipSize, frames: Int(gameClipSeconds * 30)) { index, context in
                    drawGame(frame: index, in: context, look: .night)
                }
            }
        }
        return attachment(
            id: 5_000_000_000_000_000_011,
            file: file,
            name: "Battlefield 6 2026-10-21 at 21.14.08.mp4",
            type: "video/mp4",
            size: gameClipSize,
            bytes: 9_611_520,
            duration: gameClipSeconds
        )
    }()

    /// A sky over a ridge, a sight in the middle, a target crossing it that
    /// flashes white at each of `kills`, and the clock in the corner.
    static func drawGame(
        frame: Int, in context: CGContext, look: GameLook = .dusk, kills: [Double] = gameClipKills
    ) {
        let size = gameClipSize
        let seconds = Double(frame) / 30
        let sky = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(red: look.skyTop.0, green: look.skyTop.1, blue: look.skyTop.2, alpha: 1),
                CGColor(red: look.skyBottom.0, green: look.skyBottom.1, blue: look.skyBottom.2, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )
        if let sky {
            // Bitmap space: y up, so the sky's top is the context's top.
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.35), options: [])
        }
        context.setFillColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 1)
        let ridge = CGMutablePath()
        ridge.move(to: .zero)
        for step in 0...32 {
            let x = size.width * Double(step) / 32
            let y = size.height * (0.34 + 0.05 * sin(Double(step) * 0.9 + seconds * 0.2))
            ridge.addLine(to: CGPoint(x: x, y: y))
        }
        ridge.addLine(to: CGPoint(x: size.width, y: 0))
        ridge.closeSubpath()
        context.addPath(ridge)
        context.fillPath()

        // The target crosses once every four seconds.
        let lap = seconds.truncatingRemainder(dividingBy: 4) / 4
        let target = CGRect(x: lap * (size.width + 160) - 160, y: size.height * 0.42, width: 70, height: 110)
        let isFlash = kills.contains { seconds >= $0 && seconds < $0 + 0.25 }
        context.setFillColor(isFlash
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            : CGColor(red: look.target.0, green: look.target.1, blue: look.target.2, alpha: 1))
        context.fill(target)

        // The sight.
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        context.setStrokeColor(red: 0.6, green: 1, blue: 0.7, alpha: 0.9)
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: centre.x - 26, y: centre.y - 26, width: 52, height: 52))
        context.move(to: CGPoint(x: centre.x - 44, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x + 44, y: centre.y))
        context.move(to: CGPoint(x: centre.x, y: centre.y - 44))
        context.addLine(to: CGPoint(x: centre.x, y: centre.y + 44))
        context.strokePath()

        // The clock, bottom left.
        let label = String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 44, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 0.92),
        ]))
        context.textPosition = CGPoint(x: 36, y: 34)
        CTLineDraw(line, context)
    }

    // MARK: The library's recording and screenshots

    static let desktopSize = CGSize(width: 1440, height: 900)

    /// A desktop with a window whose text scrolls — what a recording of the
    /// screen looks like with the cursor left out, as the recorder leaves it
    /// (it travels in `cursor.json`).
    static func drawDesktop(frame: Int, in context: CGContext) {
        let size = desktopSize
        let seconds = Double(frame) / 30
        if let ground = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(red: 0.12, green: 0.2, blue: 0.42, alpha: 1),
                CGColor(red: 0.42, green: 0.28, blue: 0.55, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(ground, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        // A window, its bar, and lines of text moving up through it.
        let window = CGRect(x: 220, y: 140, width: 1000, height: 620)
        context.setFillColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        context.addPath(CGPath(roundedRect: window, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()
        context.setFillColor(red: 0.18, green: 0.18, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: window.minX, y: window.maxY - 52, width: window.width, height: 34))
        for (index, colour) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.8, 0.26)].enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fillEllipse(in: CGRect(x: window.minX + 22 + Double(index) * 22, y: window.maxY - 30, width: 13, height: 13))
        }
        context.saveGState()
        context.clip(to: window.insetBy(dx: 30, dy: 70).offsetBy(dx: 0, dy: -10))
        let scroll = seconds * 36
        for line in 0..<40 {
            let y = window.maxY - 90 - Double(line) * 34 + scroll
            let width = 260 + Double((line * 97) % 520)
            context.setFillColor(red: 0.85, green: 0.86, blue: 0.9, alpha: line % 5 == 0 ? 0.95 : 0.55)
            context.fill(CGRect(x: window.minX + 40, y: y, width: width, height: 12))
        }
        context.restoreGState()
    }

    /// A still of the game clip at `frame`, for a clips gallery's picture —
    /// written once beside the clip (docs/CLIPS-PRESENCE.md, Phase 7.5).
    static func gameClipPoster(frame: Int, look: GameLook = .dusk, named name: String = "dusk") -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "demo-game-clip-poster-\(frame)-\(name).png")
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            writeStill(to: file, size: gameClipSize, frame: frame) { index, context in
                drawGame(frame: index, in: context, look: look)
            }
        }
        return file
    }

    /// One frame of a scene, as a PNG — a screenshot for the library.
    static func writeStill(
        to file: URL, size: CGSize, frame: Int, draw: (Int, CGContext) -> Void
    ) {
        guard let context = context(width: Int(size.width), height: Int(size.height)) else { return }
        draw(frame, context)
        guard let image = context.makeImage() else { return }
        write(images: [image], delays: nil, to: file, type: .png)
    }

    // MARK: A voice for the recording

    /// What the demo recording's microphone says — enough for captions and
    /// voice clean-up to have something to work on.
    static let recordingWords = "Here's the new clips editor. Watch the zoom follow my clicks, "
        + "and these captions are written on this Mac from what I'm saying."

    /// A reader's sound joined to a writer's input, on a task of its own —
    /// the writer holds it back when it runs ahead of the picture.
    /// `@unchecked`: each object is touched by that one task only.
    final class SoundPipe: @unchecked Sendable {
        let reader: AVAssetReader
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.SampleBufferReceiver

        init(
            reader: AVAssetReader, provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
            receiver: AVAssetWriterInput.SampleBufferReceiver
        ) {
            self.reader = reader
            self.provider = provider
            self.receiver = receiver
        }

        func run() async throws {
            try reader.start()
            while let sample = try await provider.next() {
                try await receiver.append(sample)
            }
            receiver.finish()
        }
    }

    /// Words spoken by the system's own voice into a file. On the main
    /// actor: the synthesiser answers on the run loop it was made on.
    @MainActor
    static func speak(_ text: String, to url: URL) async -> Bool {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var file: AVAudioFile?
            var isDone = false
        }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let sink = Sink()
        try? FileManager.default.removeItem(at: url)
        let spoke: Bool = await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                sink.lock.lock()
                defer { sink.lock.unlock() }
                guard !sink.isDone, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    sink.isDone = true
                    let wrote = sink.file != nil
                    // Closed here, so the file is whole before anybody reads it.
                    sink.file?.close()
                    sink.file = nil
                    continuation.resume(returning: wrote)
                    return
                }
                if sink.file == nil {
                    sink.file = try? AVAudioFile(
                        forWriting: url, settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved
                    )
                }
                try? sink.file?.write(from: pcm)
            }
        }
        withExtendedLifetime(synthesizer) {}
        return spoke
    }

}
