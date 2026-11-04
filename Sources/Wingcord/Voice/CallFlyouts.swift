import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - What a call control's ▾ opens
//
// **Flyouts, not menus.** Discord puts a device and a level under its mute and
// deafen buttons (its modules 486487, 298242 and 110027), and a level is a
// slider, which a menu can only hold badly. The app's own surface for a
// choice is a glass flyout anchored to the control that raised it.
//
// **No material, no ground, no shadow** — `INVARIANTS.md` §4.9. The popover
// supplies all three.

/// What a split call control's ▾ opens.
enum CallFlyout: Hashable {
    /// A device and its level — Input, Output or Camera.
    case devices(VoiceDeviceChevron.Kind)
    /// Discord's menu for a stream that is live.
    case stream
}

/// Discord's items under the microphone, the headphones and the camera: the
/// device, the level, and — under the microphone — the Input Profile.
///
/// The machine's devices are read when the flyout opens and at no other time:
/// its body is built only while it is presented, and the bar it hangs off is
/// evaluated every time somebody in the call starts or stops talking.
struct CallDeviceFlyout: View {
    var kind: VoiceDeviceChevron.Kind

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(kind.title)
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
                .accessibilityAddTraits(.isHeader)
            deviceRow
            switch kind {
            case .input:
                // Discord's Input Volume stops at 100%.
                CallVolumeRow(title: "Input Volume", symbol: "mic.fill", gain: inputVolume, maximum: 1)
                labelled("Input Profile", symbol: "slider.horizontal.3") {
                    FlyoutPicker(
                        selection: inputProfile,
                        options: AppSettings.InputProfile.allCases,
                        title: \.title,
                        accessibilityTitle: "Input Profile"
                    )
                }
            case .output:
                // And its Output Volume, on the desktop, at 200%.
                CallVolumeRow(title: "Output Volume", symbol: "speaker.wave.2.fill", gain: outputVolume, maximum: 2)
            case .camera:
                // Discord's camera menu (`video-device-context`): the device,
                // then Preview Camera while the camera is off.
                if !model.isCameraOn {
                    Button("Preview Camera", systemImage: "eye") {
                        dismiss()
                        model.previewCamera()
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(Spacing.margin)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: The device

    private var deviceRow: some View {
        let devices = self.devices
        let names = Dictionary(devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return labelled(kind.deviceTitle, symbol: kind.deviceSymbol) {
            FlyoutPicker(
                selection: device,
                options: [nil] + devices.map { Optional($0.id) },
                // "Default" is a choice, not the absence of one: it follows
                // whatever the Mac is using, which a named device does not
                // once a headset is unplugged.
                title: { id in id.flatMap { names[$0] } ?? "Default" },
                accessibilityTitle: kind.deviceTitle,
                flyoutWidth: 280
            )
        }
    }

    private var devices: [(id: String, name: String)] {
        switch kind {
        case .input: AudioDeviceCatalog.inputs().map { ($0.uniqueID, $0.name) }
        case .output: AudioDeviceCatalog.outputs().map { ($0.uniqueID, $0.name) }
        case .camera: CameraCapture.devices().map { ($0.id, $0.name) }
        }
    }

    /// Handed to the running call in the setter itself.
    private var device: Binding<String?> {
        let path: ReferenceWritableKeyPath<AppSettings, String?> = switch kind {
        case .input: \.voiceInputDeviceID
        case .output: \.voiceOutputDeviceID
        case .camera: \.cameraDeviceID
        }
        return Binding(
            get: { settings[keyPath: path] },
            set: {
                settings[keyPath: path] = $0
                model.voicePreferencesChanged()
            }
        )
    }

    private var inputProfile: Binding<AppSettings.InputProfile> {
        Binding(
            get: { settings.inputProfile },
            set: {
                settings.inputProfile = $0
                model.voicePreferencesChanged()
            }
        )
    }

    // MARK: The level

    private var inputVolume: Binding<Double> {
        Binding(
            get: { settings.voiceInputVolume },
            set: {
                settings.voiceInputVolume = $0
                model.voicePreferencesChanged()
            }
        )
    }

    private var outputVolume: Binding<Double> {
        Binding(
            get: { settings.voiceOutputVolume },
            set: {
                settings.voiceOutputVolume = $0
                model.voicePreferencesChanged()
            }
        )
    }

    private func labelled(
        _ title: String, symbol: String, @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: Spacing.base) {
            Label(title, systemImage: symbol)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: Spacing.base)
            control()
        }
    }
}

/// A level, as Discord's call menus draw one: its name and percentage over a
/// slider.
///
/// **The slider is Discord's, not a gain.** It moves along `VolumeCurve` — the
/// quiet end gets most of the travel — and the percentage is the slider's, as
/// Discord's is; what is stored and played is the gain beneath it.
struct CallVolumeRow: View {
    var title: String
    var symbol: String?
    @Binding var gain: Double
    /// How far the slider goes: 1 for 100%, 2 for 200%.
    var maximum: Double

    var body: some View {
        let position = VolumeCurve.position(ofGain: gain)
        let percent = "\(Int((position * 100).rounded()))%"
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
                Spacer(minLength: Spacing.base)
                Text(percent)
                    .monospacedDigit()
                    .foregroundStyle(Ink.secondary)
            }
            .font(.system(.subheadline))
            .foregroundStyle(Ink.primary)
            Slider(
                value: Binding(
                    get: { min(maximum, position) },
                    set: { gain = VolumeCurve.gain(atPosition: $0) }
                ),
                in: 0...maximum
            )
            .controlSize(.small)
            .tint(SettingsSurface.switchOn)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(percent))
        }
    }
}

