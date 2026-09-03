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

    /// The devices `start` was asked for, so a rebuild comes back on the same
    /// ones rather than silently moving the call to the system default.
    private var requestedInput: String?
    private var requestedOutput: String?
    /// This engine's configuration-change observer.
    ///
    /// **One per engine, because `unwind` replaces the engine.** An observer
    /// registered against the object that failed would never fire again, and
    /// the failure it exists to catch is a silent one.
    private var configurationObserver: (any NSObjectProtocol)?
    /// When the last rebuild started. One hardware change arrives as more than
    /// one notification, and a rebuild is a tenth of a second of silence.
    private var lastRebuild = ContinuousClock.now - .seconds(1)

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
        var staging: AVAudioPCMBuffer?
        var converted: AVAudioPCMBuffer?
        var converter: AVAudioConverter?
        /// The format the tap is actually delivering, which is read off the
        /// buffers rather than asked of the node. See `installCaptureTap`.
        var source: AVAudioFormat?
        /// The loudest each of the tap's channels has been, and how many
        /// buffers that is over. Kept only until the line below is written.
        var channelPeaks: [Float] = []
        var peakBuffers = 0

        mutating func reset() {
            pending.removeAll(keepingCapacity: true)
            pending.reserveCapacity(OpusFormat.interleavedCount * 8)
            channelPeaks.removeAll(keepingCapacity: true)
            peakBuffers = 0
            staging = nil
            converted = nil
            converter = nil
            source = nil
        }

        /// Builds the conversion to 48 kHz stereo `Int16` for the format the
        /// tap is delivering, and rebuilds it if that ever changes underneath.
        ///
        /// **Driven by the buffer, never by the node.** Asking the input node
        /// what it will deliver is a guess it is entitled to break, and under
        /// the voice processor it is not even a plausible one — see the tap.
        mutating func prepare(for incoming: AVAudioFormat) -> Bool {
            if let source, source == incoming, converter != nil { return true }
            guard incoming.sampleRate > 0, incoming.channelCount > 0 else {
                reset()
                VoiceTrace.fault("capture tap delivered \(incoming); nothing to convert")
                return false
            }

            // **Only the leading channels are the microphone.** The voice
            // processing unit hands over a bus far wider than the device —
            // seven channels on a two-channel USB microphone, nine on the
            // built-in one — and the extras are not silence to be averaged in.
            // A converter asked to downmix seven unlabelled channels divides
            // the one that matters by seven and folds whatever the others carry
            // into it, which is how a professional microphone reads as a flat
            // meter and an inaudible monitor.
            //
            // So anything wider than stereo is taken as **mono from channel
            // zero**, which is where `AUVoiceIO` puts its processed capture.
            // The trace below prints every channel's peak, so a bus that puts
            // it somewhere else says so rather than presenting as silence.
            let width = incoming.channelCount > AVAudioChannelCount(OpusFormat.channels)
                && !incoming.isInterleaved
                ? AVAudioChannelCount(1) : incoming.channelCount
            guard let taken = AVAudioFormat(
                      commonFormat: incoming.commonFormat,
                      sampleRate: incoming.sampleRate,
                      channels: width,
                      interleaved: incoming.isInterleaved
                  ),
                  let target = AVAudioFormat(
                      commonFormat: .pcmFormatInt16,
                      sampleRate: Double(OpusFormat.sampleRate),
                      channels: AVAudioChannelCount(OpusFormat.channels),
                      interleaved: true
                  ),
                  let made = AVAudioConverter(from: taken, to: target)
            else {
                VoiceTrace.fault("no converter from \(incoming) to 48k stereo int16")
                reset()
                return false
            }
            // Mastering-grade resampling in a 20 ms budget spends on a quality
            // nobody can hear through Opus at 64 kbit. `.medium` is what the
            // voice unit itself resamples at.
            made.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

            // A generous staging capacity, sized once per format. The tap is
            // handed whatever the device's buffer is, and a reallocation inside
            // the callback is the one thing this path must not do.
            let capacity = AVAudioFrameCount(incoming.sampleRate / 10)
            staging = AVAudioPCMBuffer(pcmFormat: taken, frameCapacity: capacity)
            converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    Double(capacity) * target.sampleRate / incoming.sampleRate
                ) + 64
            )
            guard staging != nil, converted != nil else {
                // Nothing half-built is kept: a state that remembers the format
                // but not the buffers would report itself ready for ever.
                reset()
                VoiceTrace.fault("capture buffers would not allocate for \(incoming)")
                return false
            }
            converter = made
            source = incoming
            pending.removeAll(keepingCapacity: true)
            // Measured only where the answer is in doubt: a bus wider than
            // stereo, in the one layout the peaks can be read from.
            channelPeaks = width < incoming.channelCount
                && incoming.commonFormat == .pcmFormatFloat32
                ? [Float](repeating: 0, count: Int(incoming.channelCount)) : []
            peakBuffers = 0
            VoiceTrace.write(
                "capture converting from \(incoming), taking \(width) of "
                + "\(incoming.channelCount) channel(s)"
            )
            return true
        }
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

    /// Set once the processor has been proved to cost this machine its
    /// microphone, after which it is not asked for again for the life of the
    /// process.
    ///
    /// **A canceller that costs the microphone is not worth having.** The
    /// engine's standing rule is the other way round — a call without echo
    /// cancellation beats no call — and this is the same judgement applied one
    /// step further in: a call nobody can hear is not a call. It is set by
    /// `abandonVoiceProcessing`, and only ever after capture has been given a
    /// tap restart and still delivered nothing.
    private var refusesVoiceProcessing = false

    /// Comes back without the voice processor, for good.
    ///
    /// Returns whether anything changed, so a caller that is out of recoveries
    /// can say so plainly instead of reporting one it did not make.
    @MainActor
    public func abandonVoiceProcessing() -> Bool {
        guard isVoiceProcessing, !refusesVoiceProcessing else { return false }
        refusesVoiceProcessing = true
        VoiceTrace.fault(
            "the voice processor is capturing nothing; coming back without echo cancellation"
        )
        let input = requestedInput
        let output = requestedOutput
        stop()
        do {
            try start(inputUniqueID: input, outputUniqueID: output)
        } catch {
            VoiceTrace.fault("audio engine would not start without the processor either: \(error)")
        }
        return true
    }


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
        requestedInput = inputUniqueID
        requestedOutput = outputUniqueID
        // Proved once that the processor costs this machine its microphone, and
        // it is not asked for again. See `abandonVoiceProcessing`.
        guard !refusesVoiceProcessing else {
            try bringUp(
                inputUniqueID: inputUniqueID,
                outputUniqueID: outputUniqueID,
                voiceProcessing: false
            )
            isRunning = true
            VoiceTrace.write("audio engine up, voiceProcessing=false (capture needs it off)")
            return
        }
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
        stopWatchingConfiguration()
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
        // **The main mixer comes up at 44.1 kHz, and the voice processor will
        // not have it.** `AVAudioEngine` gives `mainMixerNode` a default format
        // when it is first touched and only reconciles it with the hardware on
        // its own terms; the output device here runs at 48 kHz. A plain output
        // unit resamples across that and nobody notices. The voice processing
        // unit does not: it refuses to initialise, and the refusal surfaces as
        // `kAudioUnitErr_FailedInitialization` (-10875) on
        // `PerformCommand(*outputNode, kAUInitialize)` — an error that names
        // the output node and says nothing about a sample rate.
        //
        // **Measured, both ways, on this machine.** Every call this app has
        // ever made came up `voiceProcessing=false` on that error, with the
        // device selection blamed for it — pinned, unpinned, input, output, it
        // refused identically. Connecting the mixer to the output at the
        // output's own format is what actually fixes it, and it is the first
        // time the processor has ever come up here.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.sampleRate > 0, hardware.channelCount > 0 {
            try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: hardware)
        }
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
        startWatchingConfiguration()
        // The node is new; the reader's choice is not. See `isInputMuted`.
        engine.inputNode.isVoiceProcessingInputMuted = isMutedValue

        // **After `start()`, and the order is the whole of it.** Before it, the
        // input node's format is a guess the hardware has not agreed to yet:
        // measured on one machine it reads three channels before the engine
        // runs and one channel after, and a tap installed against the first
        // number is accepted and then never called. That is a call that
        // connects, reports itself healthy, and carries silence — the worst
        // shape this failure has, and strictly worse than not starting at all.
        installCaptureTap()
    }

    // MARK: The hardware moving underneath

    /// Asks to be told when CoreAudio changes the hardware this engine is on.
    ///
    /// **`AVAudioEngine` stops itself before it tells anybody.** Apple's own
    /// contract: when the input or output device's channel count or sample rate
    /// changes — a headset going in, a Bluetooth device connecting, a rate
    /// moving — the engine stops and posts this, and nothing restarts it. A
    /// client that does not listen carries silence for the rest of the call
    /// while every other counter still reads healthy. Measured on a real call:
    /// capture froze sixteen seconds in and stayed frozen for the remaining two
    /// minutes, and the watchdog below could not see it because the frame count
    /// was not zero — it had simply stopped moving.
    private func startWatchingConfiguration() {
        stopWatchingConfiguration()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // **Never from this thread.** The callback arrives on CoreAudio's
            // own dispatch queue, and Apple's note on the notification says
            // tearing the engine down there deadlocks. The rebuild replaces the
            // engine, so it has to hop — and it hops to the main actor, because
            // that is where this engine's lifecycle lives.
            Task { @MainActor [weak self] in self?.rebuildAfterConfigurationChange() }
        }
    }

    private func stopWatchingConfiguration() {
        guard let configurationObserver else { return }
        NotificationCenter.default.removeObserver(configurationObserver)
        self.configurationObserver = nil
    }

    @MainActor
    private func rebuildAfterConfigurationChange() {
        guard isRunning else { return }
        // One hardware change arrives as several notifications. Rebuilding on
        // each is a call that stutters every time somebody plugs in a headset.
        let now = ContinuousClock.now
        guard now - lastRebuild > .milliseconds(500) else { return }
        lastRebuild = now

        VoiceTrace.fault("audio hardware changed; rebuilding the engine")
        let input = requestedInput
        let output = requestedOutput
        stop()
        do {
            try start(inputUniqueID: input, outputUniqueID: output)
        } catch {
            // The reason, never only the fact — §1.5's rule for close codes,
            // and an OSStatus out of CoreAudio is the same bargain.
            VoiceTrace.fault("audio engine would not come back after the change: \(error)")
        }
    }

    @MainActor
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        stopWatchingConfiguration()
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
    /// **Held here as well as on the node, because the node does not survive.**
    /// A device swap and a hardware configuration change both rebuild the
    /// engine, and a fresh voice unit comes up unmuted — so without this a
    /// headset going in would open a microphone the reader had closed, in the
    /// middle of a call, silently. It is reapplied on every start.
    public var isInputMuted: Bool {
        get { isMutedValue }
        set {
            isMutedValue = newValue
            engine.inputNode.isVoiceProcessingInputMuted = newValue
        }
    }

    private var isMutedValue = false

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
        capture.withLock { $0.reset() }

        // 960 is the hint. `installAudioTap` is SDK 27's form: the buffer it
        // hands over is `Sendable` and read-only, which is what lets the block
        // be `@Sendable` without a copy at the boundary.
        //
        // **The format is nil, and that is the fix rather than a shortcut.**
        // Apple's own note on this parameter is that a non-nil format
        // "attempts to apply this as the format of the specified output bus" —
        // so passing what `outputFormat(forBus:)` reported was never asking for
        // the bus's format, it was *setting* it. With the voice processor in
        // the path that number is a phantom **nine channels** on a
        // one-channel microphone, and a tap installed against it is accepted,
        // traces itself as healthy, and then delivers nothing at all: measured,
        // with the meter flat and "Hear yourself" silent.
        //
        // With nil the bus keeps its own format and every buffer says what it
        // is, so the conversion is built from the first one and rebuilt if it
        // ever moves. That also retires the older trap this had — a tap
        // installed against a format the hardware then changed — because there
        // is no longer a moment where the format is something we assumed.
        do {
            try engine.inputNode.installAudioTap(
                onBus: 0,
                bufferSize: 960,
                format: nil
            ) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            VoiceTrace.write("capture tap up, taking the format from the buffers")
        } catch {
            // Never `try?`. A tap that did not install is a microphone that
            // delivers nothing, and the call goes on looking perfectly healthy.
            VoiceTrace.fault("capture tap would not install: \(error)")
        }
    }

    /// Converts one tap buffer and emits every whole 20 ms frame in it.
    ///
    /// The lock is held across the conversion and released before the callback:
    /// a client that encodes and sends while holding the capture lock stalls
    /// the next tap, and the tap is on the audio device's own thread.
    private func consume(_ incoming: AVReadOnlyAudioPCMBuffer) {
        // **Counted once per tap buffer, and it is the tap's own frame count.**
        // Counting inside the loop below charged the buffer's whole length to
        // every 20 ms frame it produced, so a device handing over 100 ms at a
        // time reported five times the samples that existed — a number that
        // reads as healthy while measuring nothing.
        guard incoming.frameLength > 0 else { return }
        levels.frames.add(Int(incoming.frameLength), ordering: .relaxed)

        let gain = inputVolume
        // Every whole 20 ms frame in this buffer, end to end in one allocation.
        // A separate array per frame was fifty a second for the life of a call,
        // and each `removeFirst` behind it moved the remainder down again.
        var drained: [Int16] = []

        capture.withLock { state in
            guard state.prepare(for: incoming.format),
                  let converter = state.converter,
                  let staging = state.staging,
                  let converted = state.converted,
                  incoming.frameLength <= Int(staging.frameCapacity)
            else { return }

            // Copy into the staging buffer the converter can read. The
            // read-only buffer's storage belongs to the audio unit and is
            // valid only for this call.
            // **The copy takes the leading channels and no more**, because the
            // staging buffer is only as wide as `prepare` decided to take. See
            // there for why the rest of a voice-processed bus must not be
            // averaged in.
            staging.frameLength = AVAudioFrameCount(incoming.frameLength)
            var peaks = state.channelPeaks
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
                // Which channel actually carries the microphone, measured.
                for index in 0..<min(from.count, peaks.count) {
                    guard let data = from[index].mData else { continue }
                    let count = Int(from[index].mDataByteSize) / MemoryLayout<Float>.size
                    guard count > 0 else { continue }
                    var peak: Float = 0
                    vDSP_maxmgv(
                        data.assumingMemoryBound(to: Float.self), 1, &peak, vDSP_Length(count)
                    )
                    peaks[index] = max(peaks[index], peak)
                }
            }
            if !peaks.isEmpty {
                state.peakBuffers += 1
                // Twenty buffers is a couple of seconds at the sizes CoreAudio
                // hands over — long enough for somebody to have said a word.
                if state.peakBuffers >= 20 {
                    VoiceTrace.write(
                        "capture channel peaks: "
                        + peaks.map { String(format: "%.3f", $0) }.joined(separator: " ")
                    )
                    peaks.removeAll(keepingCapacity: false)
                }
                state.channelPeaks = peaks
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
            let whole = state.pending.count / width * width
            guard whole > 0 else { return }
            drained = Array(state.pending[0..<whole])
            state.pending.removeFirst(whole)
        }

        // **Outside the lock.** A client that encodes and sends while holding
        // the capture lock stalls the next tap, and the tap is on the audio
        // device's own thread.
        let width = OpusFormat.interleavedCount
        let monitors = levels.monitors.load(ordering: .relaxed)
        drained.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for start in stride(from: 0, to: buffer.count, by: width) {
                let frame = base + start
                let level = Self.rootMeanSquare(frame, count: width)
                levels.captured.store(level.bitPattern, ordering: .relaxed)
                onCaptureFrame?(frame, level)
                if monitors { monitor(frame, frames: width) }
            }
        }
    }

    /// Loops the microphone back into the playback ring, for the mic test.
    ///
    /// The scratch is stack memory rather than an array: this runs fifty times
    /// a second on the capture thread, and a heap allocation there is the one
    /// cost that buys nothing.
    private func monitor(_ samples: UnsafePointer<Int16>, frames count: Int) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { floats in
            guard let base = floats.baseAddress else { return }
            Self.normalise(samples, into: base, count: count)
            playbackRing.write(base, count: count)
        }
    }

    /// The level the meter draws.
    ///
    /// Root mean square rather than a peak: a peak meter on speech spends most
    /// of its time at the top of the scale and says nothing about whether the
    /// gain is right, which is the only question a mic test is asking.
    private static func rootMeanSquare(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { floats in
            guard let base = floats.baseAddress else { return 0 }
            normalise(samples, into: base, count: count)
            var mean: Float = 0
            vDSP_measqv(base, 1, &mean, vDSP_Length(count))
            return min(1, sqrt(mean))
        }
    }

    /// `Int16` to `Float` in −1…1, which both readers above want first.
    private static func normalise(
        _ samples: UnsafePointer<Int16>, into floats: UnsafeMutablePointer<Float>, count: Int
    ) {
        vDSP_vflt16(samples, 1, floats, 1, vDSP_Length(count))
        var scale: Float = 1.0 / 32_768
        vDSP_vsmul(floats, 1, &scale, floats, 1, vDSP_Length(count))
    }
}
