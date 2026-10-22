import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Testing
import WingcordCore
@testable import WingcordVoice

/// Editor v2's renderer (docs/CLIPS-PRESENCE.md, Phase 5.2): the graph that
/// plays in the editor and writes the export — cuts and speed, the canvas,
/// the zoom, the cursor, a GIF.
struct ClipRenderTests {

    typealias RGB = (r: Int, g: Int, b: Int)

    /// A silent H.264 file whose every frame is drawn by `paint` for its time.
    private static func video(seconds: Double, size: CGSize, paint: @escaping (Double, CGContext) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("render-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
            size: CVImageSize(width: Int(size.width), height: Int(size.height))
        ))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(receiver.pixelBufferPool)
        for index in 0..<Int(seconds * 30) {
            var buffer = try pool.makeMutablePixelBuffer()
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first, let base = plane.bytes.baseAddress,
                      let context = CGContext(
                          data: base, width: plane.properties.size.width, height: plane.properties.size.height,
                          bitsPerComponent: 8, bytesPerRow: plane.properties.bytesPerRow,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      )
                else { return }
                paint(Double(index) / 30, context)
            }
            try await receiver.append(CVReadOnlyPixelBuffer(consume buffer), with: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        receiver.finish()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private static func image(_ size: CGSize, paint: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        paint(context)
        return try #require(context.makeImage())
    }

    /// The colour at (x, y) from the top left of a rendered picture.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> RGB {
        let probe = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        probe.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(probe.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    /// Within a colour-managed draw of a pure colour: Core Image's working
    /// space moves sRGB's primaries by a few dozen levels (red reads 255/38/0).
    private static func near(_ color: RGB, _ r: Int, _ g: Int, _ b: Int, by tolerance: Int = 70) -> Bool {
        abs(color.r - r) <= tolerance && abs(color.g - g) <= tolerance && abs(color.b - b) <= tolerance
    }

    @Test("The canvas grows round the picture's own pixels, or takes the asked short side, evenly")
    func renderSize() {
        let crop = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let plain = ClipCanvas.plain.layout(contentAspect: 16.0 / 9.0)
        #expect(ClipRenderGraph.renderSize(canvasAspect: plain.canvasAspect, content: plain.content, crop: crop, shortSide: nil)
            == CGSize(width: 1_920, height: 1_080))
        let portrait = ClipCanvas(aspect: .portrait).layout(contentAspect: 16.0 / 9.0)
        let tall = ClipRenderGraph.renderSize(canvasAspect: portrait.canvasAspect, content: portrait.content, crop: crop, shortSide: 1_080)
        #expect(tall.width == 1_080 && tall.height == 1_920)
        let huge = ClipRenderGraph.renderSize(canvasAspect: 16.0 / 9.0, content: plain.content, crop: CGRect(x: 0, y: 0, width: 7_680, height: 4_320), shortSide: nil)
        #expect(huge.width == 3_840, "never past 4K")
    }

    @Test("One frame: the picture on its canvas, zoomed where asked, the cursor drawn again on it")
    func composesFrame() async throws {
        let size = CGSize(width: 320, height: 180)
        let source = try await Self.video(seconds: 2, size: size) { _, context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        // Left half red, right half blue.
        let screen = try Self.image(size) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        }
        let sprite = try Self.image(CGSize(width: 8, height: 8)) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var log = CursorLog()
        log.samples = [.init(t: 0, x: 0.25, y: 0.5, kind: .arrow), .init(t: 2, x: 0.25, y: 0.5, kind: .arrow)]
        let graph = try await ClipRenderGraph.build(ClipRenderInput(
            source: source,
            canvas: ClipCanvas(background: .solid(0x00_FF_00), padding: 0.1),
            zooms: [ZoomBlock(start: 0, end: 1, scale: 2, x: 0.25, y: 0.5)],
            cursorLog: log,
            cursorStyle: CursorStyle(size: 1, smoothing: 0, showsClicks: false),
            cursorSprites: [.arrow: CursorSprite(image: sprite, hotspot: .zero, pointSize: CGSize(width: 8, height: 8))]
        ))
        let context = CIContext()
        func render(at time: Double) throws -> CGImage {
            let frame = graph.frame(at: time, screen: screen)
            return try #require(context.createCGImage(frame, from: CGRect(origin: .zero, size: graph.renderSize)))
        }
        // 18 px of padding (a tenth of the picture's height) all round.
        #expect(graph.renderSize == CGSize(width: 356, height: 216), "the picture's pixels, padded round")

        let zoomed = try render(at: 0.5)
        #expect(Self.near(try Self.pixel(zoomed, 2, 2), 0, 255, 0), "the background in the padding")
        #expect(Self.near(try Self.pixel(zoomed, 70, 108), 255, 0, 0), "zoomed onto the red half")
        #expect(Self.near(try Self.pixel(zoomed, 310, 108), 255, 0, 0), "the blue half is out of the zoom")
        // The tip at source (80, 90) lands at (178, 108); its 8-pixel square,
        // zoomed twice, runs 16 pixels right and down from there.
        #expect(Self.near(try Self.pixel(zoomed, 186, 116), 255, 0, 255), "the cursor drawn where it was, zoomed with the picture")
        #expect(!Self.near(try Self.pixel(zoomed, 170, 100), 255, 0, 255), "and nowhere before its tip")

        let whole = try render(at: 1.6)
        #expect(Self.near(try Self.pixel(whole, 300, 108), 0, 0, 255), "out of the zoom, both halves show")
    }

    @Test("An export plays its stretches back to back, each at its speed")
    func exportsSequence() async throws {
        let size = CGSize(width: 160, height: 90)
        // A colour a second: red, green, blue, yellow.
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        let source = try await Self.video(seconds: 4, size: size) { time, context in
            let colour = colours[min(3, Int(time))]
            context.setFillColor(CGColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sequence-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await ClipExporter.export(.init(
            input: ClipRenderInput(
                source: source,
                segments: [ClipSegment(start: 0, end: 1), ClipSegment(start: 2, end: 4, speed: 2)],
                framerate: 30
            ),
            destination: destination
        ))
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.15, "1 s, then 2 s at 2×: \(duration)")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func centre(at seconds: Double) async throws -> RGB {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            return try Self.pixel(image, image.width / 2, image.height / 2)
        }
        #expect(Self.near(try await centre(at: 0.5), 255, 0, 0), "the first stretch")
        #expect(Self.near(try await centre(at: 1.6), 255, 255, 0), "source 3.2 s — the fourth second — after the cut")
    }

    @Test("A GIF: few frames, small, looping")
    func exportsGIF() async throws {
        let size = CGSize(width: 320, height: 180)
        let source = try await Self.video(seconds: 1, size: size) { time, context in
            context.setFillColor(CGColor(red: time, green: 0, blue: 1 - time, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try await ClipExporter.export(.init(
            input: ClipRenderInput(source: source, shortSide: 120), format: .gif, destination: destination
        ))
        let image = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetType(image) as String? == "com.compuserve.gif")
        let frames = CGImageSourceGetCount(image)
        #expect(frames >= 12 && frames <= 16, "15 a second: \(frames)")
        let first = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(first.height == 120)
    }
}

/// Voice clean-up (Phase 5.5): Apple's voice isolation, offline.
struct VoiceCleanUpTests {

    @Test("A track runs through the voice model into a file as long as it")
    func cleansUp() async throws {
        let rate = 48_000.0
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).caf")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        // Two seconds of a hummed tone over hiss.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        var noise = SystemRandomNumberGenerator()
        for index in 0..<Int(buffer.frameLength) {
            let tone = sin(2 * Double.pi * 180 * Double(index) / rate) * 0.3
            let hiss = Double.random(in: -0.08...0.08, using: &noise)
            channel[index] = Float(tone + hiss)
        }
        let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)

        try await VoiceCleanUp.process(source: source, track: 0, to: destination)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(duration - 2) < 0.2, "as long as the track: \(duration)")
        let tracks = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }
}
