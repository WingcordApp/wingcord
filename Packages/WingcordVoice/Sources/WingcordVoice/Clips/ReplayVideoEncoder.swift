import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

// MARK: - The replay buffer's encoder
//
// docs/CLIPS-PRESENCE.md, D10 / Phase 0.4: **hardware HEVC**, realtime, no
// reordering, a keyframe a second. Measured there at 1080p60 on synthetic
// worst-case frames: ~1.5 % CPU, 11 ms per frame, and a two-minute ring of
// 180–220 MB. H.264 is the fallback only — it ignored its data-rate ceiling
// on hard content (58 Mbps against a 12 Mbps target), which in a ring is
// memory nobody budgeted.
//
// Unlike the Go Live encoder this one is never seen live: no viewer waits on
// it, so it keeps the encoder's own rate control and its main profile, and
// what it is tuned for is a picture that holds up in a clip.

public final class ReplayVideoEncoder: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    public struct Configuration: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var framerate: Int
        /// Bits per second the encoder aims at.
        public var bitrate: Int

        public init(width: Int, height: Int, framerate: Int, bitrate: Int) {
            self.width = width
            self.height = height
            self.framerate = framerate
            self.bitrate = bitrate
        }

        /// What a clip of this size and rate is encoded at: Discord's 1080p30
        /// default at 8 Mbps, scaled by pixels and frame rate — HEVC holds a
        /// game well there, and two minutes of it is ~120 MB.
        public static func bitrate(width: Int, height: Int, framerate: Int) -> Int {
            let pixels = Double(width * height) / Double(1_920 * 1_080)
            let motion = framerate > 30 ? 1.5 : 1
            return Int((8_000_000 * pixels * motion).rounded())
        }
    }

    public enum Failure: Error, Sendable {
        case session(OSStatus)
    }

    public let configuration: Configuration
    private let ring: ReplayVideoRing
    private let lock = NSLock()
    private var session: VTCompressionSession?
    /// What the session actually encodes, for the trace.
    public private(set) var codec: CMVideoCodecType = kCMVideoCodecType_HEVC

    public init(configuration: Configuration, ring: ReplayVideoRing) {
        self.configuration = configuration
        self.ring = ring
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { return }
        do {
            session = try Self.makeSession(configuration, codec: kCMVideoCodecType_HEVC)
            codec = kCMVideoCodecType_HEVC
        } catch {
            Self.log.warning("clips: no hardware HEVC (\(error.localizedDescription, privacy: .public)); H.264")
            session = try Self.makeSession(configuration, codec: kCMVideoCodecType_H264)
            codec = kCMVideoCodecType_H264
        }
    }

    public func stop() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// Encodes one picture into the ring. Runs on the capture's queue; the
    /// sample lands from VideoToolbox's own.
    ///
    /// - Parameter forceKeyframe: for the still picture offered again when
    ///   the window has not changed for a second — a ring of one keyframe and
    ///   nothing after it is a clip that can only start at that keyframe.
    public func encode(_ pixels: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool = false) {
        lock.lock()
        let session = self.session
        lock.unlock()
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        let ring = self.ring
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: time,
            duration: CMTime(value: 1, timescale: CMTimeScale(configuration.framerate)),
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample else { return }
            ring.append(sample)
        }
    }

    private static func makeSession(_ configuration: Configuration, codec: CMVideoCodecType) throws
        -> VTCompressionSession
    {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width), height: Int32(configuration.height),
            codecType: codec, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made
        )
        guard status == noErr, let session = made else { throw Failure.session(status) }

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as Any)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as Any)
        set(
            kVTCompressionPropertyKey_ProfileLevel,
            codec == kCMVideoCodecType_HEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        )
        // **A keyframe a second** is the grain of a clip's start: a save
        // begins at the keyframe at or before "N seconds ago", so the clip is
        // at most a second longer than asked.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.framerate)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1.0)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framerate)
        set(kVTCompressionPropertyKey_AverageBitRate, configuration.bitrate)
        // A ceiling at one and a half times the average over a second, as the
        // probe ran: a scene cut may spend more, a whole clip may not.
        set(kVTCompressionPropertyKey_DataRateLimits, [configuration.bitrate * 3 / 16, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}