/// Discord's Stream Volume for the stream being watched — its own level,
/// apart from the person's voice, up to 200%, and synced with the account.
struct StreamVolumeFlyout: View {
    var owner: UserID

    @Environment(AppModel.self) private var model

    var body: some View {
        CallVolumeRow(
            title: "Stream Volume",
            symbol: "speaker.wave.2.fill",
            gain: Binding(
                get: { model.audioContext.volume(of: owner, in: .stream) },
                set: { model.setVolume($0, of: owner, in: .stream) }
            ),
            maximum: 2
        )
        .padding(Spacing.margin)
        .frame(width: 280)
    }
}

extension VoiceDeviceChevron.Kind {
    /// The device's own row, in Discord's words.
    var deviceTitle: String {
        switch self {
        case .input: "Input Device"
        case .output: "Output Device"
        case .camera: "Camera"
        }
    }

    var deviceSymbol: String {
        switch self {
        case .input: "mic"
        case .output: "speaker.wave.2"
        case .camera: "video"
        }
    }
}

// MARK: - A live stream's own flyout

/// Discord's menu for a stream that is live (its module 405916): Stream
/// Quality — the frame rate and the resolution — Share Audio, picking again,
/// and Stop Streaming.
struct LiveShareFlyout: View {
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        let gate = model.goLiveGate
        let chosen = gate.admit(settings.goLive)
        VStack(spacing: 0) {
            FlyoutSectionHeader(title: "Frame Rate")
            GoLiveFrameRateRows(settings: chosen, gate: gate) { model.updateGoLive($0) }
            FlyoutSectionHeader(title: "Resolution")
            GoLiveResolutionRows(settings: chosen, gate: gate) { model.updateGoLive($0) }
            FlyoutDivider()
            FlyoutRow(
                title: "Share Audio",
                symbolName: "speaker.wave.2",
                accessory: .checkbox(chosen.sharesAudio)
            ) {
                var next = chosen
                next.sharesAudio.toggle()
                model.updateGoLive(next)
            }
            FlyoutRow(
                title: model.screenShareSource?.changeTitle ?? "Change Windows",
                symbolName: "rectangle.on.rectangle"
            ) {
                dismiss()
                model.pickScreenSource()
            }
            FlyoutDivider()
            FlyoutRow(
                title: "Stop Streaming",
                symbolName: "xmark.rectangle",
                isDestructive: true
            ) {
                dismiss()
                model.stopScreenShare()
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 240)
    }
}
