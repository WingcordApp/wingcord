import Accelerate
import AVFoundation
import Foundation
import Synchronization

// MARK: - Capture and playback
//
// One `AVAudioEngine` for both halves, and that is the load-bearing decision in
// this file rather than a convenience.
//
// **Echo cancellation only works if the thing being cancelled goes through the
// same engine.** `setVoiceProcessingEnabled(true)` installs Apple's voice
// processing IO unit — the same one FaceTime uses — and it cancels the echo of
// *its own output*. Play the remote speakers through a second engine, or through
// `AVAudioPlayer`, or through anything else, and the canceller has no reference
// signal: everybody hears themselves back through your microphone, and no amount
// of tuning at this end can remove it. So the mix goes into a source node on
// this engine's main mixer, and nothing in this app plays call audio any other
// way.
//
// It brings three more things with it that are otherwise weeks of work each:
// noise suppression, automatic gain control, and a muted-speech detector that is
// how the app can say "you are talking while muted" without listening to a
// muted microphone itself.

public final class VoiceAudioEngine: @unchecked Sendable {

    /// 48 kHz stereo interleaved `Int16`, 960 frames — one Opus packet's worth.
    /// Called from the capture tap's queue, never the main actor.
    public var onCaptureFrame: (@Sendable (UnsafePointer<Int16>, Float) -> Void)?
    /// Fired when the voice processor hears speech while the input is muted.
    public var onSpeechWhileMuted: (@Sendable () -> Void)?

    /// **A `var`, because a refused voice processor poisons the engine.** See
    /// `unwind()`: the only reliable way back is a new one.
    private var engine = AVAudioEngine()
    private let playbackRing = AudioRing(capacity: 1 << 16)   // ~340 ms of stereo
    private var sourceNode: AVAudioSourceNode?
    public private(set) var isRunning = false

    /// Everything the capture tap owns, and it owns all of it exclusively.
    ///
    /// **The tap's buffer size is a hint, not a promise.** CoreAudio delivers
    /// whatever the device's own buffer is — 512 frames on most Macs, never 960
    /// — so capture accumulates and the packetiser drains. A client that
    /// encodes whatever the tap handed it sends packets of the wrong duration,
    /// which the server accepts and every listener's jitter buffer then fights.
    ///
    /// The two buffers are held rather than made per callback. At a hundred
    /// callbacks a second, allocating a staging buffer and a converted one each
    /// time is twelve thousand allocations a minute for two objects whose size
    /// never changes.
    private let capture = Mutex(CaptureState())

    private struct CaptureState {
        var pending: [Int16] = []
        var frame: [Int16] = []
        var staging: AVAudioPCMBuffer?
        var converted: AVAudioPCMBuffer?
        var converter: AVAudioConverter?
        var target: AVAudioFormat?
    }

    /// The four scalars the render thread and the capture tap share.
    ///
    /// A reference type holding the atomics rather than four stored properties:
    /// `Atomic` is non-copyable, so a render block cannot capture one out of
    /// `self` without borrowing `self` into a `@Sendable` closure — and
    /// capturing `self` there is what puts the whole engine, its `AVAudioEngine`
    /// and its converter on the audio thread's retain path.
    private let levels = Levels()

    private final class Levels: Sendable {
        let output = Atomic<UInt32>(0x3F80_0000)   // 1.0f
        let input = Atomic<UInt32>(0x3F80_0000)
        let captured = Atomic<UInt32>(0)
        /// Frames the tap has actually delivered. The proof it is feeding.
        let frames = Atomic<Int>(0)
        let monitors = Atomic<Bool>(false)
    }

    public init() {}

    // MARK: Permission

    /// Prompts if the reader has never been asked, and reports the answer.
    ///
    /// **Asked rather than assumed, for the reason the camera's twin is**: the
    /// failure to ask is invisible at the call site. Without the grant the
    /// voice processing unit will not initialise, `start()` throws an OSStatus
    /// with no mention of permission anywhere in it, and the call presents as
    /// an audio engine that would not start for no reason a reader can act on.
    ///
    /// Returns straight away once the answer is known, so this is safe on the
    /// join path: only the very first call in the app's life waits on a person.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Lifecycle

    /// Whether the call is running through the system's voice processor.
    ///
    /// **A measurement, not a preference.** Nothing chooses this: the engine
    /// asks for the processor and reports what it got. When it is `false` there
    /// is no echo cancellation, no noise suppression and no automatic gain, and
    /// the surfaces that promise those have to say so instead.
    public private(set) var isVoiceProcessing = false


