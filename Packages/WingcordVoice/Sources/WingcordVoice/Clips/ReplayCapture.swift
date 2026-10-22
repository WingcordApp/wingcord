import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

// MARK: - Keeping the last minutes of a game
//
// docs/CLIPS-PRESENCE.md, D10 — Discord's `DECOUPLED` clip source: the game's
// own window and its own sound, captured while it is in front and kept for the
// length a clip can be (30 s, 1 or 2 minutes, Discord's three). It replaces
// `SCClipBufferingOutput`, whose ceiling is fifteen seconds.
//
//   * The picture goes through the hardware HEVC encoder into a
//     `ReplayVideoRing` — compressed, a group of pictures at a time.
//   * The sound is gathered into 20 ms frames and kept as Opus, the same
//     shape the call's voices are kept in, so a save decodes everything one way.
//   * **A window that does not change still gets a keyframe a second** — the
//     last picture again — or a minute of a paused game would be one keyframe
//     a clip could only start at.
//   * Never this app's own sound: `excludesCurrentProcessAudio`, so the call
//     reaches a clip only through the voice tap, track by track, under
//     Discord's consent rules.

public final class ReplayCapture: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    public struct Settings: Sendable, Equatable {
        /// The tallest the picture is kept at; a bigger window is scaled down.
        public var maxHeight: Int
        public var framerate: Int
        /// Seconds a clip lasts — the ring keeps a little more.
        public var length: Double
        public var capturesAudio: Bool
        /// Bytes of picture held in memory before the oldest go to disk.
        public var memoryBudget: Int

        public init(maxHeight: Int, framerate: Int, length: Double, capturesAudio: Bool, memoryBudget: Int) {
            self.maxHeight = maxHeight
            self.framerate = framerate
            self.length = length
            self.capturesAudio = capturesAudio
            self.memoryBudget = memoryBudget
        }

