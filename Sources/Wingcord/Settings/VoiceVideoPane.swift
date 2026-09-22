import AVFoundation
import SwiftUI
import WingcordVoice

// MARK: - Voice & Video
//
// Devices, levels, how the microphone is gated, and the three tests that answer
// the questions people actually open this pane with: can it hear me, can I hear
// it, and does the camera work.
//
// **Every test uses the device the pane has selected**, not the system default.
// A speaker test that plays through `NSSound` tests whatever macOS is using,
// which is precisely the thing somebody in here is trying to change.
//
// **Nothing here persists a preference that reaches nothing.** §1: a setting
// that saves and changes nothing is a promise the window makes and the app
// breaks. Every control writes through `AppSettings` and is re-applied to a call
// already running by `voicePreferencesChanged()`.
struct VoiceVideoPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var rig = VoiceTestRig()
    @State private var camera = CameraTestRig()
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var cameras: [CameraDevice] = []
    @State private var isTestingCamera = false
    /// Whether the reader has asked for the microphone.
    ///
    /// **Off until asked, exactly as the camera is.** See `VoiceTestRig` for
    /// what opening the pane used to cost.
    @State private var isTestingMic = false

    var body: some View {
        Group {
            devices
            levels
            inputMode
            micCheck
            video
            callSounds
        }
        // **Off the main actor.** Both catalogs are synchronous system calls and
        // together they are about a quarter of a second on the first visit of a
        // process — the pane cannot paint until they return. `WingcordVoice` is
        // not main-actor isolated and both device types are `Sendable`, so this
        // is one hop and no copy.
        .task { await loadDevices() }
        // Start and stop follow the switch, so the engine's life is the test's.
        // `.task(id:)` rather than `.onChange`, so a cancel tears it down too.
        .task(id: isTestingMic) {
            if isTestingMic {
                await rig.start()
            } else {
                rig.stop()
            }
        }
        .onDisappear {
            rig.stop()
            camera.stop()
        }
    }

    // MARK: Devices

    private var devices: some View {
        SettingsGroup("Devices") {
            SettingsCard {
                DevicePickerRow(
                    title: "Input",
                    help: "The microphone Wingcord listens to in calls.",
                    systemImage: "mic.fill",
                    selection: Binding(
                        get: { settings.voiceInputDeviceID },
                        set: {
                            settings.voiceInputDeviceID = $0
                            rig.reconfigure()
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: inputs.map { ($0.uniqueID, $0.name, $0.isDefault) }
                )
                CardDivider()
                DevicePickerRow(
                    title: "Output",
                    help: "Where everyone else's voice comes out.",
                    systemImage: "speaker.wave.2.fill",
                    selection: Binding(
                        get: { settings.voiceOutputDeviceID },
                        set: {
                            settings.voiceOutputDeviceID = $0
                            rig.reconfigure()
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: outputs.map { ($0.uniqueID, $0.name, $0.isDefault) }
                )
                CardDivider()
                SettingsActionRow(
                    "Speaker test",
                    help: "Plays a short chime through the output above — not through the system default.",
                    actionTitle: "Play"
                ) {
                    rig.playTestTone()
                }
            }
            SettingsFootnote(
                "Devices are remembered by name rather than by their position in the list, "
                    + "so unplugging a headset and plugging it back in keeps your choice. "
                    + "A device that has gone away falls back to whatever macOS is using.",
                symbolName: "cable.connector"
            )
        }
    }

    // MARK: Levels

    private var levels: some View {
        SettingsGroup("Volume") {
            SettingsCard {
                SettingsSliderRow(
                    title: "Input volume",
                    help: "Applied before your voice is encoded. Above 100% is real gain, for a quiet microphone.",
                    value: Binding(
                        get: { settings.voiceInputVolume },
                        set: {
                            settings.voiceInputVolume = $0
                            rig.setInputVolume($0)
                            model.voicePreferencesChanged()
                        }
                    ),
                    range: 0...2,
                    step: 0.05,
                    format: { "\(Int($0 * 100))%" }
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Output volume",
                    help: "Wingcord's own level. It does not move the system volume.",
                    value: Binding(
                        get: { settings.voiceOutputVolume },
                        set: {
                            settings.voiceOutputVolume = $0
                            rig.setOutputVolume($0)
                            model.voicePreferencesChanged()
                        }
                    ),
                    range: 0...2,
                    step: 0.05,
                    format: { "\(Int($0 * 100))%" }
                )
            }
        }
    }

    // MARK: How the microphone opens

    private var inputMode: some View {
        SettingsGroup("Input mode") {
            SettingsCard {
                CardHeaderRow(
                    title: "Open the microphone",
                    help: "Voice activity opens it when you speak. Push to talk opens it only while a key is held."
                )
                SettingsSegmentedControl(
                    selection: Binding(
                        get: { settings.inputMode },
                        set: {
                            settings.inputMode = $0
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: [
                        .init(.voiceActivity, "Voice activity", symbolName: "waveform"),
                        .init(.pushToTalk, "Push to talk", symbolName: "hand.tap.fill"),
                    ]
                )
            }

            if settings.inputMode == .voiceActivity {
                SettingsCard {
                    ThresholdRow(
                        level: rig.level,
                        isLive: rig.isRunning,
                        threshold: Binding(
                            get: { settings.voiceActivityThreshold },
                            set: {
                                settings.voiceActivityThreshold = $0
                                model.voicePreferencesChanged()
                            }
                        )
                    )
                }
                .padding(.top, SettingsMetrics.cardToHeader)
                SettingsFootnote(
                    "Speak normally and set the line just under where the bar sits. "
                        + "Wingcord keeps sending for a quarter of a second after you stop, "
                        + "so a pause between words does not cut the end off a sentence.",
                    symbolName: "waveform.badge.mic"
                )
            } else {
                SettingsCard {
                    HotkeyRecorderRow(
                        title: "Push-to-talk key",
                        help: "Held down to open the microphone.",
                        hotkey: Binding(
                            get: { settings.pushToTalkKey },
                            set: {
                                settings.pushToTalkKey = $0
                                model.voicePreferencesChanged()
                            }
                        )
                    )
                }
                .padding(.top, SettingsMetrics.cardToHeader)
                SettingsFootnote(
                    "The key works while Wingcord is the frontmost app. Making it work over a "
                        + "game would need Accessibility access — the same permission a keylogger "
                        + "asks for — and Wingcord will not ask for that on your behalf.",
                    symbolName: "hand.raised"
                )
            }
        }
    }

    // MARK: Mic check

    private var micCheck: some View {
        SettingsGroup("Mic check") {
            SettingsCard {
                if rig.isDenied {
                    PermissionDeniedState(
                        symbolName: "mic.slash",
                        message: "Wingcord does not have permission to use the microphone.",
                        privacyAnchor: "Privacy_Microphone"
                    )
                    CardDivider()
                }
                // **The switch, and it is the only thing that opens the input.**
                // The camera beside it has always worked this way; the
                // microphone did not, and simply looking at this pane lit the
                // recording indicator.
                SettingsToggle(
                    title: "Microphone test",
                    help: "Opens your microphone so the level below moves. Wingcord "
                        + "keeps it shut the rest of the time.",
                    isOn: $isTestingMic
                )
                CardDivider()
                MeterRow(level: rig.level, threshold: nil, isLive: rig.isRunning)
                if rig.isRunning {
                    CardDivider()
                    SettingsToggle(
                        title: "Hear yourself",
                        help: rig.isVoiceProcessing
                            ? "Plays your microphone back through the output above. Echo cancellation stays on, so it is safe on speakers."
                            : "Plays your microphone back through the output above. There is no echo cancellation on this Mac — use headphones, or this will feed back.",
                        isOn: Binding(
                            get: { rig.isMonitoring },
                            set: { rig.isMonitoring = $0 }
                        )
                    )
                }
            }
            if rig.isRunning, !rig.isVoiceProcessing {
                SettingsFootnote(
                    "This Mac's audio system would not hand Wingcord the voice processor, so calls "
                        + "run without echo cancellation, noise suppression or automatic gain. "
                        + "Everything else works — but on speakers the far end will hear themselves, "
                        + "so use headphones.",
                    symbolName: "exclamationmark.triangle"
                )
            } else {
                SettingsFootnote(
                    "Wingcord uses the system's own voice processor — the one FaceTime uses — for "
                        + "echo cancellation, noise suppression and automatic gain. There is nothing to "
                        + "tune here because it tunes itself, and it works better on speakers than any "
                        + "setting could.",
                    symbolName: "waveform.circle"
                )
            }
        }
    }

    // MARK: Camera

    private var video: some View {
        SettingsGroup("Camera") {
            SettingsCard {
                DevicePickerRow(
                    title: "Camera",
                    help: "The camera used for video calls.",
                    systemImage: "video.fill",
                    selection: Binding(
                        get: { settings.cameraDeviceID },
                        set: { deviceID in
                            settings.cameraDeviceID = deviceID
                            guard isTestingCamera else { return }
                            Task { await camera.start(deviceID: deviceID) }
                        }
                    ),
                    options: cameras.map { ($0.id, "\($0.name) · \($0.kind)", false) }
                )
                CardDivider()
                CardHeaderRow(
                    title: "Quality",
                    help: "1080p halves the frame rate: a call's video budget is a few megabits, and twice the pixels at thirty frames leaves neither sharp."
                )
                SettingsSegmentedControl(
                    selection: $settings.videoQuality,
                    options: AppSettings.VideoQuality.allCases.map {
                        .init($0, $0.label)
                    }
                )
            }

            SettingsCard {
                CameraTestRow(
                    isTesting: $isTestingCamera,
                    rig: camera,
                    deviceID: settings.cameraDeviceID
                )
            }
            .padding(.top, SettingsMetrics.cardToHeader)

            SettingsCard {
                SettingsToggle(
                    title: "Share the app's sound when sharing a screen",
                    help: "Captures audio from the window or display you share, alongside your microphone.",
                    isOn: $settings.sharesSystemAudio
                )
            }
            .padding(.top, SettingsMetrics.cardToHeader)
        }
    }

    // MARK: Sounds

    private var callSounds: some View {
        SettingsGroup("Sounds") {
            SettingsCard {
                SettingsToggle(
                    title: "Play call sounds",
                    help: "The short sounds a call makes: joining and leaving, muting, a camera or a screen share starting, and somebody beginning to watch your screen.",
                    isOn: $settings.playsCallSounds
                )
            }
            SettingsFootnote(
                "They come out of the output chosen above, not the system default — and while "
                    + "you are in a call they go through the call's own mixer, so the echo "
                    + "canceller knows about them and nobody hears your join sound back through "
                    + "your microphone.",
                symbolName: "speaker.wave.2"
            )
        }
    }

    private func loadDevices() async {
        let catalog = await Self.catalog()
        inputs = catalog.inputs
        outputs = catalog.outputs
        cameras = catalog.cameras
    }

    /// The three device lists, read off the main actor.
    ///
    /// `nonisolated` so the `await` above is a real hop rather than a
    /// same-actor call that suspends and resumes on the same thread.
    private nonisolated static func catalog() async -> (
        inputs: [AudioDevice], outputs: [AudioDevice], cameras: [CameraDevice]
    ) {
        (AudioDeviceCatalog.inputs(), AudioDeviceCatalog.outputs(), CameraCapture.devices())
    }
}

// MARK: - A device picker

/// A label and a menu.
///
/// **"System default" is a real choice and it is the first one**, not the
/// absence of a choice: a reader who has never opened this pane is on it, and a
/// reader whose headset has gone away falls back to it. Storing nil for it is
/// what makes that fallback automatic.
private struct DevicePickerRow: View {
    var title: String
    var help: String
    var systemImage: String
    @Binding var selection: String?
    /// id, name, and whether macOS calls it the default.
    var options: [(String, String, Bool)]

    var body: some View {
        SettingsControlRow(title, help: help) {
            // A `Picker`, not a hand-built `Menu`: the system draws the
            // checkmark beside the chosen row, keeps it in step with the
            // binding, and gives Full Keyboard Access the behaviour a menu
            // built out of buttons would have to put back by hand.
            Picker(selection: $selection) {
                Text("System default").tag(String?.none)
                Divider()
                ForEach(options, id: \.0) { option in
                    Text(option.2 ? "\(option.1) (default)" : option.1)
                        .tag(String?.some(option.0))
                }
                // A stored device that is no longer here keeps its own row, or
                // the picker would silently show "System default" for a choice
                // the reader made and can still get back by plugging it in.
                if let selection, !options.contains(where: { $0.0 == selection }) {
                    Divider()
                    Text("Not connected").tag(String?.some(selection))
                }
            } label: {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 230, alignment: .trailing)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(currentName))
        }
    }

    private var currentName: String {
        guard let selection else { return "System default" }
        // A stored device that is no longer here says so rather than showing a
        // blank menu: "the headset you chose is unplugged" is the answer
        // somebody in this pane needs.
        return options.first { $0.0 == selection }?.1 ?? "Not connected"
    }
}

// MARK: - The meter

/// The level, drawn as a bar.
///
/// **One scale for the level and the threshold**, which is the whole reason this
/// is not a percentage slider: "set the line under where the bar sits" is a
/// sentence somebody can act on, and "sensitivity: 38%" is not.
private struct MeterRow: View {
    var level: Float
    var threshold: Double?
    /// Whether the microphone is actually open.
    ///
    /// **A still bar and a broken microphone look identical**, and this pane is
    /// the one place somebody comes to tell those two apart — so a meter with no
    /// input behind it says so rather than sitting at zero and letting the
    /// reader draw the wrong conclusion.
    var isLive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Text("Input level")
                    .font(SettingsType.rowLabel)
                    .foregroundStyle(Ink.primary)
                if !isLive {
                    Text("microphone off")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsSurface.controlTrough)
                    Capsule()
                        .fill(fillStyle)
                        .frame(width: max(0, proxy.size.width * CGFloat(min(1, level * 2.2))))
                    if let threshold {
                        // The line, on the same scale as the bar. Drawn over
                        // both, so the reader can see the bar cross it.
                        Rectangle()
                            .fill(Ink.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * CGFloat(min(1, threshold * 2.2)) - 1)
                    }
                }
            }
            .frame(height: 8)
            // Never animated on the level: it is a measured value arriving
            // twenty times a second, and a spring on it makes the bar lag the
            // voice it is supposed to be showing.
            .animation(nil, value: level)
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .padding(.vertical, SettingsMetrics.cardContentInset)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(Int(level * 100)) percent"))
    }

    private var fillStyle: AnyShapeStyle {
        guard let threshold else { return AnyShapeStyle(SettingsSurface.switchOn) }
        // Green once it would open the gate. The colour IS the answer to "is it
        // loud enough", which a monochrome bar makes you infer from a position.
        return Double(level) >= threshold
            ? AnyShapeStyle(Palette.presenceOnline)
            : AnyShapeStyle(SettingsSurface.switchOn)
    }
}

/// The meter and the threshold slider, as one row.
private struct ThresholdRow: View {
    var level: Float
    var isLive: Bool
    @Binding var threshold: Double

    var body: some View {
        VStack(spacing: 0) {
            MeterRow(level: level, threshold: threshold, isLive: isLive)
            CardDivider()
            SettingsSliderRow(
                title: "Open at",
                help: "Where the bar has to reach before Wingcord starts sending.",
                value: $threshold,
                range: 0...0.3,
                step: 0.005,
                // A percentage of full scale, with a decimal, because the
                // useful settings all live in the first few per cent — an
                // integer readout would show "3%" across a third of the slider.
                format: { String(format: "%.1f%%", $0 * 100) }
            )
        }
    }
}

// MARK: - The camera test

private struct CameraTestRow: View {
    @Binding var isTesting: Bool
    var rig: CameraTestRig
    var deviceID: String?

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(spacing: 0) {
            SettingsControlRow(
                "Camera test",
                help: "Shows what everyone else would see. Nothing is sent anywhere."
            ) {
                Button(isTesting ? "Stop" : "Test") {
                    isTesting.toggle()
                    if isTesting {
                        Task { await rig.start(deviceID: deviceID) }
                    } else {
                        rig.stop()
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            if isTesting {
                Group {
                    if rig.isDenied {
                        deniedState
                    } else {
                        CameraPreviewView(session: rig.session)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: Radius.row + 2))
                    }
                }
                .padding(.horizontal, SettingsMetrics.cardContentInset)
                .padding(.bottom, SettingsMetrics.cardContentInset)
                .transition(.materialize(from: .top))
            }
        }
        .animation(motion.standard, value: isTesting)
    }

    private var deniedState: some View {
        PermissionDeniedState(
            symbolName: "video.slash",
            message: "Wingcord does not have permission to use the camera.",
            privacyAnchor: "Privacy_Camera"
        )
    }
}

/// What a card shows in place of a control the reader has refused permission
/// for.
///
/// **One of these, not one per device.** The microphone and the camera fail the
/// same way and are recovered the same way, and a second copy of this is a
/// second place for the wording and the anchor to drift apart.
private struct PermissionDeniedState: View {
    let symbolName: String
    let message: String
    /// The pane's anchor in System Settings — `Privacy_Microphone`, and so on.
    let privacyAnchor: String

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(message)
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.tertiary)
            Button("Open System Settings") {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.group)
    }
}
