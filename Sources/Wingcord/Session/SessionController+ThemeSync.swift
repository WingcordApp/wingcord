import Foundation
import WingcordCore
import WingcordNet

// MARK: - "Sync theme across my devices"

extension SessionController {

    /// Takes the account's theme where it names one of Discord's themes here
    /// (DESIGN-NOTES §15): a gradient preset becomes that theme. A plain
    /// room, a Nitro custom theme, or a preset with no theme here leaves the
    /// reader's theme as it is — a house theme has no Discord twin to take.
    ///
    /// Nothing while the switch is off, or while the theme follows the
    /// computer: Discord disables its switch then.
    func adoptAccountTheme(_ theme: AccountTheme?) {
        guard AppSettings.shared.syncsThemeAcrossDevices,
              ThemeStore.shared.choice != .system,
              let theme, !theme.hasCustomTheme,
              let id = theme.gradientPresetID,
              let discord = DiscordTheme(presetID: id)
        else { return }
        ThemeStore.shared.adopt(.discord(discord))
    }

    /// Writes a theme the reader chose to the account, as Discord's picker
    /// writes one (`817281.p`): one of Discord's themes as its base and its
    /// preset; any other as Discord's plain Light or Dark, with no preset.
    func writeAccountTheme(for choice: ThemeChoice) {
        guard AppSettings.shared.syncsThemeAcrossDevices,
              choice != .system,
              model.connectionState == .ready
        else { return }
        let isLight: Bool
        let preset: Int?
        if case .discord(let theme) = choice {
            isLight = theme.base == .light
            preset = theme.presetID
        } else {
            isLight = ThemeStore.shared.colors.appearance == .light
            preset = nil
        }
        let change = SyncedPreferencesProto.Change.accountTheme(
            base: isLight ? AccountTheme.light : AccountTheme.dark,
            gradientPresetID: preset
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setSyncedPreference(change)
            } catch {
                Self.trace("theme sync write failed: \(Self.describe(error))")
            }
        }
    }
}
