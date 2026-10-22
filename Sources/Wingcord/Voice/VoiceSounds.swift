import AVFoundation
import Foundation
import OSLog
import WingcordVoice

// MARK: - The sounds a call makes
//
// Fourteen short clips, and the rule that decides which of them plays is the
// same one every time: **a sound reports something that happened, and it plays
// for the person it happened TO.** Your own mute is your sound; somebody else
// joining is a sound about the room; somebody starting to watch your screen is
// a sound about you.
//
// Shipped as 96 kbps AAC rather than the 320 kbps MP3 they arrived as. These
// are half-second blips through a mixer that then re-encodes everything at 64
// kbit; the difference is inaudible and the bundle is a third the size.

enum VoiceSound: String, CaseIterable, Sendable {
    /// Somebody arrived in the channel — including you.
    case join
    /// Somebody else left.
    case userLeave = "user_leave"
    /// **You** are no longer connected: you left, or the connection failed.
    case voiceDisconnected = "voice_disconnected"

    case mute
    case unmute
    case deafen
    case undeafen

    case cameraOn = "camera_open"
    case cameraOff = "camera_off"

    case streamStart = "stream_start"
    case streamEnd = "stream_end"
    /// Somebody started, or stopped, watching **your** screen share.
    case viewerJoin = "viewer_join"
    case viewerLeave = "viewer_leave"

    /// The ringback, while you are calling somebody who has not answered. The
    /// one looping sound here.
    case outgoingCall = "outgoing_call"

    var loops: Bool { self == .outgoingCall }

    /// Discord's `stage_waiting` — not a blip but a minute and a half, read as
    /// it plays rather than decoded with the clips (`LoopedTrack`).
    static var stageWaitingURL: URL? {
        Bundle.module.url(forResource: "stage_waiting", withExtension: "m4a", subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: "stage_waiting", withExtension: "m4a")
    }

    /// The clip in the app's resource bundle.
    ///
    /// `subdirectory` first, because the resources are declared with `.copy`
    /// and the directory survives into the bundle; the flat lookup is the
    /// fallback for a bundle laid out the other way, and both are cheap.
    var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "m4a", subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: rawValue, withExtension: "m4a")
    }

    /// Relative loudness, so a blip that fires while somebody is talking sits
    /// under the conversation rather than over it.
    ///
    /// **The ringback is the loud one on purpose**: it is the only sound here
    /// that plays when there is nothing else to hear, and it is the one people
    /// wait for.
    var volume: Float {
        switch self {
        case .outgoingCall: 0.8
        case .join, .userLeave, .voiceDisconnected: 0.55
        default: 0.45
        }
    }
}

/// Decodes the clips once and plays them out of the right engine.
///
/// **Two engines, and which one a sound uses is a real decision.** A one-shot
/// during a call goes through the call's own mixer, which puts it out of the
/// chosen device *and inside the echo canceller's reference* — so the far end
/// does not hear your join sound back through your microphone. Everything else
/// — every sound outside a call, and the looping ringback, which starts before
/// the media session exists — goes through `NotificationAudioEngine`, which
/// opens no input at all.
@MainActor
final class VoiceSoundPlayer {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "VoiceAudio")

    /// Set by the controller while a call is up. Nil means "no mixer to join".
    var callSink: ((_ samples: [Float], _ volume: Float) -> Void)?

    private let notifications = NotificationAudioEngine()
    /// Decoded once, kept for the session. Fourteen clips of under two and a
    /// half seconds is about two megabytes of float; decoding one on the event
    /// would put a file read and an AAC decode between a click and its sound.
    private var interleaved: [VoiceSound: [Float]] = [:]
    private var buffers: [VoiceSound: AVAudioPCMBuffer] = [:]

    func play(_ sound: VoiceSound) {
        guard AppSettings.shared.playsCallSounds else { return }
        // Streamer Mode's "Disable all sound effects".
        guard !StreamerMode.shared.disablesSounds else { return }
        guard let clip = load(sound) else { return }

        if !sound.loops, let callSink {
            callSink(clip.samples, sound.volume)
            return
        }
        notifications.play(
            clip.buffer,
            volume: sound.volume,
            loops: sound.loops,
            outputUniqueID: AppSettings.shared.voiceOutputDeviceID
        )
    }

    /// Ends the ringback. Called when the call is answered, declined, or given
    /// up on — all three, because a ringtone that outlives its call is the one
    /// sound bug everybody notices.
    func stopRinging() {
        notifications.stopLooping()
    }

    /// Follows a device change made in the settings window.
    func outputDeviceChanged() {
        notifications.setOutput(uniqueID: AppSettings.shared.voiceOutputDeviceID)
    }

    // MARK: Decoding

    private func load(_ sound: VoiceSound) -> (samples: [Float], buffer: AVAudioPCMBuffer)? {
        if let samples = interleaved[sound], let buffer = buffers[sound] {
            return (samples, buffer)
        }
        guard let url = sound.url else {
            Self.log.error("missing sound \(sound.rawValue, privacy: .public)")
            return nil
        }
        guard let decoded = Self.decode(url) else { return nil }
        interleaved[sound] = decoded.samples
        buffers[sound] = decoded.buffer
        return decoded
    }

    /// Reads a clip and converts it once to the one format both engines take:
    /// 48 kHz stereo float. Nothing downstream converts anything.
    nonisolated static func decode(
        _ url: URL
    ) -> (samples: [Float], buffer: AVAudioPCMBuffer)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let target = NotificationAudioEngine.format
        guard let source = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ), (try? file.read(into: source)) != nil,
            let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return nil }

        let capacity = AVAudioFrameCount(
            Double(source.frameLength) * target.sampleRate / file.processingFormat.sampleRate
        ) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, output.frameLength > 0,
              let channels = output.floatChannelData else { return nil }

        // The call mixer takes interleaved; the player node takes the
        // non-interleaved buffer it already is. Both are derived from one
        // decode rather than the file being read twice.
        let frames = Int(output.frameLength)
        let count = Int(target.channelCount)
        var samples = [Float](repeating: 0, count: frames * count)
        for frame in 0..<frames {
            for channel in 0..<count {
                samples[frame * count + channel] = channels[channel][frame]
            }
        }
        return (samples, output)
    }
}