    /// Brings the engine up on the chosen devices, with the voice processor if
    /// the machine will give us one.
    ///
    /// **The voice unit does not fail where it is asked for.**
    /// `setVoiceProcessingEnabled(true)` returns without complaint, and the
    /// engine then refuses to initialise its *output* unit —
    /// `kAudioUnitErr_FailedInitialization` (-10875), naming a node that has
    /// nothing to do with the microphone. Measured on macOS 27 against every
    /// device on one machine, built-in and USB alike, and reproduced outside
    /// this app: where it happens it happens to every device, and the input
    /// node reports a phantom nine channels whatever it is pointed at.
    ///
    /// So the fallback lives here, where the failure actually appears, rather
    /// than around the call that was supposed to report it. **A call without
    /// the canceller is worth having; no call is not** — and the reader is told
    /// which one they got rather than left to discover it through an echo.
    /// Brings the engine up, with the voice processor if the machine gives us
    /// one and without it if not.
    ///
    /// **On the main thread, and that is not decoration.** Building an engine
    /// off the main thread after a voice-processing teardown intermittently
    /// hands back an output node with no channels and no sample rate, and
    /// `start()` then fails on
    /// `IsFormatSampleRateAndChannelCountValid(outputHWFormat)`. Reproduced
    /// outside this app: the identical sequence is 6/6 on the main thread and
    /// fails every other attempt on a background queue. `VoiceEngine` is an
    /// actor, so without this the call's audio is a coin flip — which is
    /// exactly how it behaved.
    ///
    /// **The processor is asked for on every start, even where it always
    /// refuses, and that is not waste.** Measured twice: a start that skips the
    /// request outright leaves the output node reporting `0 ch, 0 Hz` and the
    /// engine will not start at all, while a start that asks, is refused, and
    /// rebuilds comes up and captures. Asking is what leaves the I/O unit in a
    /// state the plain engine can use. Remembering the refusal to "save" the
    /// attempt is what broke it.
    @MainActor
    public func start(inputUniqueID: String?, outputUniqueID: String?) throws {
        guard !isRunning else { return }
        do {
            try bringUp(
                inputUniqueID: inputUniqueID,
                outputUniqueID: outputUniqueID,
                voiceProcessing: true
            )
        } catch {
            VoiceTrace.fault(
                "audio engine would not start with the voice processor (\(error)); "
                + "retrying without echo cancellation"
            )
            unwind()
            do {
                try bringUp(
                    inputUniqueID: inputUniqueID,
                    outputUniqueID: outputUniqueID,
                    voiceProcessing: false
                )
            } catch {
                // **Nothing half-built is left behind.** `stop()` guards on
                // `isRunning`, which a failed start never sets, so without this
                // the engine — attached nodes, and an I/O unit that has already
                // been told to initialise — stays alive for the lifetime of the
                // call object. They accumulate one per failed call, and each
                // one holds the device the next attempt needs.
                unwind()
                throw error
            }
        }
        isRunning = true
        VoiceTrace.write("audio engine up, voiceProcessing=\(isVoiceProcessing)")
    }

    /// Throws away the engine a failed attempt left behind.
    ///
    /// Not `stop()`: that guards on `isRunning`, which a failed start never
    /// set. And **not a reset either — a whole new engine.** Turning voice
    /// processing back off does not put the I/O unit back: the output node
    /// returns with a zero-channel, zero-rate hardware format, and the retry
    /// dies on `IsFormatSampleRateAndChannelCountValid(outputHWFormat)` — a
    /// second -10875 that looks like the first and is not. Measured, on the
    /// attempt that this fallback exists to make.
    ///
    /// An `AVAudioEngine` costs a few allocations. A call that cannot come up
    /// costs the whole feature.
    private func unwind() {
        engine.stop()
        // **Dropped, never turned off first.** Calling
        // `setVoiceProcessingEnabled(false)` on the engine that just failed
        // leaves the *process* unable to build a valid output node at all:
        // measured, six starts out of six then failed on
        // `IsFormatSampleRateAndChannelCountValid(outputHWFormat)`, including
        // ones that never asked for the processor. Releasing the engine and
        // building a new one is the only unwind that works.
        sourceNode = nil
        isVoiceProcessing = false
        engine = AVAudioEngine()
    }

