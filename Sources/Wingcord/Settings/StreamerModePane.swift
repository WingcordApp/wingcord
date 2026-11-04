import SwiftUI
import WingcordCore

// MARK: - Streamer Mode
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D21). Discord's page, in its words where it
// has them: "Enable Streamer Mode", the automatic switch, then "If Streamer
// Mode is enabled..." and what it does. Two departures, both forced by the
// platform: XSplit has no Mac build, so the automatic switch names the Mac's
// broadcasters; and "Hide Discord Window from Screen Capture" says what it
// does here — every window, the overlay included, which the reader still sees
// and the stream does not.

struct StreamerModePane: View {
    @State private var streamer = StreamerMode.shared
    @Environment(\.settingsNavigate) private var navigate

    private var settings: StreamerModeSettings { streamer.settings }

    var body: some View {
        SettingsCard {
            SettingsToggle(
                title: "Enable Streamer Mode",
                help: "Streamer Mode hides your personal info so others watching your stream can’t see it.",
                isOn: binding(\.isEnabled)
            )
            CardDivider()
            SettingsToggle(
                title: "Automatically enable Streamer Mode if OBS, Streamlabs or Ecamm Live are running",
                help: automaticHelp,
                isOn: binding(\.turnsOnWithStreamingSoftware)
            )
        }
        SettingsFootnote(keyNote, symbolName: "keyboard")

        SettingsGroup("If Streamer Mode is enabled...") {
            SettingsCard {
                SettingsToggle(
                    title: "Hide my personal information, such as email, connected accounts, and notes",
                    help: "Your email and phone in Account, your connected accounts on your own "
                        + "profile and in Connected Apps, and your notes on other people.",
                    isOn: binding(\.hidesPersonalInformation)
                )
                CardDivider()
                SettingsToggle(
                    title: "Hide invite links to my Discord servers",
                    help: "Recommended if you don’t want random people accessing your Discord servers. "
                        + "Copying a link still copies it.",
                    isOn: binding(\.hidesInviteLinks)
                )
                CardDivider()
                SettingsToggle(
                    title: "Disable all sound effects",
                    help: "Joins, leaves, mutes and message sounds.",
                    isOn: binding(\.disablesSounds)
                )
                CardDivider()
                SettingsToggle(
                    title: "Disable notifications",
                    help: "All desktop notifications will be disabled.",
                    isOn: binding(\.disablesNotifications)
                )
                CardDivider()
                SettingsToggle(
                    title: "Hide Wingcord from screen capture",
                    help: "Every Wingcord window — the overlay too — is left out of screen "
                        + "captures, OBS's included. You still see them; your stream doesn’t.",
                    isOn: binding(\.hidesWindowsFromCapture)
                )
            }
        }

        SettingsGroup("Hide overlay widgets") {
            SettingsCard {
                SettingsCheckboxGrid(
                    options: OverlayWidgetKind.allCases.map { .init($0, $0.title) },
                    isOn: { settings.hiddenOverlayWidgets.contains($0) },
                    set: { kind, hidden in
                        streamer.update { settings in
                            if hidden {
                                settings.hiddenOverlayWidgets.insert(kind)
                            } else {
                                settings.hiddenOverlayWidgets.remove(kind)
                            }
                        }
                    }
                )
            }
            SettingsFootnote(
                "Hidden from the overlay while Streamer Mode is on \u{2014} for you too \u{2014} and back "
                    + "when it\u{2019}s off.",
                symbolName: "rectangle.on.rectangle.slash"
            )
        }
    }

    private func binding(_ keyPath: WritableKeyPath<StreamerModeSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { streamer.settings[keyPath: keyPath] },
            set: { value in streamer.update { $0[keyPath: keyPath] = value } }
        )
    }

    private var automaticHelp: String {
        if streamer.runningSoftware.isEmpty {
            return "On when one starts, off when it quits."
        }
        let names = ListFormatter.localizedString(byJoining: streamer.runningSoftware)
        return "\(names) is running now."
    }

    private var keyNote: String {
        let key = AppSettings.shared.hotkey(for: .toggleStreamerMode)?.displayString
        let menu = "It\u{2019}s also in the Wingcord menu."
        guard let key else {
            return "Toggle Streamer Mode has no key yet \u{2014} give it one in Shortcuts. " + menu
        }
        return "\(key) turns it on and off from anywhere. " + menu
    }
}
