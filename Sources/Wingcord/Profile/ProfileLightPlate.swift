import SwiftUI

/// What a small plate rides on when the profile under it is light: the tag pill,
/// the note field.
///
/// **See-through, so it keeps the person's colour.** Discord's rule for this kind
/// of thing on `.custom-user-profile-theme.theme-light` is `--opacity-white-24`,
/// raised to `--opacity-white-40` (`guildTagPill`, and a dozen others in its
/// stylesheets). A grey or dark plate reads as a lump on a pale card, which is what
/// the tag and the note both were (Alex's image 52).
///
/// **White only works over somebody's colour.** On an unthemed light card it would
/// be invisible, so that one takes `--background-mod-subtle`, grey at 12 %, and
/// `--background-mod-strong` raised.
enum ProfileLightPlate {
    /// `hsl(240 4% 61%)`, which Discord's `--background-mod-*` and `--border-muted`
    /// are all made from.
    static let mod = Color(hex: 0x98_98_9F)

    static func fill(wearsTheme: Bool, isRaised: Bool) -> Color {
        if wearsTheme { return .white.opacity(isRaised ? 0.4 : 0.24) }
        return mod.opacity(isRaised ? 0.24 : 0.12)
    }
}
