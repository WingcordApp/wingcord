import SwiftUI

/// How a call control looks in each state, shared by the HUD's glass discs and
/// the capsule's regions.
///
/// **At rest a control is a quiet disc with a plain glyph. Switched on, it turns
/// light and its glyph takes the state's colour**: green for a camera that is
/// on, indigo for a screen being shared, orange for a muted microphone, red for
/// deafened. Leave is red at all times. Alex's design (references 09 and 10 in
/// `docs/references/2026-10-05`).
enum CallButtonLook {
    /// The colour a switched-on control's glyph takes.
    static func stateColor(_ kind: CallButton.Kind) -> Color {
        switch kind {
        case .camera: Palette.presenceOnline
        case .screenShare: .indigo
        case .microphone: .orange
        case .headphones, .leave: Palette.destructive
        case .soundboard, .activities: Palette.accent
        }
    }

    static func ink(_ kind: CallButton.Kind, isActive: Bool) -> Color {
        if kind == .leave { return .white }
        return isActive ? stateColor(kind) : InkColor.primary
    }

    /// A HUD disc's glass. Interactive throughout, so the pointer and a press
    /// are answered by the material itself rather than by a fill that changes.
    static func glass(_ kind: CallButton.Kind, isActive: Bool) -> Glass {
        if kind == .leave { return .regular.tint(Palette.destructive).interactive() }
        if isActive { return .regular.tint(activeTint).interactive() }
        return .regular.interactive()
    }

    /// A switched-on control: near-white in a dark room, white in a light one,
    /// so the state's colour reads on it either way.
    static let activeTint = Color.adaptive(dark: NSColor(white: 0.92, alpha: 1), light: .white)

    /// A region of the capsule under the pointer, and under a press: light on a
    /// dark room's glass, shade on a light one's.
    static let regionHovered = Color.relative(dark: 0.14, light: 0.10)
    static let regionPressed = Color.relative(dark: 0.24, light: 0.18)
}
