import AVFoundation
import Foundation
import OSLog
import Synchronization

// MARK: - The blips a call makes when there is no call
//
// A second, minimal engine for the sounds that have to play when the media
// engine is not up — muting yourself outside a call, and the ringback while you
// are calling somebody who has not answered.
//
// **It never touches the microphone.** `VoiceAudioEngine` turns on the voice
// processing unit, which opens the input; using it to play a two-hundred
// millisecond blip would light the microphone indicator on somebody's Mac for a
// sound effect, which is not a trade this app makes. This is a player node into
// an output and nothing else.
//
// **It is pointed at the same device the call uses.** A notification sound that
// comes out of the laptop speakers while the call is in a headset is a sound
// nobody hears in the headset and everybody hears in the room.
public final class NotificationAudioEngine: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "VoiceAudio")

    /// The engine's own format. Everything is converted to it once, at decode
    /// time, so playing a sound is a schedule and no conversion.
    public static let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(OpusFormat.sampleRate),
        channels: AVAudioChannelCount(OpusFormat.channels)
    )!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let state = Mutex(State())

    private struct State {
        var isRunning = false
        var outputUniqueID: String?
        var isLooping = false
    }

    /// Shuts the device down again once nothing has played for a while.
    ///
    /// **An engine left running holds the output device awake**, which on a
    /// laptop is a measurable amount of power spent on silence. Five seconds is
    /// long enough that a run of blips — mute, then deafen, then somebody
    /// joining — does not restart it between each one, and short enough that
    /// the device is not held for a session.
    private let idle = Mutex<Task<Void, Never>?>(nil)
    private static let idleTimeout = Duration.seconds(5)

    public init() {}

    deinit {
        idle.withLock { $0?.cancel() }
        engine.stop()
    }

    /// Plays a buffer, starting the engine if it is not up.
    ///
    /// - Parameter loops: for the ringback, which plays until the call is
    ///   answered or given up on.
    public func play(
        _ buffer: AVAudioPCMBuffer,
        volume: Float,
        loops: Bool,
        outputUniqueID: String?
    ) {
        guard start(outputUniqueID: outputUniqueID) else { return }
        if loops {
            // A looping schedule replaces whatever was playing: there is one
            // ringback and starting a second is two out-of-phase copies of the
            // same tone.
            player.stop()
            try? player.playAudio()
        }
        state.withLock { $0.isLooping = loops || $0.isLooping }
        player.volume = max(0, min(1, volume))
        player.scheduleBuffer(buffer, at: nil, options: loops ? [.loops] : []) { }
        if !player.isPlaying { try? player.playAudio() }
        scheduleIdleStop(after: loops ? nil : buffer.duration)
    }

    /// Ends a looping sound without stopping anything else.
    public func stopLooping() {
        guard state.withLock({ $0.isLooping }) else { return }
        state.withLock { $0.isLooping = false }
        player.stop()
        scheduleIdleStop(after: .zero)
    }

    /// Moves to a different output device, which is a restart — an IO unit is
    /// bound to its device and there is no supported way to move one.
    public func setOutput(uniqueID: String?) {
        guard state.withLock({ $0.outputUniqueID }) != uniqueID else { return }
        stop()
        state.withLock { $0.outputUniqueID = uniqueID }
    }

    public func stop() {
        idle.withLock { $0?.cancel(); $0 = nil }
        guard state.withLock({ $0.isRunning }) else { return }
        player.stop()
        engine.stop()
        state.withLock { $0.isRunning = false; $0.isLooping = false }
    }

    private func start(outputUniqueID: String?) -> Bool {
        if state.withLock({ $0.isRunning && $0.outputUniqueID == outputUniqueID }) {
            return true
        }
        stop()
        state.withLock { $0.outputUniqueID = outputUniqueID }

        if let outputUniqueID,
           let device = AudioDeviceCatalog.device(uniqueID: outputUniqueID, input: false) {
            try? engine.outputNode.withAUAudioUnit { try $0.setDeviceID(device.id) }
        }
        if player.engine == nil { engine.attach(player) }
        do {
            try engine.connectNode(player, to: engine.mainMixerNode, format: Self.format)
            engine.prepare()
            try engine.start()
        } catch {
            Self.log.error("notification engine would not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        state.withLock { $0.isRunning = true }
        return true
    }

    private func scheduleIdleStop(after duration: Duration?) {
        idle.withLock { task in
            task?.cancel()
            guard let duration else { return }   // looping: hold the device
            task = Task { [weak self] in
                try? await Task.sleep(for: duration + Self.idleTimeout)
                guard !Task.isCancelled else { return }
                guard self?.state.withLock({ !$0.isLooping }) == true else { return }
                self?.stop()
            }
        }
    }
}

extension AVAudioPCMBuffer {
    /// How long this buffer plays for.
    var duration: Duration {
        .milliseconds(Int(Double(frameLength) / format.sampleRate * 1_000))
    }
}