    /// **Order matters and it is not the order that reads naturally.** Voice
    /// processing has to be switched on before anything is connected, because
    /// turning it on replaces the IO unit underneath the graph and every
    /// existing connection is torn down with it. Devices are chosen before
    /// that, because the unit is created against whatever device the node is
    /// pointed at.
    private func bringUp(
        inputUniqueID: String?,
        outputUniqueID: String?,
        voiceProcessing: Bool
    ) throws {
        // `withAUAudioUnit` rather than the `auAudioUnit` property, which SDK
        // 27 deprecated: the unit is borrowed for the duration of the closure
        // instead of escaping, which is what makes it safe to touch a node's
        // unit on a running engine.
        if let inputUniqueID, let device = AudioDeviceCatalog.device(uniqueID: inputUniqueID, input: true) {
            try? engine.inputNode.withAUAudioUnit { try $0.setDeviceID(device.id) }
        }
        if let outputUniqueID, let device = AudioDeviceCatalog.device(uniqueID: outputUniqueID, input: false) {
            try? engine.outputNode.withAUAudioUnit { try $0.setDeviceID(device.id) }
        }

        isVoiceProcessing = false
        if voiceProcessing {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.inputNode.isVoiceProcessingAGCEnabled = true
                // Other applications keep their volume. Ducking Music while
                // somebody is in a call is a decision for the person listening
                // to it, and the system's default here is to duck.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                isVoiceProcessing = true
            } catch {
                // The rarer half of the same fault, and the half that is honest
                // about itself. Some aggregate and virtual devices cannot host
                // the unit and say so here.
                VoiceTrace.fault(
                    "voice processor refused: \(error.localizedDescription)"
                )
            }
        }

