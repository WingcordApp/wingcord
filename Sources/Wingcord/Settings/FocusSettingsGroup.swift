import AppKit
import SwiftUI
import WingcordCore

/// Settings › Notifications › Focus: what a macOS Focus does to the reader's
/// status (docs/CLIPS-PRESENCE.md, D1–D2).
///
/// **The Focus picks itself in System Settings.** A Focus reaches Wingcord as a
/// Focus filter the reader adds there; the status here is what a filter set to
/// "Wingcord's Focus status" — the one it offers first — applies, so one place
/// edits it for every Focus that uses it. A Focus can also pick its own status
/// in its filter instead.
struct FocusSettingsGroup: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    private static let focusSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")

    var body: some View {
        SettingsGroup("Focus") {
            SettingsCard {
                SettingsControlRow(
                    "Status during a Focus",
                    help: "What your status becomes while a Focus with Wingcord's filter is on."
                ) {
                    FlyoutPicker(
                        selection: $settings.focusStatus,
                        options: PresenceStatus.choosable,
                        title: \.label,
                        detail: \.explanation,
                        accessibilityTitle: "Status during a Focus"
                    )
                }
                CardDivider()
                FocusCustomStatusRow(status: $settings.focusCustomStatus)
                CardDivider()
                SettingsToggle(
                    title: "Put it back afterwards",
                    help: "When the Focus ends, your status goes back \u{2014} unless you changed it yourself.",
                    isOn: $settings.focusRestores
                )
                CardDivider()
                SettingsActionRow(
                    "Choose Focuses",
                    help: "Wingcord follows the Focuses you add its filter to.",
                    actionTitle: "Open Focus Settings…",
                    action: openFocusSettings
                )
            }
            FocusStateLine()
            SettingsFootnote(
                "In System Settings \u{203A} Focus, pick a Focus, then Focus Filters \u{203A} Add Filter\u{2026} "
                    + "\u{203A} Wingcord. Each Focus can choose its own status there too.",
                symbolName: "moon"
            )
        }
        .onChange(of: settings.focusStatus) { model.focusSync?.settingsChanged() }
        .onChange(of: settings.focusCustomStatus) { model.focusSync?.settingsChanged() }
    }

    private func openFocusSettings() {
        guard let url = Self.focusSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
