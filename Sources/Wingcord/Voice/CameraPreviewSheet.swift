import SwiftUI
import WingcordCore
import WingcordVoice

/// Discord's camera preview (module 308229, its Preview Camera): the camera,
/// live; which camera; "Always preview video"; and Turn On Camera.
///
/// **No background picker** — Discord's sits beside the preview, and the Mac's
/// own video effects are in Control Center, which is where a camera's
/// background is chosen on this platform (VOICE-VIDEO-NOTES §0, row 8e).
///
/// **The preview is its own capture, never the call's** — the settings pane's
/// rig, stopped before the call's camera starts, so the two never hold the
/// device at once.
struct CameraPreviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var rig = CameraTestRig()
    @State private var settings = AppSettings.shared
    @State private var cameras: [CameraDevice] = []

    /// Discord's preview is 430 × 242.
    private static let previewSize = CGSize(width: 430, height: 242)

    var body: some View {
        FormSheet(
            title: "Ready to video chat?",
            confirmTitle: "Turn On Camera",
            closesOnConfirm: true,
            width: Self.previewSize.width + 2 * Spacing.group,
            confirm: {
                rig.stop()
                model.turnOnCameraFromPreview()
            }
        ) {
            preview
            if rig.isDenied {
                Text("You must grant Discord [access to your camera](x-apple.systempreferences:com.apple.preference.security?Privacy_Camera) in order to be able to preview.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cameras.isEmpty {
                Picker("Camera", selection: camera) {
                    Text("Default").tag(String?.none)
                    ForEach(cameras, id: \.id) { device in
                        Text(device.name).tag(String?.some(device.id))
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("Always preview video", isOn: alwaysPreviews)
                .toggleStyle(.checkbox)
        }
        // Off the main actor: the first device list of a process loads the
        // camera assistant.
        .task {
            cameras = await Task.detached { CameraCapture.devices() }.value
            await rig.start(deviceID: settings.cameraDeviceID)
        }
        .onDisappear { rig.stop() }
    }

    private var preview: some View {
        CameraPreviewView(session: rig.session)
            .frame(width: Self.previewSize.width, height: Self.previewSize.height)
            .background(Color.black)
            .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            .accessibilityLabel(Text("Camera"))
    }

    /// The call's camera, so the one previewed is the one that turns on.
    private var camera: Binding<String?> {
        Binding(
            get: { settings.cameraDeviceID },
            set: { deviceID in
                settings.cameraDeviceID = deviceID
                Task { await rig.start(deviceID: deviceID) }
            }
        )
    }

    /// Synced, as Discord's is — `voice_and_video.always_preview_video`.
    private var alwaysPreviews: Binding<Bool> {
        Binding(
            get: { model.syncedPreferences.alwaysPreviewsVideo },
            set: { model.setAlwaysPreviewsVideo($0) }
        )
    }
}