        let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(OpusFormat.sampleRate),
            channels: AVAudioChannelCount(OpusFormat.channels)
        )!

        let ring = playbackRing
        let levels = self.levels
        let node = AVAudioSourceNode(format: playbackFormat) { _, _, frameCount, audioBufferList in
            Self.render(
                into: audioBufferList,
                frames: Int(frameCount),
                ring: ring,
                gain: Float(bitPattern: levels.output.load(ordering: .relaxed))
            )
        }
        sourceNode = node
        engine.attach(node)
        // **Before the two calls that can throw**, because a format mismatch is
        // the likeliest reason either of them does and the formats are then the
        // whole diagnosis. Written here rather than after `start()` so it
        // survives a throw from the connect below.
        VoiceTrace.write(
            "audio engine starting"
            + " input=\(engine.inputNode.outputFormat(forBus: 0))"
            + " output=\(engine.outputNode.outputFormat(forBus: 0))"
            + " playback=\(playbackFormat)"
        )
        try engine.connectNode(node, to: engine.mainMixerNode, format: playbackFormat)

        // Watching for the "you are muted" case costs nothing when nobody is
        // muted: the processor is already running the detector for its own
        // gating, and this only asks to be told.
        engine.inputNode.setMutedSpeechActivityEventListener { [weak self] event in
            guard event == .started else { return }
            self?.onSpeechWhileMuted?()
        }

        engine.prepare()
        try engine.start()

        // **After `start()`, and the order is the whole of it.** Before it, the
        // input node's format is a guess the hardware has not agreed to yet:
        // measured on one machine it reads three channels before the engine
        // runs and one channel after, and a tap installed against the first
        // number is accepted and then never called. That is a call that
        // connects, reports itself healthy, and carries silence — the worst
        // shape this failure has, and strictly worse than not starting at all.
        installCaptureTap()
    }

    @MainActor
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.setMutedSpeechActivityEventListener(nil)
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        isVoiceProcessing = false
        playbackRing.drain()
    }

    /// Swaps a device without ending the call.
    ///
    /// The engine has to come down: an IO unit is bound to its device, and
    /// there is no supported way to move one. What must *not* happen is the
    /// call ending, so the transport, the gateway and every jitter buffer are
    /// untouched — the reader hears a gap of a few tens of milliseconds and
    /// nothing else.
    @MainActor
    public func reconfigure(inputUniqueID: String?, outputUniqueID: String?) {
        let wasRunning = isRunning
        stop()
        guard wasRunning else { return }
        try? start(inputUniqueID: inputUniqueID, outputUniqueID: outputUniqueID)
    }

    // MARK: Muting

    /// Mutes at the voice processor rather than by dropping frames.
    ///
    /// **The canceller has to keep running while you are muted.** Stopping the
    /// capture instead leaves its adaptive filter with no input to converge on,
    /// so the first second after unmuting is echo — which is exactly when
    /// somebody has just started talking.
    public var isInputMuted: Bool {
        get { engine.inputNode.isVoiceProcessingInputMuted }
        set { engine.inputNode.isVoiceProcessingInputMuted = newValue }
    }

    /// 0…2. Applied to the mixed output before it reaches the device, so it is
    /// this app's level and not the system's — turning Wingcord down must not
    /// turn music down with it.
    public var outputVolume: Float {
        get { Float(bitPattern: levels.output.load(ordering: .relaxed)) }
        set { levels.output.store(max(0, min(2, newValue)).bitPattern, ordering: .relaxed) }
    }

    /// 0…2, applied to the captured signal before it is encoded.
    public var inputVolume: Float {
        get { Float(bitPattern: levels.input.load(ordering: .relaxed)) }
        set { levels.input.store(max(0, min(2, newValue)).bitPattern, ordering: .relaxed) }
    }

    /// The most recent capture level, 0…1, already gained. What the mic meter
    /// draws and what the voice-activity gate decides on.
    public var currentInputLevel: Float {
        Float(bitPattern: levels.captured.load(ordering: .relaxed))
    }

    /// Plays the microphone straight back out. The mic test, and safe to leave
    /// on precisely because the canceller is in the path.
    public var isMonitoringInput: Bool {
        get { levels.monitors.load(ordering: .relaxed) }
        set { levels.monitors.store(newValue, ordering: .relaxed) }
    }

    // MARK: Playback

    /// How much mixed audio is queued, in stereo frames. The mix pump uses it
    /// as its clock: producing on the device's own demand is what keeps the two
    /// from drifting apart over a long call.
    public var queuedFrames: Int { playbackRing.count / Int(OpusFormat.channels) }

    /// Adds `count` interleaved stereo frames to the playback queue.
    public func enqueue(_ samples: UnsafePointer<Float>, frames: Int) {
        playbackRing.write(samples, count: frames * Int(OpusFormat.channels))
    }

    public func flushPlayback() { playbackRing.drain() }

    // MARK: The render block

    /// Runs on CoreAudio's thread. No allocation, no locks, no Swift runtime
    /// calls that could take one — which is why the ring is two atomics and the
    /// gain arrives as a bit pattern rather than through a property.
    private static func render(
        into list: UnsafeMutablePointer<AudioBufferList>,
        frames: Int,
        ring: AudioRing,
        gain: Float
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let first = buffers.first?.mData else { return noErr }

        if buffers.count >= 2, let second = buffers[1].mData {
            // Non-interleaved, which is what `standardFormat` is and what the
            // engine's mixer wants. Read the interleaved ring one frame at a
            // time and split — 480 iterations of two loads and two stores, well
            // inside the budget.
            let left = first.assumingMemoryBound(to: Float.self)
            let right = second.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < frames {
                var pair: (Float, Float) = (0, 0)
                withUnsafeMutableBytes(of: &pair) { raw in
                    _ = ring.read(
                        into: raw.baseAddress!.assumingMemoryBound(to: Float.self),
                        count: 2
                    )
                }
                left[index] = pair.0 * gain
                right[index] = pair.1 * gain
                index += 1
            }
        } else {
            let output = first.assumingMemoryBound(to: Float.self)
            _ = ring.read(into: output, count: frames * Int(OpusFormat.channels))
            if gain != 1 {
                var scale = gain
                vDSP_vsmul(
                    output, 1, &scale, output, 1,
                    vDSP_Length(frames * Int(OpusFormat.channels))
                )
            }
        }
        return noErr
    }

    // MARK: The capture tap

    /// Frames the capture tap has delivered since it was installed.
    ///
    /// **The only evidence the microphone is actually feeding the call.**
    /// Everything else — the engine running, the socket up, the group
    /// established — can be true while this stays at zero.
    public var capturedFrames: Int { levels.frames.load(ordering: .relaxed) }

    /// Takes the capture tap down and puts it back on the format the input
    /// node reports *now*.
    ///
    /// The recovery for a tap that installed against a format the hardware
    /// then changed out from under it, which is a microphone that delivers
    /// nothing while every other part of the call reports itself healthy.
    @MainActor
    public func restartCapture() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        installCaptureTap()
    }

    private func installCaptureTap() {
        levels.frames.store(0, ordering: .relaxed)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            VoiceTrace.fault("input node reported no format; capture is off")
            return
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(OpusFormat.sampleRate),
            channels: AVAudioChannelCount(OpusFormat.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            VoiceTrace.fault("no converter from \(inputFormat) to 48k stereo int16")
            return
        }
        // Mastering-grade resampling in a 20 ms budget spends on a quality
        // nobody can hear through Opus at 64 kbit. `.medium` is what the voice
        // unit itself resamples at.
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        // A generous staging capacity, sized once. The tap is handed whatever
        // the device's buffer is and a reallocation inside the callback is the
        // one thing this path must not do.
        let stagingCapacity = AVAudioFrameCount(inputFormat.sampleRate / 10)
        capture.withLock { state in
            state.converter = converter
            state.target = target
            state.staging = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: stagingCapacity)
            state.converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(stagingCapacity) * target.sampleRate / inputFormat.sampleRate
                ) + 64
            )
            state.pending.reserveCapacity(OpusFormat.interleavedCount * 8)
            state.frame = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
        }

        // 960 is the hint. `installAudioTap` is SDK 27's form: the buffer it
        // hands over is `Sendable` and read-only, which is what lets the block
        // be `@Sendable` without a copy at the boundary.
        do {
            try engine.inputNode.installAudioTap(
                onBus: 0,
                bufferSize: 960,
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            VoiceTrace.write("capture tap up on \(inputFormat)")
        } catch {
            // Never `try?`. A tap that did not install is a microphone that
            // delivers nothing, and the call goes on looking perfectly healthy.
            VoiceTrace.fault("capture tap would not install on \(inputFormat): \(error)")
        }
    }

    /// Converts one tap buffer and emits every whole 20 ms frame in it.
    ///
    /// The lock is held across the conversion and released before the callback:
    /// a client that encodes and sends while holding the capture lock stalls
    /// the next tap, and the tap is on the audio device's own thread.
    private func consume(_ incoming: AVReadOnlyAudioPCMBuffer) {
        let gain = inputVolume
        var frames: [[Int16]] = []

        capture.withLock { state in
            guard let converter = state.converter,
                  let staging = state.staging,
                  let converted = state.converted,
                  incoming.frameLength > 0,
                  incoming.frameLength <= Int(staging.frameCapacity)
            else { return }

            // Copy into the staging buffer the converter can read. The
            // read-only buffer's storage belongs to the audio unit and is
            // valid only for this call.
            staging.frameLength = AVAudioFrameCount(incoming.frameLength)
            incoming.withUnsafeAudioBufferList { source in
                let from = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: source)
                )
                let into = UnsafeMutableAudioBufferListPointer(staging.mutableAudioBufferList)
                for index in 0..<min(from.count, into.count) {
                    guard let sourceData = from[index].mData,
                          let destination = into[index].mData else { continue }
                    let bytes = Int(min(from[index].mDataByteSize, into[index].mDataByteSize))
                    destination.copyMemory(from: sourceData, byteCount: bytes)
                    into[index].mDataByteSize = UInt32(bytes)
                }
            }

            converted.frameLength = 0
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return staging
            }
            guard error == nil, converted.frameLength > 0,
                  let samples = converted.int16ChannelData?[0] else { return }

            let count = Int(converted.frameLength) * Int(OpusFormat.channels)
            if gain == 1 {
                state.pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            } else {
                for index in 0..<count {
                    let scaled = Float(samples[index]) * gain
                    state.pending.append(Int16(max(-32_768, min(32_767, scaled))))
                }
            }

            let width = OpusFormat.interleavedCount
            while state.pending.count >= width {
                frames.append(Array(state.pending.prefix(width)))
                state.pending.removeFirst(width)
            }
        }

        for frame in frames {
            let level = Self.rootMeanSquare(frame)
            levels.captured.store(level.bitPattern, ordering: .relaxed)
            levels.frames.add(Int(incoming.frameLength), ordering: .relaxed)
            frame.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                onCaptureFrame?(base, level)
                if levels.monitors.load(ordering: .relaxed) {
                    monitor(base, frames: OpusFormat.interleavedCount)
                }
            }
        }
    }

    /// Loops the microphone back into the playback ring, for the mic test.
    private func monitor(_ samples: UnsafePointer<Int16>, frames count: Int) {
        var floats = [Float](repeating: 0, count: count)
        vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(count))
        var scale: Float = 1.0 / 32_768
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
        floats.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            playbackRing.write(base, count: count)
        }
    }

    /// The level the meter draws.
    ///
    /// Root mean square rather than a peak: a peak meter on speech spends most
    /// of its time at the top of the scale and says nothing about whether the
    /// gain is right, which is the only question a mic test is asking.
    private static func rootMeanSquare(_ samples: [Int16]) -> Float {
        var floats = [Float](repeating: 0, count: samples.count)
        vDSP_vflt16(samples, 1, &floats, 1, vDSP_Length(samples.count))
        var scale: Float = 1.0 / 32_768
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(samples.count))
        var mean: Float = 0
        vDSP_measqv(floats, 1, &mean, vDSP_Length(samples.count))
        return min(1, sqrt(mean))
    }
}
