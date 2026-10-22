import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import WingcordCore

// MARK: - One edit, as AVFoundation plays it
//
// docs/CLIPS-PRESENCE.md, Phase 5.2. The editor's preview and the export are
// the same graph: a composition with each kept stretch of the source laid
// end to end and stretched to its speed (sound and camera with it), the
// compositor's plan for the picture, and the sound's own time-pitch so a
// faster stretch does not chirp. The preview plays it in an `AVPlayerItem`;
// the export reads it back and encodes it.

public struct ClipRenderInput: @unchecked Sendable {
    public var source: URL
    /// A recording's camera file, and how much later than the screen it
    /// started.
    public var camera: URL?
    public var cameraOffset: Double
    /// The kept stretches; empty keeps the whole file.
    public var segments: [ClipSegment]
    /// The box kept, in the source's pixels, top-left origin; nil keeps it all.
    public var crop: CGRect?
    public var canvas: ClipCanvas
    public var zooms: [ZoomBlock]
    public var blurs: [BlurRegion]
    public var cursorLog: CursorLog?
    public var cursorStyle: CursorStyle
    public var cursorSprites: [CursorLog.Kind: CursorSprite]
    /// The bubble's centre and diameter in the canvas's 0…1 frame.
    public var cameraPlacement: (x: Double, y: Double, diameter: Double)?
    /// Which of the source's audio tracks are heard, by their order in the
    /// file; nil hears them all.
    public var audioTracks: [Int]?
    /// Tracks heard from another file instead — voice clean-up's results,
    /// by the source track they stand in for.
    public var replacedAudio: [Int: URL]
    public var overlays: [RenderedOverlay]
    /// The canvas's shorter side, in pixels; nil keeps the picture's own.
    public var shortSide: Int?
    /// Frames a second; nil follows the source, at most 60.
    public var framerate: Double?

    public init(
        source: URL, camera: URL? = nil, cameraOffset: Double = 0, segments: [ClipSegment] = [], crop: CGRect? = nil,
        canvas: ClipCanvas = .plain, zooms: [ZoomBlock] = [], blurs: [BlurRegion] = [], cursorLog: CursorLog? = nil,
        cursorStyle: CursorStyle = CursorStyle(), cursorSprites: [CursorLog.Kind: CursorSprite] = [:],
        cameraPlacement: (x: Double, y: Double, diameter: Double)? = nil, audioTracks: [Int]? = nil,
        replacedAudio: [Int: URL] = [:], overlays: [RenderedOverlay] = [], shortSide: Int? = nil, framerate: Double? = nil
    ) {
        self.source = source
        self.camera = camera
        self.cameraOffset = cameraOffset
        self.segments = segments
        self.crop = crop
        self.canvas = canvas
        self.zooms = zooms
        self.blurs = blurs
        self.cursorLog = cursorLog
        self.cursorStyle = cursorStyle
        self.cursorSprites = cursorSprites
        self.cameraPlacement = cameraPlacement
        self.audioTracks = audioTracks
        self.replacedAudio = replacedAudio
        self.overlays = overlays
        self.shortSide = shortSide
        self.framerate = framerate
    }
}

