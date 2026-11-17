import SwiftUI

/// "Join {name}": the row's one prominent action.
///
/// **Green**, the colour Accept wears on an incoming call: joining a call
/// that is already running is the same affirmative act, and a colour of its
/// own would be a second vocabulary for one meaning. A capsule, like every
/// other call control.
struct CallLobbyJoinButton: View {
    var title: String
    var hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "phone.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(.body, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, Spacing.tight)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Palette.affirmative)
        .fixedSize()
        .accessibilityHint(Text(hint))
    }
}
