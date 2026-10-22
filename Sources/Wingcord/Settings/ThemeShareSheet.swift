import SwiftUI
import WingcordCore

/// A custom theme on its way to the share sheet.
struct ThemeShareRequest: Identifiable {
    var theme: SharedClientTheme

    var id: SharedClientTheme { theme }
}

/// Discord's "Share custom theme": where to send a theme — the forward sheet,
/// with the theme where the message would be (docs/CLIPS-PRESENCE.md, D25).
/// What lands is Discord's theme card, which anyone can preview on Discord or
/// here.
struct ThemeShareSheet: View {
    var theme: SharedClientTheme
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        ForwardSheet(
            title: "Share Custom Theme",
            subtitle: "It arrives as Discord\u{2019}s theme card, ready to preview.",
            targets: model.forwardTargets(excluding: nil),
            copyLink: nil,
            send: { targets, comment in
                model.shareTheme(theme, to: targets, comment: comment)
                dismiss()
            },
            dismiss: dismiss
        ) {
            HStack(spacing: Spacing.snug) {
                SharedThemeSwatch(theme: theme)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Theme")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                    Text(theme.isLight ? "Light" : "Dark")
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
