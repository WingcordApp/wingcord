import SwiftUI
import WingcordVoice

/// The machine's devices of one kind, and which is in use: a native choice
/// with a checkmark, applied to a call already running. The call band's ▾
/// menus and the menu bar's Voice menu are this one view.
///
/// **"Default" is a choice, not the absence of one.** No preference means
/// "follow whatever the Mac is doing", which diverges from naming the device
/// the Mac happens to be using the moment a headset is unplugged.
///
/// The store is passed rather than read from the environment, because a menu
/// bar command has no view environment to read it from.
struct VoiceDevicePicker: View {
    var kind: VoiceDeviceChevron.Kind
    var model: AppModel

    @State private var settings = AppSettings.shared

    static func title(_ kind: VoiceDeviceChevron.Kind) -> String {
        switch kind {
        case .input: "Input Device"
        case .output: "Output Device"
        case .camera: "Video Device"
        }
    }

    var body: some View {
        switch kind {
        case .input:
            picker(\.voiceInputDeviceID, devices: AudioDeviceCatalog.inputs().map { ($0.uniqueID, $0.name) })
        case .output:
            picker(\.voiceOutputDeviceID, devices: AudioDeviceCatalog.outputs().map { ($0.uniqueID, $0.name) })
        case .camera:
            picker(\.cameraDeviceID, devices: CameraCapture.devices().map { ($0.id, $0.name) })
        }
    }

    /// The choice is handed to the running call in the setter itself: a menu
    /// closes on the click that chose, and takes anything watching for the
    /// change with it.
    private func choice(_ preference: ReferenceWritableKeyPath<AppSettings, String?>) -> Binding<String?> {
        Binding(
            get: { settings[keyPath: preference] },
            set: { id in
                settings[keyPath: preference] = id
                model.voicePreferencesChanged()
            }
        )
    }

    private func picker(
        _ preference: ReferenceWritableKeyPath<AppSettings, String?>,
        devices: [(id: String, name: String)]
    ) -> some View {
        Picker(Self.title(kind), selection: choice(preference)) {
            Text("Default").tag(String?.none)
            ForEach(devices, id: \.id) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }
        .pickerStyle(.inline)
    }
}
