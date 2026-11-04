import AppKit
import SwiftUI

// MARK: - A profile's flyouts, in the profile's room

extension EnvironmentValues {
    /// The room of the profile a flyout is opening from, or nil outside one. Set by
    /// `ProfileGroundFill`, and read by `profileFlyoutAppearance()` from inside the
    /// popover: a presentation inherits the environment it was raised in.
    @Entry var profileFlyoutScheme: ColorScheme?
}

extension View {
    /// Puts a popover raised from a profile in that profile's room: **its glass and
    /// its ink together**, light over a light profile and dark over a dark one.
    ///
    /// **Both, because either alone is what Alex's image 48 is.** A popover is a
    /// window of its own and its glass follows the app's appearance, whatever the
    /// card behind it is wearing. So a pale pink card's ⋯ menu came up in dark glass
    /// with the colours of the card bleeding through it: low contrast and the wrong
    /// room. Restating only the ink, which is what these used to do, made it
    /// readable and left it dark. This turns the popover's window as well.
    ///
    /// Goes on the popover's *content*. Outside a profile it's the app's room, the
    /// same thing `appColorScheme()` says.
    func profileFlyoutAppearance() -> some View {
        modifier(ProfileFlyoutAppearance())
    }
}

private struct ProfileFlyoutAppearance: ViewModifier {
    @Environment(\.profileFlyoutScheme) private var profileScheme
    @State private var theme = ThemeStore.shared

    func body(content: Content) -> some View {
        let appScheme: ColorScheme = theme.colors.appearance == .light ? .light : .dark
        let scheme = profileScheme ?? appScheme
        content
            .environment(\.colorScheme, scheme)
            .background {
                // **A veil where the glass is in the other room from what's behind
                // it.** Glass lets through what it floats over, and a flyout that
                // runs past the card is mostly over the app: light glass over a dark
                // window is a muddy grey, with dark words on it that don't read.
                if scheme != appScheme {
                    (scheme == .light ? Color.white.opacity(0.5) : Color.black.opacity(0.45))
                        .ignoresSafeArea()
                }
            }
            .background { PopoverWindowAppearance(isDark: scheme == .dark) }
    }
}

/// Sets the appearance of the popover window it finds itself in.
///
/// **A popover's glass reads its window's appearance**, and SwiftUI's colour scheme
/// doesn't reach it: `.environment(\.colorScheme)` changes the ink,
/// `.preferredColorScheme` would be a statement about the whole app.
struct PopoverWindowAppearance: NSViewRepresentable {
    var isDark: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.isDark = isDark
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.isDark = isDark
        probe.apply()
    }

    final class Probe: NSView {
        var isDark = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            // **Only a popover's.** This mustn't ever repaint the main window, and
            // a view that's been misplaced somewhere else shouldn't be able to.
            guard let window, NSStringFromClass(type(of: window)).contains("Popover") else { return }
            let name: NSAppearance.Name = isDark ? .darkAqua : .aqua
            guard window.appearance?.name != name else { return }
            window.appearance = NSAppearance(named: name)
        }
    }
}

/// The opaque ground a flyout carries, in the room it's in: the app's own while that's
/// the room it is, and the house's neutral for the other one — see
/// `ProfileGround.neutral`. **`Palette`'s colours are the theme's**, and don't turn
/// with the colour scheme.
enum ProfileFlyoutGround {
    @MainActor
    static func raised(in scheme: ColorScheme) -> Color {
        let appIsLight = ThemeStore.shared.colors.appearance == .light
        if appIsLight == (scheme == .light) { return Palette.surfaceRaised }
        return Color(hex: (scheme == .light ? ThemeColors.porcelain : .trueBlack).surfaceRaised)
    }
}
