import AVFoundation
import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - Voice & Video
//
// Devices, levels, how the microphone is gated, and the two tests that answer
// the questions people actually open this pane with: can it hear me — Discord's
// Mic Test plays you back through the chosen speaker, which answers whether you
// can hear it too — and does the camera work.
//
// **Every test uses the device the pane has selected**, not the system default,
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
            voiceProcessing
            micCheck
            video
            streaming
            callSounds
        }
        // **Off the main actor.** Both catalogs are synchronous system calls and
        // together they are about a quarter of a second on the first visit of a
        // process — the pane cannot paint until they return. `WingcordVoice` is
        // not main-actor isolated and both device types are `Sendable`, so this
        // is one hop and no copy.
        .task { await loadDevices() }
        // Start and stop follow the button, so the engine's life is the test's.
        // `.task(id:)` rather than `.onChange`, so a cancel tears it down too.
        .task(id: isTestingMic) {
            if isTestingMic {
                await rig.start()
                // Discord's test plays you back — except where echo
                // cancellation was asked for and this Mac refused it, where a
                // speaker would feed the microphone.
                rig.isMonitoring = rig.isVoiceProcessing || !settings.resolvedProcessing.echoCancellation
            } else {
                rig.stop()
            }
        }
        .onDisappear {
            rig.stop()
            camera.stop()
        }
    }

    // MARK: Voice

    /// Discord's Voice category: the microphone and the speaker, by its names
    /// for them.
    private var devices: some View {
        SettingsGroup("Voice") {
            SettingsCard {
                DevicePickerRow(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    selection: Binding(
                        get: { settings.voiceInputDeviceID },
                        set: {
                            settings.voiceInputDeviceID = $0
                            rig.reconfigure()
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: inputs.map { ($0.uniqueID, $0.name) }
                )
                CardDivider()
                DevicePickerRow(
                    title: "Speaker",
                    systemImage: "speaker.wave.2.fill",
                    selection: Binding(
                        get: { settings.voiceOutputDeviceID },
                        set: {
                            settings.voiceOutputDeviceID = $0
                            rig.reconfigure()
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: outputs.map { ($0.uniqueID, $0.name) }
                )
            }
        }
    }

    // MARK: Levels

    private var levels: some View {
        SettingsGroup("Volume") {
            SettingsCard {
                // Discord's Input Volume stops at 100%, and its Output Volume
                // on the desktop at 200%.
                // Both along Discord's slider curve — see `VolumeCurve`.
                SettingsSliderRow(
                    title: "Input Volume",
                    value: Binding(
                        get: { min(1, VolumeCurve.position(ofGain: settings.voiceInputVolume)) },
                        set: {
                            let gain = VolumeCurve.gain(atPosition: $0)
                            settings.voiceInputVolume = gain
                            rig.setInputVolume(gain)
                            model.voicePreferencesChanged()
                        }
                    ),
                    range: 0...1,
                    step: 0.05,
                    format: { "\(Int($0 * 100))%" }
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Output Volume",
                    value: Binding(
                        get: { min(2, VolumeCurve.position(ofGain: settings.voiceOutputVolume)) },
                        set: {
                            let gain = VolumeCurve.gain(atPosition: $0)
                            settings.voiceOutputVolume = gain
                            rig.setOutputVolume(gain)
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

    /// Discord's Input Mode, in Discord's words.
    private var inputMode: some View {
        SettingsGroup("Input Mode") {
            SettingsCard {
                SettingsSegmentedControl(
                    selection: Binding(
                        get: { settings.inputMode },
                        set: {
                            settings.inputMode = $0
                            model.voicePreferencesChanged()
                        }
                    ),
                    options: [
                        .init(.voiceActivity, "Voice Activity", symbolName: "waveform"),
                        // Discord's own name for a push to talk that works only
                        // while its window is in front, which is what this one
                        // is: the key is read without Accessibility access.
                        .init(.pushToTalk, "Push to Talk (Limited)", symbolName: "hand.tap.fill"),
                    ]
                )
            }

            SettingsCard {
                if settings.inputMode == .voiceActivity {
                    SettingsToggle(
                        title: "Automatically determine input sensitivity",
                        help: "Turning this off may help if your voice is not being detected by the automatic input sensitivity.",
                        isOn: Binding(
                            get: { settings.automaticInputSensitivity },
                            set: {
                                settings.automaticInputSensitivity = $0
                                model.voicePreferencesChanged()
                            }
                        )
                    )
                    CardDivider()
                    MeterRow(
                        title: "Input Sensitivity",
                        level: rig.level,
                        threshold: settings.automaticInputSensitivity
                            ? nil : settings.voiceActivityThreshold,
                        isLive: rig.isRunning
                    )
                    if !settings.automaticInputSensitivity {
                        CardDivider()
                        SettingsSliderRow(
                            title: "Input Sensitivity",
                            value: Binding(
                                get: { settings.voiceActivityThreshold },
                                set: {
                                    settings.voiceActivityThreshold = $0
                                    model.voicePreferencesChanged()
                                }
                            ),
                            range: -100...0,
                            step: 1,
                            format: { "\(Int($0)) dB" }
                        )
                    }
                } else {
                    HotkeyRecorderRow(
                        title: "Push to Talk Keybind",
                        hotkey: Binding(
                            get: { settings.pushToTalkKey },
                            set: {
                                settings.pushToTalkKey = $0
                                model.voicePreferencesChanged()
                            }
                        )
                    )
                }
            }

            SettingsCard {
                // Discord's own description, for the mode the reader is in.
                HotkeyRecorderRow(
                    title: "Push to Talk (Priority)",
                    help: settings.inputMode == .pushToTalk
                        ? "Hold to temporarily enable your microphone while in Push to Talk mode. Other speakers who are not also transmitting with priority will temporarily have their volume lowered while you are speaking."
                        : "Hold to transmit your voice with priority in Voice Activity mode. Other speakers who are not also transmitting with priority will temporarily have their volume lowered while you are speaking.",
                    hotkey: $settings.priorityPushToTalkKey
                )
                CardDivider()
                SettingsToggle(
                    title: "Show a warning when Discord is not detecting audio from your mic",
                    isOn: $settings.showsSilentMicWarning
                )
            }
        }
    }

    // MARK: Voice processing

    /// Discord's Input Profile, and the switches its Custom profile leaves to
    /// the reader. Noise suppression is the system's own Mic Mode: Apple's
    /// in-app voice isolation adds over fifty milliseconds — measured, against
    /// a thirty-millisecond bound — so the choice is offered where macOS keeps
    /// it.
    private var voiceProcessing: some View {
        SettingsGroup("Voice Processing") {
            SettingsCard {
                CardHeaderRow(title: "Input Profile")
                SettingsSegmentedControl(
                    selection: Binding(
                        get: { settings.inputProfile },
                        set: {
                            settings.inputProfile = $0
                            processingChanged()
                        }
                    ),
                    options: AppSettings.InputProfile.allCases.map { .init($0, $0.title) }
                )
            }

            if settings.inputProfile == .custom {
                SettingsCard {
                    SettingsToggle(
                        title: "Echo Cancellation",
                        isOn: Binding(
                            get: { settings.echoCancellation },
                            set: {
                                settings.echoCancellation = $0
                                processingChanged()
                            }
                        )
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Automatic Gain Control",
                        isOn: Binding(
                            get: { settings.automaticGainControl },
                            set: {
                                settings.automaticGainControl = $0
                                processingChanged()
                            }
                        )
                    )
                    // The processor's own, and nothing without it.
                    .disabled(!settings.echoCancellation)
                }
            }

            SettingsCard {
                SettingsToggle(
                    title: "Adaptive Playout (Beta)",
                    help: "Speeds speech up or slows it down by a few milliseconds to ride out network delay, instead of gaps.",
                    isOn: Binding(
                        get: { settings.adaptivePlayout },
                        set: {
                            settings.adaptivePlayout = $0
                            model.voicePreferencesChanged()
                        }
                    )
                )
            }

            if settings.resolvedProcessing.echoCancellation {
                SettingsCard {
                    SettingsActionRow(
                        "Noise Suppression",
                        help: "Reduces background noise from your mic.",
                        actionTitle: "Customize"
                    ) {
                        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    }
                }
            }
        }
    }

    /// A change to how the voice is processed reaches the call and the test.
    private func processingChanged() {
        rig.reconfigure()
        model.voicePreferencesChanged()
    }

    // MARK: Mic Test

    /// Discord's mic test: one button, the meter, and your voice played back
    /// through the speaker chosen above — "Playing back your beautiful voice" —
    /// or, after five seconds of nothing at all, its no-input lines.
    private var micCheck: some View {
        SettingsGroup("Mic Test") {
            SettingsCard {
                if rig.isDenied {
                    PermissionDeniedState(
                        symbolName: "mic.slash",
                        message: "Discord does not have access to your microphone",
                        privacyAnchor: "Privacy_Microphone"
                    )
                    CardDivider()
                }
                // **The button, and it is the only thing that opens the
                // input.** Simply looking at this pane once lit the recording
                // indicator.
                HStack(spacing: Spacing.snug) {
                    Text("Having mic issues? Start a test and say something fun\u{2014}we'll play your voice back to you.")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.base)
                    Button(isTestingMic ? "Stop Testing" : "Mic Test") { isTestingMic.toggle() }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Palette.accent)
                }
                .padding(.leading, SettingsMetrics.cardContentInset)
                .padding(.trailing, SettingsMetrics.controlTrailing)
                .padding(.vertical, SettingsMetrics.cardContentInset)
                CardDivider()
                MeterRow(title: nil, level: rig.level, threshold: nil, isLive: rig.isRunning)
                if rig.isRunning {
                    micTestCaption
                        .padding(.horizontal, SettingsMetrics.cardContentInset)
                        .padding(.bottom, SettingsMetrics.cardContentInset)
                }
            }
            SettingsFootnote(
                markdown: "Need help? Check out our [troubleshooting guide](https://support.discord.com/hc/en-us/articles/360045138471)."
            )
        }
    }

    /// What Discord's test says under the meter.
    @ViewBuilder
    private var micTestCaption: some View {
        if rig.isSilent {
            VStack(alignment: .leading, spacing: 2) {
                Text("Discord isn\u{2019}t detecting any input from your mic.")
                    .font(SettingsType.footnote.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                Text("Please check that you\u{2019}ve selected the right input device. [Help!](https://support.discord.com/hc/en-us/articles/214925018)")
                    .font(SettingsType.footnote)
                    .foregroundStyle(Ink.secondary)
                    .tint(Palette.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if rig.isMonitoring {
            Text("Playing back your beautiful voice")
                .font(SettingsType.footnote)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Camera

    private var video: some View {
        SettingsGroup("Camera") {
            SettingsCard {
                DevicePickerRow(
                    title: "Camera",
                    systemImage: "video.fill",
                    selection: Binding(
                        get: { settings.cameraDeviceID },
                        set: { deviceID in
                            settings.cameraDeviceID = deviceID
                            guard isTestingCamera else { return }
                            Task { await camera.start(deviceID: deviceID) }
                        }
                    ),
                    options: cameras.map { ($0.id, "\($0.name) · \($0.kind)") }
                )
                CardDivider()
                // Synced — `voice_and_video.always_preview_video`.
                SettingsToggle(
                    title: "Always preview video",
                    help: "Pops up preview modal every time you turn on video",
                    isOn: Binding(
                        get: { model.syncedPreferences.alwaysPreviewsVideo },
                        set: { model.setAlwaysPreviewsVideo($0) }
                    )
                )
            }

            SettingsCard {
                CameraTestRow(
                    isTesting: $isTestingCamera,
                    rig: camera,
                    deviceID: settings.cameraDeviceID
                )
            }
        }
    }

    // MARK: Streaming

    /// Discord's Stream Attenuation, from its Streaming settings: a watched
    /// stream's sound drops while people in the call talk.
    private var streaming: some View {
        SettingsGroup("Streaming") {
            SettingsCard {
                SettingsToggle(
                    title: "Stream Attenuation",
                    help: "Automatically reduce stream volume when people are talking.",
                    isOn: Binding(
                        get: { settings.streamAttenuation },
                        set: {
                            settings.streamAttenuation = $0
                            model.voicePreferencesChanged()
                        }
                    )
                )
                CardDivider()
                SettingsSliderRow(
                    title: "Stream Attenuation Strength",
                    value: Binding(
                        get: { settings.streamAttenuationStrength },
                        set: {
                            settings.streamAttenuationStrength = $0
                            model.voicePreferencesChanged()
                        }
                    ),
                    range: 0...100,
                    step: 1,
                    format: { "\(Int($0))%" }
                )
                .disabled(!settings.streamAttenuation)
            }
        }
    }

    // MARK: Sounds

    private var callSounds: some View {
        SettingsGroup("Sounds") {
            SettingsCard {
                SettingsToggle(
                    title: "Play call sounds",
                    help: "The little sounds a call makes \u{2014} joins, leaves, mutes, cameras and screen shares, "
                        + "and someone starting to watch yours.",
                    isOn: $settings.playsCallSounds
                )
            }
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
/// **"Default" is a real choice and it is the first one**, not the
/// absence of a choice: a reader who has never opened this pane is on it, and a
/// reader whose headset has gone away falls back to it. Storing nil for it is
/// what makes that fallback automatic.
private struct DevicePickerRow: View {
    var title: String
    var systemImage: String
    @Binding var selection: String?
    /// id and name.
    var options: [(String, String)]

    var body: some View {
        SettingsControlRow(title) {
            // A `Picker`, not a hand-built `Menu`: the system draws the
            // checkmark beside the chosen row, keeps it in step with the
            // binding, and gives Full Keyboard Access the behaviour a menu
            // built out of buttons would have to put back by hand.
            Picker(selection: $selection) {
                // Discord's own first entry.
                Text("Default").tag(String?.none)
                Divider()
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(String?.some(option.0))
                }
                // A stored device that is no longer here keeps its own row, or
                // the picker would silently show "Default" for a choice
                // the reader made and can still get back by plugging it in.
                if let selection, !options.contains(where: { $0.0 == selection }) {
                    Divider()
                    Text("Not connected").tag(String?.some(selection))
                }
            } label: {
                Image(symbol: systemImage)
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
        guard let selection else { return "Default" }
        // A stored device that is no longer here says so rather than showing a
        // blank menu: "the headset you chose is unplugged" is the answer
        // somebody in this pane needs.
        return options.first { $0.0 == selection }?.1 ?? "Not connected"
    }
}

// MARK: - The meter

/// The level, drawn as a bar on Discord's scale — dBFS, −100 at the left and 0
/// at the right — with the line it has to cross when there is one.
///
/// **One scale for the level and the line**, so "set the line under where the
/// bar sits when you speak" is something a reader can do by looking.
private struct MeterRow: View {
    var title: String?
    /// Linear, 0…1, as the engine measures it.
    var level: Float
    /// In dBFS, or `nil` where nothing is set by hand.
    var threshold: Double?
    /// Whether the microphone is actually open. **A still bar and a broken
    /// microphone look identical**, so a bar with nothing behind it is drawn
    /// faded rather than empty and confident.
    var isLive: Bool = true

    private var decibels: Double { Double(MeterScale.decibels(level)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let title {
                Text(title)
                    .font(SettingsType.rowLabel)
                    .foregroundStyle(Ink.primary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(SettingsSurface.controlTrough)
                    Capsule()
                        .fill(fillStyle)
                        .frame(width: proxy.size.width * MeterScale.position(decibels))
                    if let threshold {
                        // The line, on the same scale as the bar. Drawn over
                        // both, so the reader can see the bar cross it.
                        Rectangle()
                            .fill(Ink.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * MeterScale.position(threshold) - 1)
                    }
                }
            }
            .frame(height: 8)
            .opacity(isLive ? 1 : 0.4)
            // Never animated on the level: it is a measured value arriving
            // twenty times a second, and a spring on it makes the bar lag the
            // voice it is supposed to be showing.
            .animation(nil, value: level)
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .padding(.vertical, SettingsMetrics.cardContentInset)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(isLive ? "\(Int(decibels)) dB" : "off"))
    }

    private var fillStyle: AnyShapeStyle {
        guard let threshold else { return AnyShapeStyle(SettingsSurface.switchOn) }
        // Green once it would open the gate. The colour IS the answer to "is it
        // loud enough", which a monochrome bar makes you infer from a position.
        return decibels >= threshold
            ? AnyShapeStyle(Palette.presenceOnline)
            : AnyShapeStyle(SettingsSurface.switchOn)
    }
}

/// Discord's meter scale.
private enum MeterScale {
    /// A linear level in dBFS, with digital silence at the scale's −100.
    static func decibels(_ level: Float) -> Float {
        level > 0.000_01 ? max(-100, 20 * log10(level)) : -100
    }

    /// Where a level in dBFS sits along the bar, 0…1.
    static func position(_ decibels: Double) -> CGFloat {
        CGFloat(min(1, max(0, (decibels + 100) / 100)))
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
                .buttonBorderShape(.capsule)
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
            Image(symbol: symbolName)
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
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.group)
    }
}