        /// Seconds the rings keep: the clip and the second before its first
        /// keyframe, and a little for a save that lands late.
        var window: Double { length + 3 }
    }

    public enum Failure: Error, Sendable {
        /// The process has no window on screen worth capturing.
        case noWindow
        case nothingToCapture
    }

    public let video: ReplayVideoRing
    private let spillDirectory: URL?
    private let queue = DispatchQueue(label: "dev.wingcord.clips.capture", qos: .userInitiated)

    private struct Control: @unchecked Sendable {
        var stream: SCStream?
        var encoder: ReplayVideoEncoder?
        var settings: Settings
    }

    private let control: Mutex<Control>
    private let sound = Mutex(TimedAudioTrack())

    // Touched only from `queue`.
    private var lastPicture: CVPixelBuffer?
    private var lastEncoded: Double = 0
    private var stillTimer: DispatchSourceTimer?
    private var soundEncoder: OpusEncoder?
    private var soundFrame = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
    private var soundFilled = 0
    private var soundFrameStart: Double = 0
    private var soundScratch = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
    private let soundBuffers = AudioBufferList.allocate(maximumBuffers: 2)

    public init(settings: Settings, spillDirectory: URL?) {
        control = Mutex(Control(settings: settings))
        self.spillDirectory = spillDirectory
        video = ReplayVideoRing(window: settings.window, memoryBudget: settings.memoryBudget, spillDirectory: spillDirectory)
        super.init()
    }

    deinit { free(soundBuffers.unsafeMutablePointer) }

    public var settings: Settings { control.withLock { $0.settings } }
    public var isRunning: Bool { control.withLock { $0.stream != nil } }

    /// The game's sound kept so far.
    public func gameSound() -> TimedAudioTrack { sound.withLock { $0 } }

    /// What clips are kept for from now on. A longer length keeps more from
    /// here; what was already let go is not coming back.
    public func setLength(_ length: Double) {
        control.withLock { $0.settings.length = length }
        video.setWindow(length + 3)
    }

    // MARK: Running

    /// Starts keeping the biggest window `pid` has on screen, and its sound.
    ///
    /// **Asking for the content IS the permission check.** There is no
    /// authorisation-status API for screen capture the way there is for the
    /// camera, so a throw from it means "send them to System Settings" rather
    /// than "something went wrong" — the same fact `ScreenShareCapture`
    /// documents.
    ///
    /// - Parameter fresh: forget what was kept before — a different game.
    public func start(processIdentifier pid: pid_t, fresh: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = Self.largestWindow(of: pid, in: content) else { throw Failure.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        try await start(filter: filter, size: window.frame.size, scale: CGFloat(filter.pointPixelScale), fresh: fresh)
    }

    /// The biggest on-screen window the process owns.
    ///
    /// **Biggest, not first.** A game very often has a small helper window — a
    /// launcher splash, an anti-cheat shim, an invisible input sink — and the
    /// order `SCShareableContent` returns them in is not the order anybody
    /// would guess. Zero-sized windows are skipped outright.
    static func largestWindow(of pid: pid_t, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == pid }
            .filter { $0.frame.width > 1 && $0.frame.height > 1 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Starts keeping the picture and sound `filter` selects.
    ///
    /// - Parameters:
    ///   - size: the source's size in points, and `scale` its pixels per point.
    ///   - fresh: forget what was kept before — a different game.
    public func start(filter: sending SCContentFilter, size: CGSize, scale: CGFloat, fresh: Bool) async throws {
        await stop()
        if fresh {
            video.reset()
            sound.withLock { $0 = TimedAudioTrack() }
        }
        let settings = self.settings
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width >= 16, pixels.height >= 16 else { throw Failure.nothingToCapture }
        let fitted = ScreenShareCapture.fit(
            width: Int(pixels.width), height: Int(pixels.height),
            into: Int(Double(settings.maxHeight) * 16 / 9 * 2), by: settings.maxHeight
        )

        let encoder = ReplayVideoEncoder(
            configuration: .init(
                width: fitted.width, height: fitted.height, framerate: settings.framerate,
                bitrate: ReplayVideoEncoder.Configuration.bitrate(
                    width: fitted.width, height: fitted.height, framerate: settings.framerate
                )
            ),
            ring: video
        )
        try encoder.start()

        let configuration = SCStreamConfiguration()
        configuration.width = fitted.width
        configuration.height = fitted.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framerate))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.queueDepth = 6
        configuration.capturesAudio = settings.capturesAudio
        configuration.sampleRate = Int(OpusFormat.sampleRate)
        configuration.channelCount = Int(OpusFormat.channels)
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        queue.sync {
            soundEncoder = settings.capturesAudio
                ? try? OpusEncoder(bitrate: 128_000, signal: .soundshare)
                : nil
            soundFilled = 0
            lastPicture = nil
            startStillTimer()
        }
        do {
            try await stream.startCapture()
        } catch {
            encoder.stop()
            queue.sync { stopStillTimer() }
            throw error
        }
        control.withLock { control in
            control.stream = stream
            control.encoder = encoder
        }
        Self.log.info("clips: buffering \(fitted.width, privacy: .public)×\(fitted.height, privacy: .public) at \(settings.framerate, privacy: .public) fps, \(Int(settings.length), privacy: .public) s")
    }

    /// Stops capturing. **What was kept stays** until the next `start` asks
    /// for a fresh ring, so the moment just before a game quit can still be
    /// clipped.
    public func stop() async {
        let (stream, encoder) = control.withLock { control -> (SCStream?, ReplayVideoEncoder?) in
            defer {
                control.stream = nil
                control.encoder = nil
            }
            return (control.stream, control.encoder)
        }
        try? await stream?.stopCapture()
        encoder?.stop()
        queue.sync {
            stopStillTimer()
            lastPicture = nil
            soundEncoder = nil
        }
    }

    /// Forgets everything kept.
    public func reset() {
        video.reset()
        sound.withLock { $0 = TimedAudioTrack() }
    }

    // MARK: The still picture

    private func startStillTimer() {
        stopStillTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.offerStill() }
        timer.resume()
        stillTimer = timer
    }

    private func stopStillTimer() {
        stillTimer?.cancel()
        stillTimer = nil
    }

    /// Encodes the last picture again as a keyframe when nothing has been
    /// encoded for a second. On `queue`.
    private func offerStill() {
        guard let lastPicture,
              let encoder = control.withLock({ $0.encoder })
        else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard now.seconds - lastEncoded >= 1 else { return }
        encoder.encode(lastPicture, at: now, forceKeyframe: true)
        lastEncoded = now.seconds
    }

    // MARK: The sound

    /// Gathers the game's sound into 20 ms frames and keeps each as Opus. On
    /// `queue`, allocating only the packet it keeps.
    private func gather(_ sampleBuffer: CMSampleBuffer) {
        guard let encoder = soundEncoder,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mBitsPerChannel == 32,
              description.mSampleRate == Double(OpusFormat.sampleRate)
        else { return }
        let channels = Int(description.mChannelsPerFrame)
        guard channels == 1 || channels == 2 else { return }
        let isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: soundBuffers.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2), blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block
        ) == noErr else { return }

        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let stride: Int
        if isInterleaved || channels == 1 {
            guard let base = soundBuffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            left = UnsafePointer(base)
            right = channels == 2 ? UnsafePointer(base + 1) : UnsafePointer(base)
            stride = channels
        } else {
            guard soundBuffers.count >= 2,
                  let first = soundBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let second = soundBuffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return }
            left = UnsafePointer(first)
            right = UnsafePointer(second)
            stride = 1
        }

        let bufferStart = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let window = control.withLock { $0.settings.window }
        let rate = Double(OpusFormat.sampleRate)
        for index in 0..<count {
            if soundFilled == 0 { soundFrameStart = bufferStart + Double(index) / rate }
            soundFrame[soundFilled] = Int16(max(-1, min(1, left[index * stride])) * 32_767)
            soundFrame[soundFilled + 1] = Int16(max(-1, min(1, right[index * stride])) * 32_767)
            soundFilled += 2
            guard soundFilled == soundFrame.count else { continue }
            soundFilled = 0
            let length = soundFrame.withUnsafeBufferPointer { samples in
                (try? encoder.encode(samples.baseAddress!, into: &soundScratch)) ?? 0
            }
            guard length > 0 else { continue }
            let frame = TimedAudioFrame(time: soundFrameStart, payload: .opus(Array(soundScratch[0..<length])))
            sound.withLock { $0.append(frame, keeping: window) }
        }
    }
}

extension ReplayCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Self.log.warning("clips: capture stopped: \(error.localizedDescription, privacy: .public)")
        let encoder = control.withLock { control -> ReplayVideoEncoder? in
            guard control.stream === stream else { return nil }
            defer {
                control.stream = nil
                control.encoder = nil
            }
            return control.encoder
        }
        encoder?.stop()
        queue.async { [self] in
            stopStillTimer()
            lastPicture = nil
        }
    }
}

extension ReplayCapture: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw)
            else { return }
            switch status {
            case .complete:
                guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let encoder = control.withLock({ $0.encoder })
                else { return }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                encoder.encode(pixels, at: time)
                lastPicture = pixels
                lastEncoded = time.seconds
            case .idle:
                offerStill()
            default:
                lastPicture = nil
            }
        case .audio:
            gather(sampleBuffer)
        default:
            break
        }
    }
}