/// The built graph.
public struct ClipRenderGraph: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let videoTracks: [AVAssetTrack]
    public let audioTracks: [AVAssetTrack]
    public let renderSize: CGSize
    public let duration: Double
    public let framerate: Double
    /// The source's own height, for the budget.
    public let sourceSize: CGSize
    /// The shorter side asked for, kept for a canvas change.
    let shortSide: Int?
    let plan: ClipRenderPlan

    public enum Failure: Error, LocalizedError, Sendable {
        case noPicture
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noPicture: "There is no picture in that file."
            case .failed(let reason): "The clip could not be put together: \(reason)"
            }
        }
    }

    public static func build(_ input: ClipRenderInput) async throws -> ClipRenderGraph {
        let asset = AVURLAsset(url: input.source)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noPicture }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let nominal = Double(try await sourceVideo.load(.nominalFrameRate))
        let fileDuration = try await asset.load(.duration).seconds

        // The stretches, inside the file.
        let segments = (input.segments.isEmpty ? [ClipSegment(start: 0, end: fileDuration)] : input.segments)
            .compactMap { segment -> ClipSegment? in
                let start = min(max(0, segment.start), fileDuration)
                let end = min(max(start, segment.end), fileDuration)
                guard end - start >= 0.01 else { return nil }
                return ClipSegment(id: segment.id, start: start, end: end, speed: segment.speed)
            }
        guard !segments.isEmpty else { throw Failure.failed("nothing is kept") }
        let sequence = ClipSequence(segments: segments)

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.failed("no video track") }
        try lay(segments, of: sourceVideo, into: video, offset: 0, available: fileDuration)

        var cameraTrack: AVMutableCompositionTrack?
        if let cameraURL = input.camera, input.cameraPlacement != nil {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraSource = try? await cameraAsset.loadTracks(withMediaType: .video).first,
               let cameraDuration = try? await cameraAsset.load(.duration).seconds,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            {
                // The camera's own clock runs `cameraOffset` behind the screen's.
                try lay(segments, of: cameraSource, into: track, offset: input.cameraOffset, available: cameraDuration)
                cameraTrack = track
            }
        }

        var audioTracks: [AVMutableCompositionTrack] = []
        let heard = input.audioTracks.map(Set.init) ?? Set(sourceAudio.indices)
        for (index, track) in sourceAudio.enumerated() where heard.contains(index) {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            if let replacement = input.replacedAudio[index],
               let cleaned = try? await AVURLAsset(url: replacement).loadTracks(withMediaType: .audio).first
            {
                try lay(segments, of: cleaned, into: target, offset: 0, available: fileDuration)
            } else {
                try lay(segments, of: track, into: target, offset: 0, available: fileDuration)
            }
            audioTracks.append(target)
        }

        // The canvas's size.
        let crop = (input.crop ?? CGRect(origin: .zero, size: naturalSize)).intersection(CGRect(origin: .zero, size: naturalSize))
        let contentAspect = Double(crop.width / max(crop.height, 1))
        let layout = input.canvas.layout(contentAspect: contentAspect)
        let renderSize = Self.renderSize(canvasAspect: layout.canvasAspect, content: layout.content, crop: crop, shortSide: input.shortSide)
        let rate = min(60, max(1, input.framerate ?? (nominal > 0 ? nominal : 30)))

        let plan = ClipRenderPlan(
            screenTrack: video.trackID,
            cameraTrack: cameraTrack?.trackID,
            sequence: sequence,
            sourceSize: naturalSize,
            crop: crop,
            renderSize: renderSize,
            content: layout.content,
            canvas: input.canvas,
            zooms: input.zooms,
            blurs: input.blurs,
            cursor: input.cursorLog.map { log in
                (log, input.cursorStyle, input.cursorSprites, Self.pointScale(for: naturalSize))
            },
            camera: input.cameraPlacement.map { (CGFloat($0.x), CGFloat($0.y), CGFloat($0.diameter)) },
            overlays: input.overlays.map { (CIImage(cgImage: $0.image), $0.frame, $0.start, $0.end) }
        )
        let videoComposition = Self.videoComposition(plan: plan, duration: sequence.duration, framerate: rate)

        var audioMix: AVAudioMix?
        if !audioTracks.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.audioTimePitchAlgorithm = .spectral
                return parameters
            }
            audioMix = mix
        }
        return ClipRenderGraph(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            videoTracks: [video] + (cameraTrack.map { [$0] } ?? []),
            audioTracks: audioTracks,
            renderSize: renderSize,
            duration: sequence.duration,
            framerate: rate,
            sourceSize: naturalSize,
            shortSide: input.shortSide,
            plan: plan
        )
    }

    /// The canvas's size in pixels for `canvas` — what `replacing` sizes a
    /// new video composition to.
    public func renderSize(for canvas: ClipCanvas) -> CGSize {
        let layout = canvas.layout(contentAspect: Double(plan.crop.width / max(plan.crop.height, 1)))
        return Self.renderSize(canvasAspect: layout.canvasAspect, content: layout.content, crop: plan.crop, shortSide: shortSide)
    }

    /// The same graph with a new picture plan — what a drag in the editor
    /// changes, without rebuilding the composition.
    public func replacing(
        canvas: ClipCanvas? = nil, zooms: [ZoomBlock]? = nil, blurs: [BlurRegion]? = nil,
        cursorStyle: CursorStyle? = nil, cameraPlacement: (x: Double, y: Double, diameter: Double)?? = nil,
        overlays: [RenderedOverlay]? = nil
    ) -> AVVideoComposition {
        var plan = plan
        if let canvas {
            plan.canvas = canvas
            let layout = canvas.layout(contentAspect: Double(plan.crop.width / max(plan.crop.height, 1)))
            plan.content = layout.content
            plan.renderSize = renderSize(for: canvas)
        }
        if let zooms { plan.zooms = zooms }
        if let blurs { plan.blurs = blurs }
        if let cursorStyle, let cursor = plan.cursor { plan.cursor = (cursor.log, cursorStyle, cursor.sprites, cursor.pointScale) }
        if let cameraPlacement { plan.camera = cameraPlacement.map { (CGFloat($0.x), CGFloat($0.y), CGFloat($0.diameter)) } }
        if let overlays { plan.overlays = overlays.map { (CIImage(cgImage: $0.image), $0.frame, $0.start, $0.end) } }
        return Self.videoComposition(plan: plan, duration: duration, framerate: framerate)
    }

    /// One frame of the edit at `time`, drawn without a player — for a test,
    /// or a still.
    public func frame(at time: Double, screen: CGImage?, camera: CGImage? = nil) -> CIImage {
        ClipCompositor.compose(
            plan: plan, screen: screen.map { CIImage(cgImage: $0) }, camera: camera.map { CIImage(cgImage: $0) }, at: time
        )
    }

    // MARK: Building

    private static func videoComposition(plan: ClipRenderPlan, duration: Double, framerate: Double) -> AVVideoComposition {
        // A constant frame rate, never the source's own timing: a screen
        // recording has frames only when something changed, and a zoom easing
        // over a still screen still needs every frame it moves through.
        AVVideoComposition(configuration: .init(
            customVideoCompositorClass: ClipCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(framerate.rounded())),
            instructions: [ClipRenderInstruction(
                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)),
                plan: plan
            )],
            renderSize: plan.renderSize
        ))
    }

    /// Each stretch inserted end to end, then stretched to its speed.
    private static func lay(
        _ segments: [ClipSegment], of source: AVAssetTrack, into target: AVMutableCompositionTrack,
        offset: Double, available: Double
    ) throws {
        var cursor = CMTime.zero
        for segment in segments {
            let outputDuration = CMTime(seconds: segment.outputDuration, preferredTimescale: 600)
            // In the source track's own clock — the camera's runs `offset`
            // behind the screen's.
            let from = segment.start - offset
            let to = segment.end - offset
            let start = max(0, from)
            let end = min(available, to)
            if end - start > 0.01 {
                let lead = CMTime(seconds: (start - from) / segment.speed, preferredTimescale: 600)
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600)
                )
                let at = cursor + lead
                try target.insertTimeRange(range, of: source, at: at)
                if segment.speed != 1 {
                    target.scaleTimeRange(
                        CMTimeRange(start: at, duration: range.duration),
                        toDuration: CMTime(seconds: (end - start) / segment.speed, preferredTimescale: 600)
                    )
                }
            }
            cursor = cursor + outputDuration
        }
    }

    /// The canvas in pixels: even, at the asked shorter side or the
    /// picture's own, never past 4K's long side.
    static func renderSize(canvasAspect: Double, content: CGRect, crop: CGRect, shortSide: Int?) -> CGSize {
        var width: Double
        var height: Double
        if let shortSide {
            if canvasAspect >= 1 {
                height = Double(shortSide)
                width = height * canvasAspect
            } else {
                width = Double(shortSide)
                height = width / canvasAspect
            }
        } else {
            // The picture keeps its pixels; the canvas grows round it.
            height = Double(crop.height) / Double(max(content.height, 0.05))
            width = height * canvasAspect
        }
        let longest = max(width, height)
        if longest > 3_840 {
            width *= 3_840 / longest
            height *= 3_840 / longest
        }
        func even(_ value: Double) -> CGFloat { CGFloat(max(2, Int(value.rounded()) / 2 * 2)) }
        return CGSize(width: even(width), height: even(height))
    }

    /// Source pixels per point: a Retina capture is twice the points it shows.
    static func pointScale(for size: CGSize) -> CGFloat {
        max(size.width, size.height) >= 2_400 ? 2 : 1
    }
}
