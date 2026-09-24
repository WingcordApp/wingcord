import SwiftUI
import WingcordCore

// MARK: - Server themes
//
// Which server's theme the window wears, and when. What one looks like is
// `ServerTheme`; the window taking it on is `ThemeStore.setServerTheme`.

extension AppModel {

    /// Discord's flag for a server that may carry a theme.
    static let serverThemeFeature = "GUILD_THEME"

    /// The theme of the server the reader is in, while it is the one drawn.
    ///
    /// Discord's own resolution (`useActiveGuildTheme`, module `875317`): the
    /// selected server has the feature, its theme is switched on and is one
    /// Discord can draw, and the reader has not asked for their own theme
    /// there — per server, or by default in Appearance.
    ///
    /// **Discord also gates it on a user experiment** (`2026-05-server-theme-user`)
    /// that this client cannot evaluate; the server's flags and the reader's
    /// preference are what decide here. Discovery wears no server's theme: it
    /// is a page about other servers.
    var activeServerTheme: ActiveServerTheme? {
        guard !isDiscoveryShown,
              let guildID = selectedGuildID,
              let guild = guilds[guildID],
              guild.features.contains(Self.serverThemeFeature),
              let theme = guild.theme, theme.resolved != nil,
              serverThemePreferences.usesServerTheme(in: guildID)
        else { return nil }
        return ActiveServerTheme(guildID: guildID, theme: theme)
    }
}

/// Keeps the window's theme on the server the reader is in.
///
/// **A modifier at the window root rather than a subscription in the store**,
/// for `DockBadgeModifier`'s reason: the answer is a projection, and the thing
/// that can tell it moved is a view that reads it. `onChange` fires only when
/// the value differs, so a guild update that changed no theme costs one
/// comparison.
private struct ServerThemeModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onChange(of: model.activeServerTheme, initial: true) { _, theme in
                ThemeStore.shared.setServerTheme(theme)
            }
    }
}

extension View {
    /// Applied once, at the window root.
    func wearsServerThemes() -> some View {
        modifier(ServerThemeModifier())
    }
}
