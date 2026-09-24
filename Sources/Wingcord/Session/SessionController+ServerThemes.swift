import Foundation
import WingcordCore
import WingcordNet

// MARK: - Server themes
//
// The one write behind Appearance → "Default theme in servers". What a server's
// theme draws as is `ServerTheme`; whose theme applies is `ServerThemePreferences`.

extension SessionController {

    /// Writes Appearance → "Default theme in servers", putting the old value
    /// back if Discord refuses — a switch that shows an answer the account
    /// does not hold is a setting that lies.
    func setDefaultServerTheme(_ source: GuildThemeSource) {
        let previous = model.serverThemePreferences.default
        guard previous != source else { return }
        model.serverThemePreferences.default = source
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setDefaultServerTheme(source)
            } catch {
                Self.trace("server theme preference FAILED: \(Self.describe(error))")
                if model.serverThemePreferences.default == source {
                    model.serverThemePreferences.default = previous
                }
            }
        }
    }
}
