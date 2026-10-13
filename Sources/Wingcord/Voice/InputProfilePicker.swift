import SwiftUI

/// Discord's Input Profile submenu (its module 110027): Voice Isolation, Studio
/// or Custom, with a checkmark on the one in use — under the microphone's ▾ in
/// the call band and in the menu bar's Voice menu, as Discord puts it under its
/// mute button.
///
/// The store is passed rather than read from the environment, for the reason
/// `VoiceDevicePicker`'s is: a menu bar command has no view environment.
struct InputProfilePicker: View {
    var model: AppModel

    @State private var settings = AppSettings.shared

    var body: some View {
        Picker(
            "Input Profile",
            selection: Binding(
                get: { settings.inputProfile },
                // Applied in the setter itself: a menu closes on the click that
                // chose, and takes anything watching for the change with it.
                set: {
                    settings.inputProfile = $0
                    model.voicePreferencesChanged()
                }
            )
        ) {
            ForEach(AppSettings.InputProfile.allCases, id: \.self) { profile in
                Text(profile.title).tag(profile)
            }
        }
        .pickerStyle(.menu)
    }
}
