import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import WingcordCore

@testable import WingcordVoice

// MARK: - The replay buffer, end to end
//
// docs/CLIPS-PRESENCE.md, Phase 3.1–3.2. Real pictures through the real
// hardware encoder into the real ring, real Opus for the game and for a voice,
// a soundboard sound — then the real writer, and the file read back with
// AVFoundation: how long it is, which tracks it has, which one plays.

@Suite("Clip engine", .serialized)
struct ClipEngineTests {

    // MARK: The ring

    private func fakeFrame(
        _ ring: ReplayVideoRing, at seconds: Double, keyframe: Bool, bytes: Int = 1_000, fill: UInt8 = 0
    ) throws {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC, width: 64, height: 64,
            extensions: nil, formatDescriptionOut: &description
        )
        let format = try #require(description)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        ring.append(
            Data(repeating: fill, count: bytes),
            format: FormatBox(formatDescription: format), presentation: time, decode: time,
            duration: CMTime(value: 20, timescale: 600), isKeyframe: keyframe
        )
    }

    @Test("The ring lets go a whole group at a time, and always starts on a keyframe")
    func ringKeepsWholeGroups() throws {
        let ring = ReplayVideoRing(window: 4, memoryBudget: .max, spillDirectory: nil)
        for index in 0..<300 {
            try fakeFrame(ring, at: 1_000 + Double(index) / 30, keyframe: index % 30 == 0)
        }
        let kept = ring.frames(lasting: 100)
        #expect(kept.first?.isKeyframe == true)
        // Ten seconds in, the window is four: the newest keyframe at least four
        // seconds old is where it starts.
        #expect(ring.duration >= 4 && ring.duration < 5)
        // A clip of two seconds starts at the keyframe at or before two
        // seconds ago.
        let clip = ring.frames(lasting: 2)
        let newest = try #require(clip.last).presentation.seconds
        let start = try #require(clip.first)
        #expect(start.isKeyframe)
        #expect(newest - start.presentation.seconds >= 2)
        #expect(newest - start.presentation.seconds < 3)
    }

    @Test("Past the budget the oldest go to disk, and come back byte for byte")
    func spillsPastBudget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wingcord-spill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ring = ReplayVideoRing(window: 60, memoryBudget: 50_000, spillDirectory: directory)
        for index in 0..<240 {
            try fakeFrame(
                ring, at: 2_000 + Double(index) / 30, keyframe: index % 30 == 0, bytes: 2_000,
                fill: UInt8(truncatingIfNeeded: index)
            )
        }
        // The spill runs off the encoder's thread; give it a moment.
        for _ in 0..<50 where ring.memoryBytes > 50_000 { Thread.sleep(forTimeInterval: 0.02) }
        #expect(ring.memoryBytes <= 50_000)
        let kept = ring.frames(lasting: 60)
        #expect(kept.count == 240)
        for (index, frame) in kept.enumerated() {
            let bytes = try #require(ring.bytes(of: frame))
            #expect(bytes.count == 2_000)
            #expect(bytes.allSatisfy { $0 == UInt8(truncatingIfNeeded: index) })
        }
        #expect(kept.contains { if case .spilled = $0.storage { true } else { false } })
    }

    // MARK: A whole clip

    /// A frame with something on it, a different shade each time.
    private static func picture(_ index: Int, width: Int = 320, height: Int = 180) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * stride + column * 4
                base[offset] = UInt8(truncatingIfNeeded: column + index * 4)
                base[offset + 1] = UInt8(truncatingIfNeeded: row + index * 2)
                base[offset + 2] = UInt8(truncatingIfNeeded: index * 8)
                base[offset + 3] = 0xFF
            }
        }
        return pixels
    }

    /// `seconds` of a tone as 20 ms Opus frames stamped from `start`.
    private static func tone(_ frequency: Double, from start: Double, seconds: Double, signal: OpusEncoder.Signal) throws
        -> [TimedAudioFrame]
    {
        let encoder = try OpusEncoder(bitrate: 96_000, signal: signal)
        var scratch = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var frames: [TimedAudioFrame] = []
        let width = Int(OpusFormat.frameSize)
        let channels = Int(signal.channels)
        for index in 0..<Int(seconds / 0.02) {
            var pcm = [Int16](repeating: 0, count: width * channels)
            for sample in 0..<width {
                let t = Double(index * width + sample) / 48_000
                let value = Int16(sin(2 * .pi * frequency * t) * 12_000)
                for channel in 0..<channels { pcm[sample * channels + channel] = value }
            }
            let length = try pcm.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!, into: &scratch) }
            frames.append(TimedAudioFrame(time: start + Double(index) * 0.02, payload: .opus(Array(scratch[0..<length]))))
        }
        return frames
    }

    @Test("A clip: the picture from a keyframe, the mix first and enabled, one stem per source")
    func writesClip() async throws {
        let ring = ReplayVideoRing(window: 10, memoryBudget: .max, spillDirectory: nil)
        let encoder = ReplayVideoEncoder(
            configuration: .init(width: 320, height: 180, framerate: 30, bitrate: 1_000_000), ring: ring
        )
        try encoder.start()
        let origin = 5_000.0
        for index in 0..<(6 * 30) {
            encoder.encode(try Self.picture(index), at: CMTime(seconds: origin + Double(index) / 30, preferredTimescale: 90_000))
        }
        encoder.stop()

        let game = TimedAudioTrack(frames: try Self.tone(440, from: origin, seconds: 6, signal: .soundshare))
        let tap = ClipAudioTap()
        tap.setPlan(.init(window: 10, voices: [7], keepsMicrophone: true, keepsSoundboard: true))
        for frame in try Self.tone(220, from: origin + 3, seconds: 2, signal: .voice) { tap.noteVoice(7, frame) }
        // Somebody whose client does not allow it is never kept.
        for frame in try Self.tone(330, from: origin + 3, seconds: 2, signal: .voice) { tap.noteVoice(8, frame) }
        tap.noteSoundboard([Float](repeating: 0.25, count: 48_000), volume: 1, at: origin + 4)
        tap.noteSpeaking(7, flags: 1, at: origin + 3)
        tap.noteSpeaking(7, flags: 0, at: origin + 5)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ClipWriter.write(.init(
            url: url, length: 4, video: ring, gameSound: game, call: tap.snapshot(), selfUserID: 1,
            names: [7: "Kim"], gameName: "Minecraft"
        ))

        #expect(result.duration >= 4 && result.duration < 5.1)
        #expect(result.tracks.map(\.role) == [.mix, .game, .voice(userID: 7), .soundboard])
        #expect(result.tracks.map(\.title) == ["Everything", "Minecraft", "Kim", "Soundboard"])
        #expect(result.voices == [7])

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 4)
        let enabled = try await audioTracks.asyncMap { try await $0.load(.isEnabled) }
        #expect(enabled == [true, false, false, false])
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - result.duration) < 0.15)
        let codec = try await videoTracks[0].load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_HEVC)

        // Kept to look at with WINGCORD_RENDER_DIR set.
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            let kept = URL(fileURLWithPath: directory).appendingPathComponent("engine-clip.mp4")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: url, to: kept)
        }
    }

    @Test("A Go Live stream's own H.264 is clipped as it was sent, with the stream's sound")
    func clipsAStream() async throws {
        let ring = ReplayVideoRing(window: 10, memoryBudget: .max, spillDirectory: nil)
        let encoder = H264Encoder(configuration: .init(width: 320, height: 180, framerate: 30, bitrate: 800_000))
        encoder.onSample = { ring.append($0) }
        try encoder.start()
        let origin = 8_000.0
        for index in 0..<(5 * 30) {
            encoder.encode(
                try Self.picture(index), at: CMTime(seconds: origin + Double(index) / 30, preferredTimescale: 90_000),
                forceKeyframe: false
            )
        }
        // Completes every frame in flight, as the stream's own end does.
        encoder.teardown()
        let sound = TimedAudioBuffer(window: 10)
        for frame in try Self.tone(440, from: origin, seconds: 5, signal: .soundshare) { sound.append(frame) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ClipWriter.write(.init(
            url: url, length: 2, video: ring, gameSound: sound.track, call: nil, selfUserID: nil,
            names: [:], gameName: "Stream"
        ))
        // The stream's keyframes are two seconds apart: a clip of two starts
        // at the one at or before that.
        #expect(result.duration >= 2 && result.duration < 4.1)
        #expect(result.tracks.map(\.role) == [.mix, .game])
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let codec = try await videoTracks.first?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_H264)
    }

    @Test("An edited export: trimmed, cut to 9:16, an overlay, one mixed sound, under the size it was given")
    func exportsEdited() async throws {
        // A five-second clip with a game track and a voice, as a save makes.
        let ring = ReplayVideoRing(window: 10, memoryBudget: .max, spillDirectory: nil)
        let encoder = ReplayVideoEncoder(
            configuration: .init(width: 640, height: 360, framerate: 30, bitrate: 2_000_000), ring: ring
        )
        try encoder.start()
        let origin = 9_000.0
        for index in 0..<(6 * 30) {
            encoder.encode(try Self.picture(index, width: 640, height: 360),
                           at: CMTime(seconds: origin + Double(index) / 30, preferredTimescale: 90_000))
        }
        encoder.stop()
        let tap = ClipAudioTap()
        tap.setPlan(.init(window: 10, voices: [7], keepsMicrophone: false, keepsSoundboard: false))
        for frame in try Self.tone(220, from: origin + 1, seconds: 3, signal: .voice) { tap.noteVoice(7, frame) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try await ClipWriter.write(.init(
            url: source, length: 5, video: ring,
            gameSound: TimedAudioTrack(frames: try Self.tone(440, from: origin, seconds: 6, signal: .soundshare)),
            call: tap.snapshot(), selfUserID: nil, names: [7: "Kim"], gameName: "Test"
        ))

        // A red square for the overlay.
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let square = try #require(context.makeImage())

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let crop = CGRect(x: 220, y: 0, width: 202, height: 360)   // 9:16 out of 640×360
        let limit = 2_000_000
        _ = try await ClipExporter.export(.init(
            source: source, range: 1...4, crop: crop,
            audioTracks: [1, 2],   // the stems, not the mix: game and Sam
            // On the source's clock: 1…3 s of the file is 0…2 s of the export.
            overlays: [RenderedOverlay(image: square, frame: CGRect(x: 0.05, y: 0.03, width: 0.2, height: 0.11), start: 1, end: 3)],
            maxHeight: 1_080, maxBytes: limit, destination: destination
        ))

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.15)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size.height > size.width, "portrait")
        #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)
        let codec = try await video.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_H264)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "one mixed sound")
        let bytes = try #require(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(bytes <= limit)

        // The overlay is in the picture for its stretch: the top-left corner
        // is red at the start and not at the end.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func corner(at seconds: Double) async throws -> (r: Int, g: Int, b: Int) {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let probe = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            probe.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(probe.data).assumingMemoryBound(to: UInt8.self)
            // Row 25 from the top, column 25: inside the square.
            let offset = (25 * image.width + 25) * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }
        let early = try await corner(at: 0.5)
        let late = try await corner(at: 2.6)
        #expect(early.r > 180 && early.g < 80 && early.b < 80, "red while the overlay shows: \(early)")
        #expect(!(late.r > 180 && late.g < 80 && late.b < 80), "gone after its stretch: \(late)")

        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            let kept = URL(fileURLWithPath: directory).appendingPathComponent("engine-export.mp4")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: destination, to: kept)
        }
    }

    @Test("Fitting a clip under a limit lowers the bitrate, then the picture, then gives up")
    func budget() {
        let roomy = ClipExporter.budget(duration: 30, maxBytes: 500_000_000, sourceHeight: 1_080, maxHeight: 1_080, framerate: 60)
        #expect(roomy?.height == 1_080 && roomy?.videoBitrate == 12_000_000)
        let tight = ClipExporter.budget(duration: 30, maxBytes: 10 * 1_024 * 1_024, sourceHeight: 1_080, maxHeight: 1_080, framerate: 60)
        #expect(tight?.height == 1_080 || tight?.height == 720)
        #expect((tight?.videoBitrate ?? 0) + (tight?.audioBitrate ?? 0) <= Int(10.0 * 1_024 * 1_024 * 8 / 30))
        let squeezed = ClipExporter.budget(duration: 120, maxBytes: 10 * 1_024 * 1_024, sourceHeight: 1_080, maxHeight: 1_080, framerate: 60)
        #expect(squeezed?.height == 480)
        #expect(ClipExporter.budget(duration: 600, maxBytes: 10 * 1_024 * 1_024, sourceHeight: 1_080, maxHeight: 1_080, framerate: 60) == nil)
    }

    @Test("The tap keeps who spoke before the window, as Discord's timeline needs")
    func tapCarriesSpeaking() {
        let tap = ClipAudioTap()
        tap.setPlan(.init(window: 5, keepsMicrophone: false, keepsSoundboard: false))
        tap.noteSpeaking(1, flags: 1, at: 100)
        tap.noteSpeaking(2, flags: 1, at: 101)
        tap.noteSpeaking(2, flags: 0, at: 102)
        tap.noteSpeaking(3, flags: 1, at: 110)
        let speaking = tap.snapshot().speaking
        // 1 and 2 fell out of the window; their last state is carried.
        let changes = speaking.map { ClipTimeline.SpeakingChange(time: $0.time, userID: $0.userID, flags: $0.flags) }
        let events = ClipTimeline.events(start: 108, end: 115, speaking: changes)
        #expect(events == [
            .init(timestampMS: 0, event: .speaking(userID: 1, flags: 1)),
            .init(timestampMS: 2_000, event: .speaking(userID: 3, flags: 1)),
        ])
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
